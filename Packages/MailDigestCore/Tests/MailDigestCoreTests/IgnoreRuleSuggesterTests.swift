import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func decisions(_ n: Int, action: SuggestionStatus = .dismissed, sender: String = "promo@shop.com") -> [Decision] {
    (0..<n).map { _ in Decision(suggestionID: UUID(), sender: sender, action: action, decidedAt: t0) }
}

@Suite struct IgnoreRuleSuggesterTests {
    private let settings = DigestSettings()

    @Test func thresholdIsFiveDismissals() {
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: decisions(4), settings: settings) == nil)
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: decisions(5), settings: settings)
            == IgnoreSuggestion(sender: "promo@shop.com", dismissedCount: 5))
    }

    @Test func approvalsAreNotCounted() {
        let mixed = decisions(4) + decisions(3, action: .approved)
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: mixed, settings: settings) == nil)
        // Approvals do not reset the count either.
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: decisions(5) + decisions(2, action: .approved),
                                               settings: settings)?.dismissedCount == 5)
    }

    @Test func excludesIgnoredBlockedAndVIPButNotTrustedNewsletter() {
        for keyPath in [\DigestSettings.ignoredSenders, \.blockedSenders, \.vipSenders, \.declinedIgnoreSuggestions] {
            var s = settings
            s[keyPath: keyPath] = ["Shop <PROMO@shop.com>"]
            #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: decisions(6), settings: s) == nil)
        }
        var trusted = settings
        trusted.trustedNewsletterSenders = ["promo@shop.com"]
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: decisions(5), settings: trusted) != nil)
    }

    @Test func normalisesAddresses() {
        let result = IgnoreRuleSuggester.suggestion(for: "Shop <Promo@Shop.com>", decisions: decisions(5, sender: "PROMO@shop.com"),
                                                    settings: settings)
        #expect(result?.sender == "promo@shop.com")
        // Other senders' decisions do not count (exact matching).
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: decisions(5, sender: "other@shop.com"),
                                               settings: settings) == nil)
    }

    @Test func duplicateRowsForOneSuggestionCountOnce() {
        let d = Decision(suggestionID: UUID(), sender: "promo@shop.com", action: .dismissed, decidedAt: t0)
        #expect(IgnoreRuleSuggester.suggestion(for: "promo@shop.com", decisions: Array(repeating: d, count: 5), settings: settings) == nil)
    }
}
