import Foundation

/// The Today header: greeting, first name and date overline. Time, calendar and locale are injected.
public enum TodayGreeting {
    /// "Good morning" before 12 pm, "Good afternoon" from 12 pm, "Good evening" from 6 pm, by `calendar`'s time zone.
    public static func greeting(at now: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: now) {
        case ..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// The first word of a full name ("Justin Wang" gives "Justin"); nil for an empty or blank name.
    public static func firstName(fromFullName fullName: String) -> String? {
        fullName.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// "Good morning, Justin", or just "Good morning" when there is no name (no dangling comma).
    public static func title(now: Date, calendar: Calendar, fullName: String) -> String {
        let greeting = greeting(at: now, calendar: calendar)
        guard let name = firstName(fromFullName: fullName) else { return greeting }
        return "\(greeting), \(name)"
    }

    /// "MONDAY 9 NOVEMBER": weekday, day and month, upper-cased in the given locale.
    public static func dateOverline(now: Date, calendar: Calendar, locale: Locale = Locale(identifier: "en_AU")) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: now).uppercased(with: locale)
    }
}

/// Where and when the day's runs were processed, taken from real job and item records.
public struct RunInfo: Sendable, Equatable {
    /// Emails whose final executor was the local model.
    public var localEmails: Int
    /// Emails whose final executor was Gemini.
    public var cloudEmails: Int
    /// The local model recorded most often ("qwen3:4b"); nil when no item recorded one.
    public var localModel: String?
    public var cloudModel: String?
    /// When the last run finished; nil while any of them is still going or no end time was stored.
    public var finishedAt: Date?
    /// Total running time of the runs; nil when unknown.
    public var duration: TimeInterval?

    public init(localEmails: Int, cloudEmails: Int, localModel: String?, cloudModel: String?,
                finishedAt: Date?, duration: TimeInterval?) {
        self.localEmails = localEmails
        self.cloudEmails = cloudEmails
        self.localModel = localModel
        self.cloudModel = cloudModel
        self.finishedAt = finishedAt
        self.duration = duration
    }

    /// Builds the summary from the jobs of the day and their items. Nothing is guessed: an item without a
    /// recorded executor counts for neither side.
    public static func make(jobs: [Job], items: [JobItem]) -> RunInfo {
        var local = 0, cloud = 0
        var localModels: [String: Int] = [:], cloudModels: [String: Int] = [:]
        for item in items {
            let execution = item.routing?.execution
            switch execution?.provider ?? item.provider {
            case .local?:
                local += 1
                if let m = execution?.model, !m.isEmpty { localModels[m, default: 0] += 1 }
            case .cloud?:
                cloud += 1
                if let m = execution?.model, !m.isEmpty { cloudModels[m, default: 0] += 1 }
            case nil:
                break
            }
        }
        let finished = !jobs.isEmpty && jobs.allSatisfy { $0.endedAt != nil }
        let finishedAt = finished ? jobs.compactMap(\.endedAt).max() : nil
        let durations = jobs.compactMap { job -> TimeInterval? in
            guard let start = job.startedAt, let end = job.endedAt, end >= start else { return nil }
            return end.timeIntervalSince(start)
        }
        let duration = finished && durations.count == jobs.count ? durations.reduce(0, +) : nil
        return RunInfo(localEmails: local, cloudEmails: cloud, localModel: mostCommon(localModels),
                       cloudModel: mostCommon(cloudModels), finishedAt: finishedAt, duration: duration)
    }

    /// The most frequent key; ties go to the alphabetically first, so the result is stable.
    private static func mostCommon(_ counts: [String: Int]) -> String? {
        counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }
}

/// The text of Today's run line.
public enum RunLine {
    /// "Processed on this Mac with Qwen3 4B", "On this Mac and Gemini (3 emails)" or "Processed with Gemini 3.5
    /// Flash-Lite (3 emails)". Nil when no email recorded how it was processed.
    public static func processingText(_ info: RunInfo) -> String? {
        let count = info.cloudEmails
        let emails = "\(count) \(count == 1 ? "email" : "emails")"
        switch (info.localEmails > 0, info.cloudEmails > 0) {
        case (false, false):
            return nil
        case (true, false):
            guard let model = info.localModel else { return "Processed on this Mac" }
            return "Processed on this Mac with \(RoutingPresentation.modelDisplayName(model))"
        case (true, true):
            return "On this Mac and Gemini (\(emails))"
        case (false, true):
            let model = info.cloudModel.map(RoutingPresentation.modelDisplayName) ?? "Gemini"
            return "Processed with \(model) (\(emails))"
        }
    }

    /// "Finished 7:28 am · 46 min"; nil while the run has no end time.
    public static func timingText(_ info: RunInfo, calendar: Calendar, locale: Locale = Locale(identifier: "en_AU")) -> String? {
        guard let finished = info.finishedAt else { return nil }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        let time = finished.formatted(style)
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
        var text = "Finished \(time)"
        if let duration = info.duration { text += " · \(durationText(duration))" }
        return text
    }

    /// "under a minute", "46 min", "2 h" or "1 h 5 min".
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let (h, m) = minutes.quotientAndRemainder(dividingBy: 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
