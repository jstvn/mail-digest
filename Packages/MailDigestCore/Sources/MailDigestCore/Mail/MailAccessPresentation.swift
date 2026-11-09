import Foundation

/// What the Mail Access window shows, derived from the two permissions. Pure.
public struct MailAccessPresentation: Sendable, Equatable {
    public enum Header: Sendable, Equatable {
        /// Full Disk Access and Automation are both on.
        case ready
        /// Full Disk Access is off but Mail can still be read through automation.
        case slowerMode
        /// Full Disk Access is on but Automation is not allowed (needed for Mail Cleanup).
        case automationOff
        /// Neither route works.
        case unavailable

        public var title: String {
            switch self {
            case .ready: "Mail Digest Can Read Your Mail"
            case .slowerMode: "Running in Slower Mode"
            case .automationOff: "Mail Automation Is Off"
            case .unavailable: "Mail Digest Can't Read Your Mail Yet"
            }
        }

        public var subtitle: String {
            switch self {
            case .ready:
                "Fast local access is on. Mail is read on this Mac and nothing is changed in Mail unless you use Mail Cleanup."
            case .slowerMode:
                "Without Full Disk Access, Mail Digest asks Mail for each email. Everything still works, it just takes longer on big inboxes."
            case .automationOff:
                "Reading is fast, but Mail Digest can't open emails in Mail or move them during Mail Cleanup until you allow automation."
            case .unavailable:
                "Turn on Full Disk Access or allow Mail Automation so Mail Digest can read your new mail."
            }
        }

        /// SF Symbol for the header tile.
        public var symbol: String { self == .ready ? "checkmark.shield" : "exclamationmark.triangle" }
        public var isReady: Bool { self == .ready }
    }

    /// What the Automation row's button does.
    public enum AutomationAction: Sendable, Equatable {
        case none
        /// Shows the system prompt (never asked yet, or Mail is not running).
        case request
        /// The user already said no, so only System Settings can change it.
        case openSettings
    }

    public var header: Header
    public var fullDiskAccessOn: Bool
    public var fullDiskAccessText: String
    /// Only offered when access is plainly off; "Mail data not found" can't be fixed by granting it.
    public var showsGrantAccess: Bool
    public var automationAllowed: Bool
    public var automationText: String
    public var automationAction: AutomationAction
    /// The "come back here" footnote shows while anything is missing.
    public var showsPermissionFootnote: Bool

    public init(_ status: MailAccessStatus) {
        let fda = status.fullDiskAccess == .granted
        let auto = status.automation == .granted
        switch (fda, auto, status.mode) {
        case (true, true, _): header = .ready
        case (true, false, _): header = .automationOff
        case (false, _, .unavailable): header = .unavailable
        default: header = .slowerMode
        }
        fullDiskAccessOn = fda
        switch status.fullDiskAccess {
        case .granted: fullDiskAccessText = "On"
        case .denied: fullDiskAccessText = "Off"
        case .mailDataMissing, .unsupportedStore, .busy, .unknown: fullDiskAccessText = "Unavailable"
        }
        showsGrantAccess = status.fullDiskAccess == .denied
        automationAllowed = auto
        switch status.automation {
        case .granted: automationText = "Allowed"
        case .unknown: automationText = "Unknown"
        case .denied, .notDetermined, .mailNotRunning: automationText = "Not Allowed"
        }
        switch status.automation {
        case .notDetermined, .mailNotRunning: automationAction = .request
        case .denied: automationAction = .openSettings
        case .granted, .unknown: automationAction = .none
        }
        showsPermissionFootnote = !(fda && auto)
    }
}

/// How the Daily Digest Reads list maps onto `DigestSettings.dailyMailboxes`. Pure.
///
/// An empty stored list means "every account's Inbox" (the default), so those inboxes show ticked.
/// Choosing exactly the full set of inboxes stores an empty list again, so new accounts keep being included.
public enum DailyMailboxSelection {
    /// The inboxes in `boxes`, in the order given.
    public static func inboxes(_ boxes: [MailboxInfo]) -> [MailboxRef] {
        boxes.filter { $0.kind == .inbox }.map(\.ref)
    }

    /// The mailboxes the daily run reads, as far as the list can show. A stored mailbox that no longer exists
    /// is ignored; if none of the stored choices exist any more, the default (all inboxes) applies.
    public static func effective(stored: [MailboxRef], available: [MailboxInfo]) -> Set<MailboxRef> {
        let existing = Set(available.map(\.ref))
        let allInboxes = Set(inboxes(available))
        if stored.isEmpty { return allInboxes }
        let kept = Set(stored).intersection(existing)
        return kept.isEmpty ? allInboxes : kept
    }

    /// The list to store after the user ticks or unticks `ref`. Returns the current stored value when the change
    /// would leave nothing selected (an empty list would silently mean "all inboxes").
    public static func toggled(_ ref: MailboxRef, on: Bool, stored: [MailboxRef], available: [MailboxInfo]) -> [MailboxRef] {
        var chosen = effective(stored: stored, available: available)
        if on { chosen.insert(ref) } else { chosen.remove(ref) }
        if chosen.isEmpty { return stored }
        let allInboxes = Set(inboxes(available))
        if chosen == allInboxes { return [] }
        // Keep the mailbox list's order so the stored value is stable.
        return available.map(\.ref).filter { chosen.contains($0) }
    }

    /// Whether the checkbox for `ref` may be unticked: the last ticked mailbox stays on.
    public static func canUntick(_ ref: MailboxRef, stored: [MailboxRef], available: [MailboxInfo]) -> Bool {
        let chosen = effective(stored: stored, available: available)
        return !(chosen.contains(ref) && chosen.count == 1)
    }

    /// The Inbox rows, plus the other mailboxes that hold mail. Empty, system and Junk/Sent/Drafts/Trash
    /// folders stay hidden (`MailboxTree.partition`).
    public struct Rows: Sendable, Equatable {
        public var inboxes: [MailboxTreeRow]
        public var others: [MailboxTreeAccount]
        public var otherCount: Int { others.reduce(0) { $0 + $1.rows.count } }
    }

    public static func rows(_ boxes: [MailboxInfo]) -> Rows {
        let partition = MailboxTree.partition(boxes)
        let inboxes = partition.useful.flatMap(\.rows).filter { $0.info.kind == .inbox }
        let others = partition.useful.compactMap { account -> MailboxTreeAccount? in
            let rows = account.rows.filter { $0.info.kind != .inbox }
            return rows.isEmpty ? nil : MailboxTreeAccount(account: account.account, rows: rows)
        }
        return Rows(inboxes: inboxes, others: others)
    }

    /// "Inbox · iCloud" or "Projects/2026 · iCloud".
    public static func label(_ row: MailboxTreeRow) -> String {
        let name = row.depth == 0 ? MailboxTree.displayTitle(row) : row.info.ref.name
        return "\(name) · \(row.info.ref.account)"
    }
}

/// The footer text of the Mail Access window. Pure; the caller supplies the time and calendar.
public enum MailAccessCheckedText {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Checked just now" for a minute, then "Checked 8:10 pm" (12-hour, lowercase), with the date added
    /// when the check was on an earlier day ("Checked 8 Nov, 8:10 pm").
    public static func text(checkedAt: Date?, now: Date, calendar: Calendar) -> String {
        guard let checkedAt else { return "Not checked yet" }
        if now.timeIntervalSince(checkedAt) < 60 && now >= checkedAt { return "Checked just now" }
        let p = calendar.dateComponents([.hour, .minute, .day, .month], from: checkedAt)
        let hour = p.hour ?? 0, minute = p.minute ?? 0
        let clock = "\(hour % 12 == 0 ? 12 : hour % 12):\(minute < 10 ? "0" : "")\(minute) \(hour < 12 ? "am" : "pm")"
        if calendar.isDate(checkedAt, inSameDayAs: now) { return "Checked \(clock)" }
        let month = months[max(0, min(11, (p.month ?? 1) - 1))]
        return "Checked \(p.day ?? 1) \(month), \(clock)"
    }
}
