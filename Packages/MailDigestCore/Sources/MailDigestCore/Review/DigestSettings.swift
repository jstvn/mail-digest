import Foundation

/// Where auto-file moves an email (Q94). Both are `Mail.move`s that Undo can reverse; nothing is deleted.
public enum AutoFileDestination: String, Codable, Sendable, Equatable, CaseIterable {
    /// The "Mail Digest" mailbox in the message's own account.
    case mailDigest
    /// The account's Trash mailbox (`MailActions.moveToTrash`, Q40).
    case trash
}

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
    /// Q94: where auto-file puts emails with a reminder added, no suggestions, or blocked/ignored senders.
    public var autoFileHandledDestination: AutoFileDestination
    /// Q94: where auto-file puts emails whose suggestions were all dismissed.
    public var autoFileDismissedDestination: AutoFileDestination
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
    /// Which cloud provider Cloud Digest uses (Q93). Nil until the user chooses one; while nil nothing leaves this Mac.
    public var cloudProvider: CloudProvider?
    /// Claude Code model alias passed to `--model` (`haiku` or `sonnet`).
    public var claudeCodeModel: String
    /// The Claude Code notice revision the user accepted; nil until they accept (Q93).
    public var claudeCodePrivacyAcknowledgedRevision: Int?
    /// Fetch sender logos from the sender's own website (BIMI DNS, then apple-touch-icon). Off by default:
    /// the sender can see the user's IP address. Logos from a mail's BIMI header never need this.
    public var showSenderLogos: Bool

    /// Which triage-model strategy generation the stored value was written under.
    /// Revision 2 made Kev 4B the default (Kev 0.8B stayed as the low-memory option); revision 3 retired
    /// Kev 0.8B in favour of Tev1 0.8B. Values stored at revision 3 or later are never migrated.
    public var triageModelDefaultRevision: Int?

    /// Which privacy-threshold default generation the stored value was written under. Revision 2 lowered the
    /// default from 0.90 to 0.85 (Q91); a stored 0.90 below revision 2 only reflected the old default, so it
    /// migrates once. Any other value, and anything stored at revision 2 or later, is left alone.
    public var privacyThresholdDefaultRevision: Int?

    public static let currentTriageModelDefaultRevision = 3
    public static let currentPrivacyThresholdDefaultRevision = 2
    /// The retired Kev 0.8B tag; only used to migrate stored settings.
    static let retiredTriageModel = "kev:0.8b-q8_0"
    static let lowMemoryTriageModel = "tev1:0.8b-q8_0"
    public static let defaultTriageModel = "kev:4b-q4_K_M"
    /// Revision 2 lowered the default threshold from 0.90 to 0.85 (Q91).
    public static let defaultPrivacyThreshold = 0.85
    public static let defaultOllamaURL = "http://localhost:11434"
    public static let defaultClaudeCodeModel = "haiku"
    public static let defaultModel = "qwen3:4b"
    public static let defaultListName = "Mail Digest"

    public init(runHour: Int = 6, runMinute: Int = 30, lookbackHours: Int = 48, maxEmailsPerRun: Int? = nil,
                ollamaURL: String = DigestSettings.defaultOllamaURL, ollamaModel: String = DigestSettings.defaultModel,
                remindersListName: String = DigestSettings.defaultListName,
                retention: HistoryRetention = .default, vipSenders: [String] = [], blockedSenders: [String] = [],
                ignoredSenders: [String] = [], trustedNewsletterSenders: [String] = [],
                declinedIgnoreSuggestions: [String] = [], dailyMailboxes: [MailboxRef] = [],
                autoFileProcessed: Bool = false, autoFileEnabledAt: Date? = nil,
                autoFileHandledDestination: AutoFileDestination = .mailDigest,
                autoFileDismissedDestination: AutoFileDestination = .trash, pauseBacklogOnBattery: Bool = true,
                quietHoursEnabled: Bool = false, quietHoursStartMinute: Int = 22 * 60,
                quietHoursEndMinute: Int = 7 * 60,
                cloudDigestEnabled: Bool = false, geminiModel: String = GeminiDefaults.model,
                triageModel: String = DigestSettings.defaultTriageModel,
                privacyThreshold: Double = DigestSettings.defaultPrivacyThreshold,
                cloudPrivacyAcknowledgedRevision: Int? = nil,
                cloudProvider: CloudProvider? = nil,
                claudeCodeModel: String = DigestSettings.defaultClaudeCodeModel,
                claudeCodePrivacyAcknowledgedRevision: Int? = nil,
                triageModelDefaultRevision: Int? = DigestSettings.currentTriageModelDefaultRevision,
                showSenderLogos: Bool = false,
                privacyThresholdDefaultRevision: Int? = DigestSettings.currentPrivacyThresholdDefaultRevision) {
        self.privacyThresholdDefaultRevision = privacyThresholdDefaultRevision
        self.showSenderLogos = showSenderLogos
        self.triageModelDefaultRevision = triageModelDefaultRevision
        self.cloudDigestEnabled = cloudDigestEnabled
        self.geminiModel = geminiModel
        self.triageModel = triageModel
        self.privacyThreshold = privacyThreshold
        self.cloudPrivacyAcknowledgedRevision = cloudPrivacyAcknowledgedRevision
        self.cloudProvider = cloudProvider
        self.claudeCodeModel = claudeCodeModel
        self.claudeCodePrivacyAcknowledgedRevision = claudeCodePrivacyAcknowledgedRevision
        self.pauseBacklogOnBattery = pauseBacklogOnBattery
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStartMinute = quietHoursStartMinute
        self.quietHoursEndMinute = quietHoursEndMinute
        self.autoFileProcessed = autoFileProcessed
        self.autoFileHandledDestination = autoFileHandledDestination
        self.autoFileDismissedDestination = autoFileDismissedDestination
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
        case autoFileHandledDestination, autoFileDismissedDestination
        case pauseBacklogOnBattery, quietHoursEnabled, quietHoursStartMinute, quietHoursEndMinute
        case cloudDigestEnabled, geminiModel, triageModel, privacyThreshold, cloudPrivacyAcknowledgedRevision
        case triageModelDefaultRevision, showSenderLogos, privacyThresholdDefaultRevision
        case cloudProvider, claudeCodeModel, claudeCodePrivacyAcknowledgedRevision
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
        // A stored 0.90 below revision 2 was the old default, so it becomes 0.85. Other values are the user's choice.
        var threshold = try c.decodeIfPresent(Double.self, forKey: .privacyThreshold) ?? d.privacyThreshold
        let storedThresholdRevision = try c.decodeIfPresent(Int.self, forKey: .privacyThresholdDefaultRevision)
        if (storedThresholdRevision ?? 0) < Self.currentPrivacyThresholdDefaultRevision, abs(threshold - 0.90) < 1e-9 {
            threshold = Self.defaultPrivacyThreshold
        }
        // A present key is authoritative: null or an unknown value means no provider. Only a missing key (settings
        // saved before Q93) migrates, and only for a user who already accepted the Gemini notice.
        let acknowledged = try c.decodeIfPresent(Int.self, forKey: .cloudPrivacyAcknowledgedRevision)
        let provider: CloudProvider? = c.contains(.cloudProvider)
            ? (try? c.decode(CloudProvider?.self, forKey: .cloudProvider)) ?? nil
            : (acknowledged != nil ? .gemini : nil)
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
                  // An unknown stored value falls back to the default rather than failing the whole blob.
                  autoFileHandledDestination: (try? c.decodeIfPresent(AutoFileDestination.self,
                                                                      forKey: .autoFileHandledDestination))
                      ?? d.autoFileHandledDestination,
                  autoFileDismissedDestination: (try? c.decodeIfPresent(AutoFileDestination.self,
                                                                        forKey: .autoFileDismissedDestination))
                      ?? d.autoFileDismissedDestination,
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
                  privacyThreshold: threshold,
                  cloudPrivacyAcknowledgedRevision: try c.decodeIfPresent(Int.self,
                                                                          forKey: .cloudPrivacyAcknowledgedRevision),
                  cloudProvider: provider,
                  claudeCodeModel: try c.decodeIfPresent(String.self, forKey: .claudeCodeModel) ?? d.claudeCodeModel,
                  claudeCodePrivacyAcknowledgedRevision: try c.decodeIfPresent(
                      Int.self, forKey: .claudeCodePrivacyAcknowledgedRevision),
                  showSenderLogos: try c.decodeIfPresent(Bool.self, forKey: .showSenderLogos) ?? d.showSenderLogos)
    }

    /// Writes every key, including a nil `cloudProvider` as null: a missing key would be read back as a
    /// pre-Q93 blob and migrated to Gemini.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runHour, forKey: .runHour)
        try c.encode(runMinute, forKey: .runMinute)
        try c.encode(lookbackHours, forKey: .lookbackHours)
        try c.encodeIfPresent(maxEmailsPerRun, forKey: .maxEmailsPerRun)
        try c.encode(ollamaURL, forKey: .ollamaURL)
        try c.encode(ollamaModel, forKey: .ollamaModel)
        try c.encode(remindersListName, forKey: .remindersListName)
        try c.encode(retention, forKey: .retention)
        try c.encode(vipSenders, forKey: .vipSenders)
        try c.encode(blockedSenders, forKey: .blockedSenders)
        try c.encode(ignoredSenders, forKey: .ignoredSenders)
        try c.encode(trustedNewsletterSenders, forKey: .trustedNewsletterSenders)
        try c.encode(declinedIgnoreSuggestions, forKey: .declinedIgnoreSuggestions)
        try c.encode(dailyMailboxes, forKey: .dailyMailboxes)
        try c.encode(autoFileProcessed, forKey: .autoFileProcessed)
        try c.encodeIfPresent(autoFileEnabledAt, forKey: .autoFileEnabledAt)
        try c.encode(autoFileHandledDestination, forKey: .autoFileHandledDestination)
        try c.encode(autoFileDismissedDestination, forKey: .autoFileDismissedDestination)
        try c.encode(pauseBacklogOnBattery, forKey: .pauseBacklogOnBattery)
        try c.encode(quietHoursEnabled, forKey: .quietHoursEnabled)
        try c.encode(quietHoursStartMinute, forKey: .quietHoursStartMinute)
        try c.encode(quietHoursEndMinute, forKey: .quietHoursEndMinute)
        try c.encode(cloudDigestEnabled, forKey: .cloudDigestEnabled)
        try c.encode(geminiModel, forKey: .geminiModel)
        try c.encode(triageModel, forKey: .triageModel)
        try c.encode(privacyThreshold, forKey: .privacyThreshold)
        try c.encodeIfPresent(cloudPrivacyAcknowledgedRevision, forKey: .cloudPrivacyAcknowledgedRevision)
        try c.encodeIfPresent(triageModelDefaultRevision, forKey: .triageModelDefaultRevision)
        try c.encode(showSenderLogos, forKey: .showSenderLogos)
        try c.encodeIfPresent(privacyThresholdDefaultRevision, forKey: .privacyThresholdDefaultRevision)
        try c.encode(cloudProvider, forKey: .cloudProvider)
        try c.encode(claudeCodeModel, forKey: .claudeCodeModel)
        try c.encodeIfPresent(claudeCodePrivacyAcknowledgedRevision, forKey: .claudeCodePrivacyAcknowledgedRevision)
    }

    /// The Gemini model, or the default when blank.
    public var resolvedGeminiModel: String {
        let m = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? GeminiDefaults.model : m
    }

    /// The Claude Code model alias, or the default when blank.
    public var resolvedClaudeCodeModel: String {
        let m = claudeCodeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? Self.defaultClaudeCodeModel : m
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
