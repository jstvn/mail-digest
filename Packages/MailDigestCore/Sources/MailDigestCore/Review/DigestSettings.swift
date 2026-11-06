import Foundation

/// The user's settings that exist today. Stored as one JSON blob by the app; every field has the spec's
/// default, and missing keys in older blobs fall back to it.
public struct DigestSettings: Codable, Sendable, Equatable {
    /// Local time of day for the scheduled Daily run (read by the morning scheduler).
    public var runHour: Int
    public var runMinute: Int
    /// Daily jobs never look further back than this many hours.
    public var lookbackHours: Int
    /// Newest emails kept per Daily run; nil means no cap.
    public var maxEmailsPerRun: Int?
    public var ollamaURL: String
    public var ollamaModel: String
    public var remindersListName: String
    public var retention: HistoryRetention
    public var vipSenders: [String]
    public var blockedSenders: [String]
    public var ignoredSenders: [String]
    public var trustedNewsletterSenders: [String]
    /// Senders the user told the app not to suggest ignoring again (normalised addresses).
    public var declinedIgnoreSuggestions: [String]
    /// Daily mailboxes. Empty means all inboxes.
    public var dailyMailboxes: [MailboxRef]
    /// Move processed emails into a "Mail Digest" mailbox in the same account automatically. Off by default.
    public var autoFileProcessed: Bool
    /// Backlog jobs pause on battery power and resume when plugged in (default on).
    public var pauseBacklogOnBattery: Bool
    /// Backlog jobs only run inside the quiet-hours window (default off).
    public var quietHoursEnabled: Bool
    /// The allowed window, minutes after midnight in the app's time zone (default 10pm to 7am).
    public var quietHoursStartMinute: Int
    public var quietHoursEndMinute: Int

    public static let defaultOllamaURL = "http://localhost:11434"
    public static let defaultModel = "qwen3:4b"
    public static let defaultListName = "Mail Digest"

    public init(runHour: Int = 6, runMinute: Int = 30, lookbackHours: Int = 48, maxEmailsPerRun: Int? = nil,
                ollamaURL: String = DigestSettings.defaultOllamaURL, ollamaModel: String = DigestSettings.defaultModel,
                remindersListName: String = DigestSettings.defaultListName,
                retention: HistoryRetention = .default, vipSenders: [String] = [], blockedSenders: [String] = [],
                ignoredSenders: [String] = [], trustedNewsletterSenders: [String] = [],
                declinedIgnoreSuggestions: [String] = [], dailyMailboxes: [MailboxRef] = [],
                autoFileProcessed: Bool = false, pauseBacklogOnBattery: Bool = true,
                quietHoursEnabled: Bool = false, quietHoursStartMinute: Int = 22 * 60,
                quietHoursEndMinute: Int = 7 * 60) {
        self.pauseBacklogOnBattery = pauseBacklogOnBattery
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStartMinute = quietHoursStartMinute
        self.quietHoursEndMinute = quietHoursEndMinute
        self.autoFileProcessed = autoFileProcessed
        self.runHour = runHour
        self.runMinute = runMinute
        self.lookbackHours = lookbackHours
        self.maxEmailsPerRun = maxEmailsPerRun
        self.ollamaURL = ollamaURL
        self.ollamaModel = ollamaModel
        self.remindersListName = remindersListName
        self.retention = retention
        self.vipSenders = vipSenders
        self.blockedSenders = blockedSenders
        self.ignoredSenders = ignoredSenders
        self.trustedNewsletterSenders = trustedNewsletterSenders
        self.declinedIgnoreSuggestions = declinedIgnoreSuggestions
        self.dailyMailboxes = dailyMailboxes
    }

    private enum CodingKeys: String, CodingKey {
        case runHour, runMinute, lookbackHours, maxEmailsPerRun, ollamaURL, ollamaModel, remindersListName
        case retention, vipSenders, blockedSenders, ignoredSenders, trustedNewsletterSenders, declinedIgnoreSuggestions
        case dailyMailboxes, autoFileProcessed
        case pauseBacklogOnBattery, quietHoursEnabled, quietHoursStartMinute, quietHoursEndMinute
    }

    /// Tolerant decoding: unknown or missing keys keep their defaults, so adding a setting never loses the rest.
    public init(from decoder: Decoder) throws {
        let d = DigestSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(runHour: try c.decodeIfPresent(Int.self, forKey: .runHour) ?? d.runHour,
                  runMinute: try c.decodeIfPresent(Int.self, forKey: .runMinute) ?? d.runMinute,
                  lookbackHours: try c.decodeIfPresent(Int.self, forKey: .lookbackHours) ?? d.lookbackHours,
                  maxEmailsPerRun: try c.decodeIfPresent(Int.self, forKey: .maxEmailsPerRun),
                  ollamaURL: try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL,
                  ollamaModel: try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel,
                  remindersListName: try c.decodeIfPresent(String.self, forKey: .remindersListName) ?? d.remindersListName,
                  retention: try c.decodeIfPresent(HistoryRetention.self, forKey: .retention) ?? d.retention,
                  vipSenders: try c.decodeIfPresent([String].self, forKey: .vipSenders) ?? [],
                  blockedSenders: try c.decodeIfPresent([String].self, forKey: .blockedSenders) ?? [],
                  ignoredSenders: try c.decodeIfPresent([String].self, forKey: .ignoredSenders) ?? [],
                  trustedNewsletterSenders: try c.decodeIfPresent([String].self, forKey: .trustedNewsletterSenders) ?? [],
                  declinedIgnoreSuggestions: try c.decodeIfPresent([String].self, forKey: .declinedIgnoreSuggestions) ?? [],
                  dailyMailboxes: try c.decodeIfPresent([MailboxRef].self, forKey: .dailyMailboxes) ?? [],
                  autoFileProcessed: try c.decodeIfPresent(Bool.self, forKey: .autoFileProcessed) ?? d.autoFileProcessed,
                  pauseBacklogOnBattery: try c.decodeIfPresent(Bool.self, forKey: .pauseBacklogOnBattery)
                      ?? d.pauseBacklogOnBattery,
                  quietHoursEnabled: try c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? d.quietHoursEnabled,
                  quietHoursStartMinute: try c.decodeIfPresent(Int.self, forKey: .quietHoursStartMinute)
                      ?? d.quietHoursStartMinute,
                  quietHoursEndMinute: try c.decodeIfPresent(Int.self, forKey: .quietHoursEndMinute)
                      ?? d.quietHoursEndMinute)
    }

    /// The resource rules these settings describe. Low Power Mode and serious heat always pause Backlog.
    public func resourcePolicy(timeZone: TimeZone? = nil) -> ResourcePolicy {
        ResourcePolicy(pauseBacklogOnBattery: pauseBacklogOnBattery,
                       quietHours: quietHoursEnabled
                           ? QuietHours(startMinute: quietHoursStartMinute, endMinute: quietHoursEndMinute) : nil,
                       timeZone: timeZone ?? RunnerSettings().timeZone)
    }

    /// The Ollama endpoint, or the default when the text isn't a usable http(s) URL.
    public var resolvedOllamaURL: URL {
        let fallback = URL(string: Self.defaultOllamaURL)!
        guard let url = URL(string: ollamaURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
        else { return fallback }
        return url
    }

    /// The model name, or the default when blank.
    public var resolvedModel: String {
        let m = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? Self.defaultModel : m
    }

    /// The Reminders list name, or the default when blank.
    public var resolvedListName: String {
        let n = remindersListName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? Self.defaultListName : n
    }

    /// Sender rules as a runner filter (VIP / blocked / ignored). Trusted Newsletter senders are not part of it.
    public var mailFilter: MailFilter {
        MailFilter(blockedSenders: Set(blockedSenders.map(MailFilter.address(from:))),
                   ignoredSenders: Set(ignoredSenders.map(MailFilter.address(from:))),
                   vipSenders: Set(vipSenders.map(MailFilter.address(from:))))
    }

    /// Maps into the runner's settings. `inboxes` is used when no Daily mailboxes are chosen (all inboxes).
    /// A nil `timeZone` keeps the runner's own default.
    public func runnerSettings(inboxes: [MailboxRef], timeZone: TimeZone? = nil) -> RunnerSettings {
        RunnerSettings(timeZone: timeZone ?? RunnerSettings().timeZone, filter: mailFilter,
                       dailyMailboxes: dailyMailboxes.isEmpty ? inboxes : dailyMailboxes,
                       lookbackCap: TimeInterval(max(lookbackHours, 1)) * 3600,
                       maxEmailsPerRun: maxEmailsPerRun.flatMap { $0 > 0 ? $0 : nil })
    }
}
