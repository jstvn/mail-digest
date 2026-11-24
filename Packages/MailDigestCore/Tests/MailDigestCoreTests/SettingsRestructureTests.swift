import Foundation
import Testing
@testable import MailDigestCore

/// Phase 6 (Settings restructure): the move must keep every stored setting, and the new pure helpers must
/// say what the code really does.
@Suite struct SettingsRestructureTests {
    // MARK: Migration

    /// A blob written by the app before the redesign, with every key the old tabs edited.
    private static let oldBlob = #"""
    {
      "runHour": 7, "runMinute": 15, "lookbackHours": 60, "maxEmailsPerRun": 120,
      "ollamaURL": "http://192.168.1.5:11434", "ollamaModel": "llama3.2:3b",
      "remindersListName": "Uni Mail", "retention": "oneYear",
      "vipSenders": ["boss@work.example"], "blockedSenders": ["spam@bad.example"],
      "ignoredSenders": ["deals@shop.example", "@legacy.example"],
      "trustedNewsletterSenders": ["news@paper.example"],
      "declinedIgnoreSuggestions": ["x@y.example"],
      "dailyMailboxes": [{"account": "iCloud", "name": "Inbox"}],
      "autoFileProcessed": false, "pauseBacklogOnBattery": false,
      "quietHoursEnabled": true, "quietHoursStartMinute": 1380, "quietHoursEndMinute": 360,
      "cloudDigestEnabled": true, "geminiModel": "gemini-custom-model", "triageModel": "tev1:0.8b-q8_0",
      "privacyThreshold": 0.95, "cloudPrivacyAcknowledgedRevision": 1, "triageModelDefaultRevision": 3
    }
    """#

    @Test func oldBlobDecodesToTheSameValues() throws {
        let s = try JSONDecoder().decode(DigestSettings.self, from: Data(Self.oldBlob.utf8))
        #expect(s.runHour == 7 && s.runMinute == 15)
        #expect(s.lookbackHours == 60 && s.maxEmailsPerRun == 120)
        #expect(s.ollamaURL == "http://192.168.1.5:11434" && s.ollamaModel == "llama3.2:3b")
        #expect(s.remindersListName == "Uni Mail" && s.retention == .oneYear)
        #expect(s.vipSenders == ["boss@work.example"] && s.blockedSenders == ["spam@bad.example"])
        #expect(s.ignoredSenders == ["deals@shop.example", "@legacy.example"])
        #expect(s.trustedNewsletterSenders == ["news@paper.example"])
        #expect(s.declinedIgnoreSuggestions == ["x@y.example"])
        #expect(s.dailyMailboxes == [MailboxRef(account: "iCloud", name: "Inbox")])
        #expect(s.autoFileProcessed == false && s.pauseBacklogOnBattery == false)
        #expect(s.quietHoursEnabled && s.quietHoursStartMinute == 1380 && s.quietHoursEndMinute == 360)
        #expect(s.cloudDigestEnabled && s.geminiModel == "gemini-custom-model" && s.triageModel == "tev1:0.8b-q8_0")
        #expect(s.privacyThreshold == 0.95 && s.cloudPrivacyAcknowledgedRevision == 1)
        // Saving again and reading back changes nothing.
        let again = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(again == s)
    }

    @Test func everyEncodedKeyIsStillAKey() throws {
        // A fully populated blob has exactly these JSON keys; adding one (showSenderLogos) is a deliberate change.
        var full = DigestSettings()
        full.maxEmailsPerRun = 50
        full.autoFileProcessed = true
        full.autoFileEnabledAt = Date(timeIntervalSince1970: 1_800_000_000)
        full.cloudPrivacyAcknowledgedRevision = 1
        // A nil provider is still written (as null) so it cannot be mistaken for a pre-Q93 blob.
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any]
        #expect(Set(keys?.keys ?? [:].keys) == [
            "maxEmailsPerRun", "autoFileEnabledAt", "runHour", "runMinute", "lookbackHours", "ollamaURL", "ollamaModel", "remindersListName", "retention",
            "vipSenders", "blockedSenders", "ignoredSenders", "trustedNewsletterSenders", "declinedIgnoreSuggestions",
            "dailyMailboxes", "autoFileProcessed", "pauseBacklogOnBattery", "quietHoursEnabled", "localProvider",
            "quietHoursStartMinute", "quietHoursEndMinute", "cloudDigestEnabled", "geminiModel", "triageModel", "cloudProvider", "claudeCodeModel",
            "privacyThreshold", "cloudPrivacyAcknowledgedRevision", "triageModelDefaultRevision", "showSenderLogos",
            "privacyThresholdDefaultRevision", "autoFileHandledDestination", "autoFileDismissedDestination",
            "reminderDateMode", "reminderPlanHour", "reminderPlanMinute", "autoAddSuggestedReminders",
        ])
    }

    // MARK: Look Back, retention, time text

    @Test func lookbackKeepsAnUnlistedStoredValueSelectable() {
        #expect(SettingsPresentation.lookbackOptions(current: 48) == [24, 48, 72])
        #expect(SettingsPresentation.lookbackOptions(current: 60) == [24, 48, 60, 72])
        #expect(SettingsPresentation.lookbackOptions(current: 336) == [24, 48, 72, 336])
        #expect(SettingsPresentation.lookbackTitle(48) == "48 Hours")
        #expect(SettingsPresentation.lookbackTitle(1) == "1 Hour")
    }

    @Test func retentionChoicesCoverEveryCase() {
        #expect(Set(SettingsPresentation.retentionChoices) == Set(HistoryRetention.allCases))
        #expect(SettingsPresentation.retentionChoices.map(SettingsPresentation.retentionTitle)
            == ["30 Days", "90 Days", "365 Days", "Forever"])
    }

    @Test func timeText() {
        #expect(SettingsPresentation.time(minutes: 6 * 60 + 30) == "6:30 am")
        #expect(SettingsPresentation.time(minutes: 22 * 60) == "10 pm")
        #expect(SettingsPresentation.time(minutes: 0) == "12 am")
        #expect(SettingsPresentation.time(minutes: 12 * 60) == "12 pm")
        #expect(SettingsPresentation.time(minutes: 12 * 60 + 5) == "12:05 pm")
        #expect(SettingsPresentation.runAtFootnote(hour: 6, minute: 30)
            == "If your Mac is asleep at 6:30 am, the digest runs as soon as it wakes.")
        #expect(SettingsPresentation.overnightSubtitle(startMinute: 22 * 60, endMinute: 7 * 60)
            == "Backlog jobs run between 10 pm and 7 am.")
    }

    @Test func ollamaURLValidationMatchesTheResolvedURL() {
        #expect(DigestSettings.usableOllamaURL("http://localhost:11434")?.host == "localhost")
        #expect(DigestSettings.usableOllamaURL("  https://example.com ") != nil)
        #expect(DigestSettings.usableOllamaURL("localhost:11434") == nil)
        #expect(DigestSettings.usableOllamaURL("ftp://example.com") == nil)
        #expect(DigestSettings.usableOllamaURL("") == nil)
        var s = DigestSettings()
        s.ollamaURL = "nonsense"
        #expect(s.resolvedOllamaURL.absoluteString == DigestSettings.defaultOllamaURL)
    }

    // MARK: Mail tab

    @Test func mailStatusSummary() {
        func summary(_ f: FullDiskAccessState, _ a: AutomationState) -> MailAccessPresentation.Summary {
            MailAccessPresentation(MailAccessStatus(fullDiskAccess: f, automation: a)).settingsSummary
        }
        #expect(summary(.granted, .granted) == .init(title: "Full Access",
                                                      detail: "Full Disk Access and Mail Automation are on.", isReady: true))
        #expect(summary(.denied, .granted).isReady == false && summary(.denied, .granted).title == "Slower Mode")
        #expect(summary(.granted, .denied).title == "Automation Off")
        #expect(summary(.denied, .denied).title == "No Access")
    }

    @Test func dailyReadsSummary() {
        let icloud = MailboxRef(account: "iCloud", name: "INBOX")
        let outlook = MailboxRef(account: "Outlook", name: "Inbox")
        let projects = MailboxRef(account: "iCloud", name: "Projects")
        let boxes = [MailboxInfo(ref: icloud, messageCount: 1, unreadCount: 0, kind: .inbox),
                     MailboxInfo(ref: outlook, messageCount: 1, unreadCount: 0, kind: .inbox),
                     MailboxInfo(ref: projects, messageCount: 1, unreadCount: 0, kind: .custom)]
        #expect(DailyMailboxSelection.summary(stored: [], available: boxes) == "All Inboxes")
        #expect(DailyMailboxSelection.summary(stored: [], available: []) == "All Inboxes")
        #expect(DailyMailboxSelection.summary(stored: [icloud, outlook], available: boxes) == "iCloud Inbox, Outlook Inbox")
        #expect(DailyMailboxSelection.summary(stored: [outlook, projects], available: boxes) == "Outlook Inbox, iCloud Projects")
        // Mailboxes not loaded yet: the stored choices are described as they are.
        #expect(DailyMailboxSelection.summary(stored: [outlook], available: []) == "Outlook Inbox")
        // Every stored mailbox has gone, so the default applies.
        #expect(DailyMailboxSelection.summary(stored: [MailboxRef(account: "Old", name: "Inbox")], available: boxes) == "All Inboxes")
        let many = (0..<5).map { MailboxRef(account: "A\($0)", name: "Inbox") }
        let manyInfo = many.map { MailboxInfo(ref: $0, messageCount: 1, unreadCount: 0, kind: .custom) }
        #expect(DailyMailboxSelection.summary(stored: Array(many.prefix(4)), available: manyInfo) == "4 mailboxes")
    }

    // MARK: Senders

    /// `#expect` can't call a mutating method directly.
    private static func add(_ s: inout DigestSettings, _ sender: String, _ list: SenderList) -> Bool {
        s.add(sender: sender, to: list)
    }

    @Test func addingNormalisesDeduplicatesAndRejectsInvalidEntries() {
        var s = DigestSettings()
        #expect(Self.add(&s, "Jacob Harland <Jacob@Example.com>", .vip))
        #expect(s.vipSenders == ["jacob@example.com"])
        #expect(!Self.add(&s, "jacob@example.com", .vip))
        #expect(!Self.add(&s, "@", .vip))
        #expect(!Self.add(&s, "@com", .vip))
        #expect(!Self.add(&s, "no-at-sign", .blocked))
        #expect(!Self.add(&s, "a@", .blocked))
        #expect(!Self.add(&s, "a b@x.com", .blocked))
        #expect(s.blockedSenders.isEmpty)
        #expect(Self.add(&s, "jacob@example.com", .ignored))
        #expect(s.contains(sender: "Jacob <jacob@example.com>", in: .ignored))
        #expect(Self.add(&s, "@Example.com", .vip))   // a whole domain is a valid rule
        #expect(s.vipSenders == ["jacob@example.com", "@example.com"])
        s.remove("JACOB@example.com", from: .vip)
        s.remove("@example.com", from: .vip)
        #expect(s.vipSenders.isEmpty && s.senders(in: .ignored) == ["jacob@example.com"])
    }

    @Test func eachListMapsToItsSettingsKey() {
        var s = DigestSettings()
        for list in SenderList.allCases { s.add(sender: "\(list.rawValue)@x.com", to: list) }
        #expect(s.vipSenders == ["vip@x.com"] && s.blockedSenders == ["blocked@x.com"])
        #expect(s.ignoredSenders == ["ignored@x.com"] && s.trustedNewsletterSenders == ["newsletters@x.com"])
    }

    @Test func precedenceFootnoteMatchesMailFilter() {
        func header(_ s: String) -> MessageHeader {
            MessageHeader(id: "1", account: "a", mailbox: "Inbox", sender: s, subject: "s", receivedAt: Date())
        }
        func filter(_ lists: [SenderList]) -> MailFilter {
            var s = DigestSettings()
            for list in lists { s.add(sender: "x@y.com", to: list) }
            return s.mailFilter
        }
        let h = header("x@y.com")
        // Blocked beats VIP, Ignored beats nothing, VIP beats Ignored, Ignored beats Newsletters.
        #expect(filter([.blocked, .vip]).estimatedTier(for: h) == .skip)
        #expect(filter([.blocked, .newsletters]).estimatedTier(for: h) == .skip)
        #expect(filter([.vip, .ignored]).estimatedTier(for: h) == .full)
        #expect(filter([.ignored, .newsletters]).estimatedTier(for: h) == .skip)
        #expect(filter([.vip, .newsletters]).estimatedTier(for: h) == .full)
        #expect(SenderList.precedenceFootnote.contains("Blocked wins, then VIP, then Ignored, then Newsletters"))
    }

    @Test func domainRuleInOldSettingsNowMatches() {
        var s = DigestSettings()
        s.ignoredSenders = ["@example.com"]   // saved by an older build, where it never matched
        let h = MessageHeader(id: "1", account: "a", mailbox: "Inbox", sender: "a@example.com", subject: "s", receivedAt: Date())
        #expect(s.mailFilter.estimatedTier(for: h) == .skip)
        #expect(DigestSettings.isMatchableAddress("@example.com"))
        #expect(SenderList.vip.summary.contains("Add a whole domain with @example.com."))
    }

    @Test func recentSendersRankByCountThenRecencyAndSkipListed() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ sender: String, _ ago: Double) -> JobItem {
            JobItem(id: UUID(), jobID: UUID(), messageID: UUID().uuidString, mailbox: MailboxRef(account: "a", name: "Inbox"),
                    sender: sender, subject: "s", receivedAt: t.addingTimeInterval(-ago), position: 1, state: .done,
                    outcome: nil, seconds: nil, attempts: 1, lastError: nil)
        }
        let items = [item("Ann <ann@x.com>", 10), item("bob@x.com", 5), item("Ann Lee <ANN@x.com>", 1),
                     item("carl@x.com", 100), item("noaddress", 1), item("listed@x.com", 1)]
        let ranked = RecentSender.rank(items, excluding: ["listed@x.com"])
        #expect(ranked.map(\.address) == ["ann@x.com", "bob@x.com", "carl@x.com"])
        #expect(ranked[0].count == 2 && ranked[0].name == "Ann Lee")
        #expect(RecentSender.rank(items, limit: 1).count == 1)
    }
}
