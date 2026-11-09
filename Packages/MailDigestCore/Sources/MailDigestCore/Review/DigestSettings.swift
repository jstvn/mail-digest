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
    /// When auto-file was last switched on. Only results finished after it are auto-filed, so switching it
    /// on never sweeps older mail (Q42). Nil while auto-file is off.
    public var autoFileEnabledAt: Date?
    /// Backlog jobs pause on battery power and resume when plugged in (default on).
    public var pauseBacklogOnBattery: Bool
    /// Backlog jobs only run inside the quiet-hours window (default off).
    public var quietHoursEnabled: Bool
    /// The allowed window, minutes after midnight in the app's time zone (default 10pm to 7am).
    public var quietHoursStartMinute: Int
    public var quietHoursEndMinute: Int
    /// Hybrid routing: send emails System One confirms as non-sensitive to Gemini. Off by default (Q63).
    public var cloudDigestEnabled: Bool
    public var geminiModel: String
    /// Local Ollama model that runs System One triage.
    public var triageModel: String
    /// Minimum non-sensitive confidence for cloud eligibility (`SystemOneSpec.thresholdRange`).
    public var privacyThreshold: Double
    /// The `CloudPrivacyPolicy` revision the user accepted; nil until they accept.
    public var cloudPrivacyAcknowledgedRevision: Int?

    /// Which triage-model strategy generation the stored value was written under.
    /// Revision 2 made Kev 4B the default (Kev 0.8B stayed as the low-memory option); revision 3 retired
    /// Kev 0.8B in favour of Tev1 0.8B. Values stored at revision 3 or later are never migrated.
    public var triageModelDefaultRevision: Int?

    public static let currentTriageModelDefaultRevision = 3
    /// The retired Kev 0.8B tag; only used to migrate stored settings.
    static let retiredTriageModel = "kev:0.8b-q8_0"
    static let lowMemoryTriageModel = "tev1:0.8b-q8_0"
    public static let defaultTriageModel = "kev:4b-q4_K_M"
    public static let defaultPrivacyThreshold = 0.90
    public static let defaultOllamaURL = "http://localhost:11434"
    public static let defaultModel = "qwen3:4b"
    public static let defaultListName = "Mail Digest"

    public init(runHour: Int = 6, runMinute: Int = 30, lookbackHours: Int = 48, maxEmailsPerRun: Int? = nil,
                ollamaURL: String = DigestSettings.defaultOllamaURL, ollamaModel: String = DigestSettings.defaultModel,
                remindersListName: String = DigestSettings.defaultListName,
                retention: HistoryRetention = .default, vipSenders: [String] = [], blockedSenders: [String] = [],
                ignoredSenders: [String] = [], trustedNewsletterSenders: [String] = [],
                declinedIgnoreSuggestions: [String] = [], dailyMailboxes: [MailboxRef] = [],
                autoFileProcessed: Bool = false, autoFileEnabledAt: Date? = nil, pauseBacklogOnBattery: Bool = true,
                quietHoursEnabled: Bool = false, quietHoursStartMinute: Int = 22 * 60,
                quietHoursEndMinute: Int = 7 * 60,
                cloudDigestEnabled: Bool = false, geminiModel: String = GeminiDefaults.model,
                triageModel: String = DigestSettings.defaultTriageModel,
                privacyThreshold: Double = DigestSettings.defaultPrivacyThreshold,
                cloudPrivacyAcknowledgedRevision: Int? = nil,
                triageModelDefaultRevision: Int? = DigestSettings.currentTriageModelDefaultRevision) {
        self.triageModelDefaultRevision = triageModelDefaultRevision
        self.cloudDigestEnabled = cloudDigestEnabled
        self.geminiModel = geminiModel
        self.triageModel = triageModel
        self.privacyThreshold = privacyThreshold
        self.cloudPrivacyAcknowledgedRevision = cloudPrivacyAcknowledgedRevision
        self.pauseBacklogOnBattery = pauseBacklogOnBattery
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStartMinute = quietHoursStartMinute
        self.quietHoursEndMinute = quietHoursEndMinute
        self.autoFileProcessed = autoFileProcessed
        self.autoFileEnabledAt = autoFileProcessed ? autoFileEnabledAt : nil
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
        case dailyMailboxes, autoFileProcessed, autoFileEnabledAt
        case pauseBacklogOnBattery, quietHoursEnabled, quietHoursStartMinute, quietHoursEndMinute
        case cloudDigestEnabled, geminiModel, triageModel, privacyThreshold, cloudPrivacyAcknowledgedRevision
        case triageModelDefaultRevision
    }

    /// Tolerant decoding: unknown or missing keys keep their defaults, so adding a setting never loses the rest.
    public init(from decoder: Decoder) throws {
        let d = DigestSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Kev 0.8B is retired. Before revision 2 it only reflected the old default, so it becomes the new default;
        // at revision 2 the user had kept it as the low-memory option, so it becomes Tev1. Anything else, and
        // anything stored at revision 3 or later, is left alone. The decoded value carries the current revision.
        var triage = try c.decodeIfPresent(String.self, forKey: .triageModel) ?? d.triageModel
        let storedRevision = try c.decodeIfPresent(Int.self, forKey: .triageModelDefaultRevision)
        if triage == Self.retiredTriageModel {
            switch storedRevision ?? 0 {
            case ..<2: triage = Self.defaultTriageModel
            case 2: triage = Self.lowMemoryTriageModel
            default: break
            }
        }
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
                  autoFileEnabledAt: try c.decodeIfPresent(Date.self, forKey: .autoFileEnabledAt),
                  pauseBacklogOnBattery: try c.decodeIfPresent(Bool.self, forKey: .pauseBacklogOnBattery)
                      ?? d.pauseBacklogOnBattery,
                  quietHoursEnabled: try c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? d.quietHoursEnabled,
                  quietHoursStartMinute: try c.decodeIfPresent(Int.self, forKey: .quietHoursStartMinute)
                      ?? d.quietHoursStartMinute,
                  quietHoursEndMinute: try c.decodeIfPresent(Int.self, forKey: .quietHoursEndMinute)
                      ?? d.quietHoursEndMinute,
                  cloudDigestEnabled: try c.decodeIfPresent(Bool.self, forKey: .cloudDigestEnabled)
                      ?? d.cloudDigestEnabled,
                  geminiModel: try c.decodeIfPresent(String.self, forKey: .geminiModel) ?? d.geminiModel,
                  triageModel: triage,
                  privacyThreshold: try c.decodeIfPresent(Double.self, forKey: .privacyThreshold)
                      ?? d.privacyThreshold,
                  cloudPrivacyAcknowledgedRevision: try c.decodeIfPresent(Int.self,
                                                                          forKey: .cloudPrivacyAcknowledgedRevision))
    }

    /// The Gemini model, or the default when blank.
    public var resolvedGeminiModel: String {
        let m = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? GeminiDefaults.model : m
    }

    /// The triage model, or the default when blank.
    public var resolvedTriageModel: String {
        let m = triageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? Self.defaultTriageModel : m
    }

    /// The threshold clamped into the allowed range (a non-finite value falls back to the default).
    public var resolvedPrivacyThreshold: Double {
        guard privacyThreshold.isFinite else { return Self.defaultPrivacyThreshold }
        return min(max(privacyThreshold, SystemOneSpec.thresholdRange.lowerBound), SystemOneSpec.thresholdRange.upperBound)
    }

    /// The resource rules these settings describe. Low Power Mode and serious heat always pause Backlog.
    public func resourcePolicy(timeZone: TimeZone? = nil) -> ResourcePolicy {
        ResourcePolicy(pauseBacklogOnBattery: pauseBacklogOnBattery,
                       quietHours: quietHoursEnabled
                           ? QuietHours(startMinute: quietHoursStartMinute, endMinute: quietHoursEndMinute) : nil,
                       timeZone: timeZone ?? RunnerSettings().timeZone,
                       overnightWindow: QuietHours(startMinute: quietHoursStartMinute, endMinute: quietHoursEndMinute))
    }

    /// The Ollama endpoint, or the default when the text isn't a usable http(s) URL.
    public var resolvedOllamaURL: URL {
        Self.usableOllamaURL(ollamaURL) ?? URL(string: Self.defaultOllamaURL)!
    }

    /// The URL in `text` when it is an http(s) address with a host, otherwise nil.
    public static func usableOllamaURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// The model name, or the default when blank.
    public var resolvedModel: String {
        let m = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? Self.defaultModel : m
    }

    /// Keeps `autoFileEnabledAt` in step with the auto-file switch: stamped with `now` when it is switched on
    /// (or is on without a stamp, as in settings saved before Q42), cleared when it is switched off.
    public mutating func stampAutoFile(previous: DigestSettings?, now: Date) {
        if !autoFileProcessed {
            autoFileEnabledAt = nil
        } else if previous?.autoFileProcessed != true || autoFileEnabledAt == nil {
            autoFileEnabledAt = now
        }
    }

    /// The Reminders list name, or the default when blank.
    public var resolvedListName: String {
        let n = remindersListName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? Self.defaultListName : n
    }

    /// Sender rules as a runner filter (blocked / VIP / ignored / Trusted Newsletter).
    public var mailFilter: MailFilter {
        MailFilter(blockedSenders: Set(blockedSenders.map(MailFilter.address(from:))),
                   ignoredSenders: Set(ignoredSenders.map(MailFilter.address(from:))),
                   vipSenders: Set(vipSenders.map(MailFilter.address(from:))),
                   trustedNewsletterSenders: Set(trustedNewsletterSenders.map(MailFilter.address(from:))))
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
