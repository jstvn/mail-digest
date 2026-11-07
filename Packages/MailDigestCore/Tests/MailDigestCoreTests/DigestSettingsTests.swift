import Foundation
import Testing
@testable import MailDigestCore

@Suite struct DigestSettingsTests {
    @Test func defaultsMatchSpec() {
        let s = DigestSettings()
        #expect(s.runHour == 6 && s.runMinute == 30)
        #expect(s.lookbackHours == 48)
        #expect(s.maxEmailsPerRun == nil)
        #expect(s.ollamaURL == "http://localhost:11434")
        #expect(s.ollamaModel == "qwen3:4b")
        #expect(s.remindersListName == "Mail Digest")
        #expect(s.retention == .ninetyDays)
        #expect(s.dailyMailboxes.isEmpty)
        #expect(s.vipSenders.isEmpty && s.blockedSenders.isEmpty && s.ignoredSenders.isEmpty
            && s.trustedNewsletterSenders.isEmpty)
    }

    @Test func codableRoundTripAndTolerantDecode() throws {
        var s = DigestSettings()
        s.runHour = 7; s.maxEmailsPerRun = 80; s.retention = .oneYear
        s.vipSenders = ["a@b.com"]; s.trustedNewsletterSenders = ["n@x.com"]
        s.dailyMailboxes = [MailboxRef(account: "iCloud", name: "Inbox")]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(DigestSettings.self, from: data) == s)
        // An older blob with only some keys keeps defaults for the rest.
        let partial = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"runHour":8}"#.utf8))
        #expect(partial.runHour == 8 && partial.runMinute == 30 && partial.ollamaModel == "qwen3:4b")
    }

    @Test func autoFileIsOffByDefaultAndDecodesTolerantly() throws {
        #expect(DigestSettings().autoFileProcessed == false)
        let old = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"runHour":7}"#.utf8))
        #expect(old.autoFileProcessed == false && old.runHour == 7)
        var on = DigestSettings()
        on.autoFileProcessed = true
        let round = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(on))
        #expect(round.autoFileProcessed)
    }

    @Test func olderSavedSettingsDecodeWithoutDeclinedSuggestions() throws {
        // A blob saved before T16 has no `declinedIgnoreSuggestions` key but keeps every other value.
        let old = #"{"runHour":7,"ignoredSenders":["a@b.com"],"vipSenders":["v@b.com"]}"#
        let s = try JSONDecoder().decode(DigestSettings.self, from: Data(old.utf8))
        #expect(s.declinedIgnoreSuggestions.isEmpty && s.runHour == 7 && s.ignoredSenders == ["a@b.com"])
        var withDeclined = s
        withDeclined.declinedIgnoreSuggestions = ["x@y.com"]
        let round = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(withDeclined))
        #expect(round.declinedIgnoreSuggestions == ["x@y.com"])
    }

    @Test func autoFileStampFollowsTheSwitch() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var s = DigestSettings()
        let off = s
        s.autoFileProcessed = true
        s.stampAutoFile(previous: off, now: t)
        #expect(s.autoFileEnabledAt == t)
        // Staying on keeps the first stamp.
        let on = s
        s.lookbackHours = 12
        s.stampAutoFile(previous: on, now: t.addingTimeInterval(60))
        #expect(s.autoFileEnabledAt == t)
        // Settings saved before Q42 (on, no stamp) are stamped when loaded, so nothing older is swept.
        var legacy = DigestSettings(autoFileProcessed: true)
        legacy.stampAutoFile(previous: nil, now: t)
        #expect(legacy.autoFileEnabledAt == t)
        // Switching off clears it; it round-trips through JSON.
        let round = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(round.autoFileEnabledAt == t)
        s.autoFileProcessed = false
        s.stampAutoFile(previous: on, now: t)
        #expect(s.autoFileEnabledAt == nil)
    }

    @Test func mapsIntoRunnerSettings() {
        var s = DigestSettings()
        s.lookbackHours = 24; s.maxEmailsPerRun = 50
        s.blockedSenders = ["Spam <SPAM@x.com>"]; s.vipSenders = ["boss@work.com"]
        s.trustedNewsletterSenders = ["Uni News <News@Uni.edu>"]
        let inbox = MailboxRef(account: "iCloud", name: "Inbox")
        let r = s.runnerSettings(inboxes: [inbox])
        #expect(r.lookbackCap == 24 * 3600 && r.maxEmailsPerRun == 50)
        #expect(r.dailyMailboxes == [inbox])
        #expect(r.timeZone == RunnerSettings().timeZone)
        #expect(r.filter.blockedSenders == ["spam@x.com"] && r.filter.vipSenders == ["boss@work.com"])
        #expect(r.filter.trustedNewsletterSenders == ["news@uni.edu"])
        let other = MailboxRef(account: "Outlook", name: "Inbox")
        s.dailyMailboxes = [other]
        #expect(s.runnerSettings(inboxes: [inbox]).dailyMailboxes == [other])
        s.maxEmailsPerRun = 0
        #expect(s.runnerSettings(inboxes: []).maxEmailsPerRun == nil)
    }

    @Test func resolvesBadInputToDefaults() {
        var s = DigestSettings()
        s.ollamaURL = "not a url"; s.ollamaModel = "  "; s.remindersListName = ""
        #expect(s.resolvedOllamaURL.absoluteString == "http://localhost:11434")
        #expect(s.resolvedModel == "qwen3:4b" && s.resolvedListName == "Mail Digest")
        s.ollamaURL = "http://192.168.1.5:11434"; s.ollamaModel = "llama3"
        #expect(s.resolvedOllamaURL.host == "192.168.1.5" && s.resolvedModel == "llama3")
    }

    @Test func resourceRulesDefaultAndDecodeTolerantly() throws {
        let d = DigestSettings()
        #expect(d.pauseBacklogOnBattery && !d.quietHoursEnabled)
        #expect(d.quietHoursStartMinute == 22 * 60 && d.quietHoursEndMinute == 7 * 60)
        #expect(d.resourcePolicy().quietHours == nil)
        // An older blob keeps its values and gets the new defaults.
        let old = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"runHour":8}"#.utf8))
        #expect(old.runHour == 8 && old.pauseBacklogOnBattery && !old.quietHoursEnabled)
        var s = DigestSettings()
        s.pauseBacklogOnBattery = false
        s.quietHoursEnabled = true
        s.quietHoursStartMinute = 23 * 60
        let round = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
        let policy = round.resourcePolicy()
        #expect(!policy.pauseBacklogOnBattery && policy.quietHours == QuietHours(startMinute: 23 * 60, endMinute: 7 * 60))
        #expect(policy.timeZone.identifier == "Australia/Brisbane")
    }
}

@Suite struct CloudSettingsTests {
    @Test func olderBlobGetsCloudDefaults() throws {
        let old = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"runHour":8}"#.utf8))
        #expect(old.runHour == 8 && !old.cloudDigestEnabled)
        #expect(old.geminiModel == GeminiDefaults.model && old.triageModel == "kev:0.8b-q8_0")
        #expect(old.privacyThreshold == 0.90 && old.cloudPrivacyAcknowledgedRevision == nil)
    }

    @Test func cloudSettingsRoundTrip() throws {
        var s = DigestSettings()
        s.cloudDigestEnabled = true
        s.geminiModel = "m"
        s.triageModel = "tev1:0.8b"
        s.privacyThreshold = 0.95
        s.cloudPrivacyAcknowledgedRevision = 1
        #expect(try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func resolvedValuesFallBackAndClamp() {
        var s = DigestSettings()
        s.geminiModel = "  "; s.triageModel = ""; s.privacyThreshold = 0.5
        #expect(s.resolvedGeminiModel == GeminiDefaults.model && s.resolvedTriageModel == "kev:0.8b-q8_0")
        #expect(s.resolvedPrivacyThreshold == 0.80)
        s.privacyThreshold = .nan
        #expect(s.resolvedPrivacyThreshold == 0.90)
    }

    @Test func offReasonOrder() {
        var s = DigestSettings()
        #expect(CloudPrivacyPolicy.offReason(settings: s, hasKey: true) == .cloudDisabled)
        s.cloudDigestEnabled = true
        #expect(CloudPrivacyPolicy.offReason(settings: s, hasKey: true) == .acknowledgementRequired)
        s.cloudPrivacyAcknowledgedRevision = 0
        #expect(CloudPrivacyPolicy.offReason(settings: s, hasKey: true) == .acknowledgementRequired)
        s.cloudPrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentRevision
        #expect(CloudPrivacyPolicy.offReason(settings: s, hasKey: false) == .noCredential)
        #expect(CloudPrivacyPolicy.offReason(settings: s, hasKey: true) == nil)
        s.cloudPrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentRevision + 1
        #expect(CloudPrivacyPolicy.offReason(settings: s, hasKey: true) == nil)
    }

    @Test func triageModelsListed() {
        #expect(CloudPrivacyPolicy.triageModels.map(\.tag) == ["kev:0.8b-q8_0", "tev1:0.8b", "kev:4b-q4_K_M"])
    }
}
