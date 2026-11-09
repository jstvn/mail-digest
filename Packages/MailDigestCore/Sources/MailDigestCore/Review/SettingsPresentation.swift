import Foundation

/// Text and choices for the Settings window. Pure, so the choices and copy are testable.
public enum SettingsPresentation {
    /// The Look Back choices in the design.
    public static let lookbackChoices = [24, 48, 72]

    /// The Look Back popup's hours: the design's choices, plus the stored value when it is something else
    /// (the old stepper allowed 12 to 336 in steps of 12), so an existing setting is never silently changed.
    public static func lookbackOptions(current: Int) -> [Int] {
        lookbackChoices.contains(current) ? lookbackChoices : (lookbackChoices + [current]).sorted()
    }

    /// "48 Hours", "1 Hour".
    public static func lookbackTitle(_ hours: Int) -> String { "\(hours) \(hours == 1 ? "Hour" : "Hours")" }

    /// The Keep Digests and Activity For popup, in the design's order.
    public static let retentionChoices: [HistoryRetention] = [.thirtyDays, .ninetyDays, .oneYear, .forever]

    public static func retentionTitle(_ retention: HistoryRetention) -> String {
        switch retention {
        case .thirtyDays: "30 Days"
        case .ninetyDays: "90 Days"
        case .oneYear: "365 Days"
        case .forever: "Forever"
        }
    }

    /// "6:30 am", "10 pm": 12-hour time with a lowercase suffix, from minutes after midnight.
    public static func time(minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let hour = m / 60 % 12 == 0 ? 12 : m / 60 % 12
        let suffix = m < 720 ? "am" : "pm"
        return m % 60 == 0 ? "\(hour) \(suffix)" : "\(hour):" + String(format: "%02d", m % 60) + " \(suffix)"
    }

    /// Footnote under the Daily Digest rows. The scheduler also checks on wake, so a missed time runs at once.
    public static func runAtFootnote(hour: Int, minute: Int) -> String {
        "If your Mac is asleep at \(time(minutes: hour * 60 + minute)), the digest runs as soon as it wakes."
    }

    /// Subtitle of Only Run Overnight, naming the window as configured.
    public static func overnightSubtitle(startMinute: Int, endMinute: Int) -> String {
        "Backlog jobs run between \(time(minutes: startMinute)) and \(time(minutes: endMinute))."
    }
}

extension MailAccessPresentation {
    /// The one-line status for Settings > Mail: a title and a sentence, and whether it is a good state.
    public struct Summary: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var isReady: Bool
    }

    public var settingsSummary: Summary {
        switch header {
        case .ready:
            Summary(title: "Full Access", detail: "Full Disk Access and Mail Automation are on.", isReady: true)
        case .slowerMode:
            Summary(title: "Slower Mode", detail: "Full Disk Access is off, so Mail is asked for each email.", isReady: false)
        case .automationOff:
            Summary(title: "Automation Off", detail: "Mail Automation is off, so Mail Cleanup and Open in Mail can't work.", isReady: false)
        case .unavailable:
            Summary(title: "No Access", detail: "Turn on Full Disk Access or Mail Automation to read your mail.", isReady: false)
        }
    }
}

extension DailyMailboxSelection {
    /// The read-only "Daily Digest Reads" text for Settings, such as "All Inboxes" or "iCloud Inbox, Outlook Inbox".
    /// Edited in Mail Access. `available` is empty until the mailboxes have loaded, in which case the stored
    /// choices are described as they are.
    public static func summary(stored: [MailboxRef], available: [MailboxInfo]) -> String {
        if stored.isEmpty { return "All Inboxes" }
        let chosen: [MailboxRef]
        if available.isEmpty {
            chosen = stored
        } else {
            // Every stored mailbox is gone, so `effective` falls back to all inboxes.
            if Set(stored).isDisjoint(with: available.map(\.ref)) { return "All Inboxes" }
            let set = effective(stored: stored, available: available)
            // Keep the Mail Access list order so the text is stable.
            chosen = available.map(\.ref).filter { set.contains($0) }
        }
        let names = chosen.map { ref in
            "\(ref.account) \(ref.name.caseInsensitiveCompare("INBOX") == .orderedSame ? "Inbox" : ref.name)"
        }
        switch names.count {
        case 0: return "All Inboxes"
        case 1...3: return names.joined(separator: ", ")
        default: return "\(names.count) mailboxes"
        }
    }
}
