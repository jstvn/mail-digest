import Testing
@testable import MailDigestCore

@Suite struct MailAccessStatusTests {
    static let fdaStates: [FullDiskAccessState] = [.granted, .denied, .mailDataMissing, .unsupportedStore, .busy, .unknown]
    static let autoStates: [AutomationState] = [.granted, .denied, .notDetermined, .mailNotRunning, .unknown]

    @Test func everyCombination() {
        for fda in Self.fdaStates {
            for auto in Self.autoStates {
                let s = MailAccessStatus(fullDiskAccess: fda, automation: auto)
                let expected: MailAccessMode
                if fda == .granted { expected = .fastLocal }
                else if auto == .denied || auto == .unknown { expected = .unavailable }
                else { expected = .automationFallback }
                #expect(s.mode == expected, "\(fda) \(auto)")
                #expect(s.showsAutomationBanner == (auto == .denied))
                #expect(s.showsFullDiskAccessNotice == (fda != .granted))
                #expect(s.canRequestAutomation == (auto == .notDetermined || auto == .mailNotRunning))
            }
        }
    }

    @Test func titles() {
        #expect(MailAccessMode.fastLocal.title == "Fast local access enabled")
        #expect(MailAccessMode.automationFallback.title == "Using Mail automation fallback")
        #expect(MailAccessMode.unavailable.title == "Mail access unavailable")
    }

    @Test func settingsURLs() {
        #expect(MailAccessStatus.fullDiskAccessSettingsURL.hasSuffix("Privacy_AllFiles"))
        #expect(MailAccessStatus.automationSettingsURL.hasSuffix("Privacy_Automation"))
    }
}
