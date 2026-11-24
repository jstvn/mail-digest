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

    @Test func senderLogosAreOffByDefaultAndOldBlobsStillDecode() throws {
        #expect(DigestSettings().showSenderLogos == false)
        let old = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"runHour":8,"vipSenders":["a@b.com"]}"#.utf8))
        #expect(old.showSenderLogos == false && old.runHour == 8 && old.vipSenders == ["a@b.com"])
        let on = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"showSenderLogos":true}"#.utf8))
        #expect(on.showSenderLogos)
        let bad = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"showSenderLogos":true,"future":1}"#.utf8))
        #expect(bad.showSenderLogos)
        var s = DigestSettings(); s.showSenderLogos = true
        #expect(try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s)).showSenderLogos)
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
        #expect(old.geminiModel == GeminiDefaults.model && old.triageModel == "kev:4b-q4_K_M")
        #expect(old.privacyThreshold == 0.85 && old.cloudPrivacyAcknowledgedRevision == nil)
    }

    @Test func privacyThresholdDefaultMigration() throws {
        func decode(_ json: String) throws -> DigestSettings {
            try JSONDecoder().decode(DigestSettings.self, from: Data(json.utf8))
        }
        #expect(DigestSettings().privacyThreshold == 0.85)
        #expect(try decode(#"{"privacyThreshold":0.9}"#).privacyThreshold == 0.85)
        #expect(try decode(#"{"privacyThreshold":0.9,"privacyThresholdDefaultRevision":1}"#).privacyThreshold == 0.85)
        #expect(try decode(#"{"privacyThreshold":0.9,"privacyThresholdDefaultRevision":2}"#).privacyThreshold == 0.9)
        #expect(try decode(#"{"privacyThreshold":0.93}"#).privacyThreshold == 0.93)
        #expect(try decode(#"{"runHour":7}"#).privacyThreshold == 0.85)
        let migrated = try decode(#"{"privacyThreshold":0.9}"#)
        #expect(migrated.privacyThresholdDefaultRevision == 2)
        let again = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(migrated))
        #expect(again == migrated && again.privacyThresholdDefaultRevision == 2)
    }

    @Test func cloudSettingsRoundTrip() throws {
        var s = DigestSettings()
        s.cloudDigestEnabled = true
        s.geminiModel = "m"
        s.triageModel = "tev1:0.8b-q8_0"
        s.privacyThreshold = 0.95
        s.cloudPrivacyAcknowledgedRevision = 1
        #expect(try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func resolvedValuesFallBackAndClamp() {
        var s = DigestSettings()
        s.geminiModel = "  "; s.triageModel = ""; s.privacyThreshold = 0.5
        #expect(s.resolvedGeminiModel == GeminiDefaults.model && s.resolvedTriageModel == "kev:4b-q4_K_M")
        #expect(s.resolvedPrivacyThreshold == 0.80)
        s.privacyThreshold = .nan
        #expect(s.resolvedPrivacyThreshold == 0.85)
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
        #expect(CloudPrivacyPolicy.triageModels.map(\.tag) == ["kev:4b-q4_K_M", "tev1:0.8b-q8_0"])
        #expect(CloudPrivacyPolicy.triageModels.map(\.displayName)
                == ["Kev 4B (Q4, default)", "Tev1 0.8B (Q8, low memory)"])
        #expect(DigestSettings.defaultTriageModel == "kev:4b-q4_K_M")
    }

    @Test func triageModelNotes() {
        #expect(CloudPrivacyPolicy.triageModelNote(for: "kev:4b-q4_K_M")
                == "Uses about 8.5 GB of memory while loaded, on top of the digest model. On a Mac with 16 GB, choose Tev1 0.8B if the system starts swapping.")
        #expect(CloudPrivacyPolicy.triageModelNote(for: "tev1:0.8b-q8_0")
                == "Uses much less memory than Kev 4B, but keeps more public emails on this Mac.")
        #expect(CloudPrivacyPolicy.triageModelNote(for: "kev:0.8b-q8_0") == nil)
        #expect(CloudPrivacyPolicy.triageModelNote(for: "other") == nil)
    }

    private func decode(_ json: String) throws -> DigestSettings {
        try JSONDecoder().decode(DigestSettings.self, from: Data(json.utf8))
    }

    @Test func retiredModelBeforeRevision2MigratesToDefault() throws {
        #expect(try decode(#"{"triageModel":"kev:0.8b-q8_0"}"#).triageModel == "kev:4b-q4_K_M")
        #expect(try decode(#"{"triageModel":"kev:0.8b-q8_0","triageModelDefaultRevision":1}"#).triageModel == "kev:4b-q4_K_M")
    }

    @Test func retiredModelAtRevision2MigratesToTev1() throws {
        let s = try decode(#"{"triageModel":"kev:0.8b-q8_0","triageModelDefaultRevision":2}"#)
        #expect(s.triageModel == "tev1:0.8b-q8_0" && s.triageModelDefaultRevision == 3)
    }

    @Test func otherChoicesAreNeverChanged() throws {
        #expect(try decode(#"{"triageModel":"kev:0.8b-q8_0","triageModelDefaultRevision":3}"#).triageModel == "kev:0.8b-q8_0")
        for revision in ["null", "1", "2", "3"] {
            let r = revision == "null" ? "" : #","triageModelDefaultRevision":\#(revision)"#
            for tag in ["kev:4b-q4_K_M", "tev1:0.8b-q8_0", "", "my:custom"] {
                #expect(try decode(#"{"triageModel":"\#(tag)"\#(r)}"#).triageModel == tag)
            }
        }
    }

    @Test func migratedSettingsRoundTrip() throws {
        let s = try decode(#"{"triageModel":"kev:0.8b-q8_0","triageModelDefaultRevision":2}"#)
        let again = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(again == s && again.triageModel == "tev1:0.8b-q8_0" && again.triageModelDefaultRevision == 3)
    }

    @Test func reminderDateSettingsDefaultAndDecodeTolerantly() throws {
        let d = DigestSettings()
        #expect(d.reminderDateMode == .planToday && d.reminderPlanHour == 20 && d.reminderPlanMinute == 0)
        #expect(d.autoAddSuggestedReminders == false)
        #expect(d.reminderDatePolicy == ReminderDatePolicy())
        let old = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"runHour":8}"#.utf8))
        #expect(old.reminderDateMode == .planToday && old.reminderPlanHour == 20 && !old.autoAddSuggestedReminders)
        let unknown = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"reminderDateMode":"nope"}"#.utf8))
        #expect(unknown.reminderDateMode == .planToday)
        var s = DigestSettings()
        s.reminderDateMode = .emailDeadline; s.reminderPlanHour = 7; s.reminderPlanMinute = 15
        s.autoAddSuggestedReminders = true
        let round = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
        #expect(round.reminderDatePolicy == ReminderDatePolicy(mode: .emailDeadline, planHour: 7, planMinute: 15))
    }
}
