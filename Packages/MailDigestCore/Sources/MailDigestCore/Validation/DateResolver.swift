import Foundation

/// A due date parsed from the model's ISO-8601 string.
public struct ResolvedDue: Sendable, Equatable {
    public var date: Date
    /// False for date-only input, which resolves to midnight local time.
    public var hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }
}

/// Parses model-supplied due strings in a fixed time zone and applies the range rule.
public struct DateResolver: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // Built per call so the time zone is always the injected one, never the system's.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// Parses `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS][Z|±HH:MM]`.
    /// Returns nil for garbage, dates before today, or dates more than 365 days ahead.
    public func resolve(_ due: String?, today: Date) -> ResolvedDue? {
        guard let due, let parsed = parse(due.trimmingCharacters(in: .whitespaces)) else { return nil }
        let cal = calendar
        // Compare calendar days, so a time earlier today is still today.
        let todayStart = cal.startOfDay(for: today)
        let dueStart = cal.startOfDay(for: parsed.date)
        guard let days = cal.dateComponents([.day], from: todayStart, to: dueStart).day,
              days >= 0, days <= 365 else { return nil }
        return parsed
    }

    /// True when both instants fall on the same calendar day in the resolver's time zone.
    public func isSameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    private func parse(_ s: String) -> ResolvedDue? {
        let parts = s.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let datePart = parts.first else { return nil }
        let d = datePart.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard d.count == 3, d[0].count == 4, d[1].count == 2, d[2].count == 2,
              let y = digits(d[0]), let mo = digits(d[1]), let day = digits(d[2]) else { return nil }

        var hour = 0, minute = 0, second = 0
        var zone = timeZone
        var hasTime = false
        if parts.count == 2 {
            hasTime = true
            var t = parts[1]
            // Peel off an optional zone suffix before reading the clock part.
            if t.hasSuffix("Z") || t.hasSuffix("z") {
                guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
                zone = utc
                t.removeLast()
            } else if let signIdx = t.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                let off = String(t[t.index(after: signIdx)...]).replacingOccurrences(of: ":", with: "")
                guard off.count == 4, let oh = digits(String(off.prefix(2))), let om = digits(String(off.suffix(2))),
                      oh < 24, om < 60,
                      let tz = TimeZone(secondsFromGMT: (oh * 3600 + om * 60) * (t[signIdx] == "-" ? -1 : 1))
                else { return nil }
                zone = tz
                t = String(t[..<signIdx])
            }
            let c = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard c.count == 2 || c.count == 3, c.allSatisfy({ $0.count == 2 }),
                  let h = digits(c[0]), let m = digits(c[1]) else { return nil }
            hour = h
            minute = m
            if c.count == 3 {
                guard let sec = digits(c[2]) else { return nil }
                second = sec
            }
            guard hour < 24, minute < 60, second < 60 else { return nil }
        }

        var cal = calendar
        cal.timeZone = zone
        let comps = DateComponents(year: y, month: mo, day: day, hour: hour, minute: minute, second: second)
        guard let date = cal.date(from: comps) else { return nil }
        // Calendar is lenient (Feb 30 rolls over), so confirm the fields survived.
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == mo, back.day == day else { return nil }
        return ResolvedDue(date: date, hasTime: hasTime)
    }

    private func digits(_ s: String) -> Int? {
        s.allSatisfy({ $0 >= "0" && $0 <= "9" }) ? Int(s) : nil
    }
}
