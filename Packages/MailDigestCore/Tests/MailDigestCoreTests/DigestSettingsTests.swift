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

    @Test func mapsIntoRunnerSettings() {
        var s = DigestSettings()
        s.lookbackHours = 24; s.maxEmailsPerRun = 50
        s.blockedSenders = ["Spam <SPAM@x.com>"]; s.vipSenders = ["boss@work.com"]
        let inbox = MailboxRef(account: "iCloud", name: "Inbox")
        let r = s.runnerSettings(inboxes: [inbox])
        #expect(r.lookbackCap == 24 * 3600 && r.maxEmailsPerRun == 50)
        #expect(r.dailyMailboxes == [inbox])
        #expect(r.timeZone == RunnerSettings().timeZone)
        #expect(r.filter.blockedSenders == ["spam@x.com"] && r.filter.vipSenders == ["boss@work.com"])
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
}
