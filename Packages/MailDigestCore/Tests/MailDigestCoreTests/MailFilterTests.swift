import Foundation
import Testing
@testable import MailDigestCore

private func mail(_ sender: String, _ headers: [String: String] = [:]) -> EmailMessage {
    EmailMessage(id: "x", account: "a", mailbox: "Inbox", sender: sender, subject: "s",
                 receivedAt: Date(timeIntervalSince1970: 0), body: "b", headers: headers)
}

@Suite struct MailFilterTests {
    @Test func plainMailIsFull() {
        #expect(MailFilter().tier(mail("Sam <sam@example.com>")) == .full)
    }

    @Test func blockedIsSkip() {
        let f = MailFilter(blockedSenders: ["spam@x.com"])
        #expect(f.tier(mail("Spam <spam@x.com>")) == .skip)
        #expect(f.skipReason(mail("Spam <spam@x.com>")) == "blocked sender")
    }

    @Test func ignoredIsSkip() {
        let f = MailFilter(ignoredSenders: ["meh@x.com"])
        #expect(f.tier(mail("meh@x.com")) == .skip)
        #expect(f.skipReason(mail("meh@x.com")) == "ignored sender")
        #expect(f.skipReason(mail("other@x.com")) == nil)
    }

    // Q9: Blocked → VIP → Ignored → Trusted Newsletter → ordinary bulk → normal.
    @Test func blockBeatsVIP() {
        let f = MailFilter(blockedSenders: ["boss@x.com"], vipSenders: ["boss@x.com"])
        #expect(f.tier(mail("Boss <boss@x.com>")) == .skip)
        #expect(f.skipReason(mail("Boss <boss@x.com>")) == "blocked sender")
    }

    @Test func vipBeatsIgnoreAndBulk() {
        let f = MailFilter(ignoredSenders: ["boss@x.com"], vipSenders: ["boss@x.com"])
        #expect(f.tier(mail("Boss <boss@x.com>")) == .full)
        #expect(f.tier(mail("Boss <boss@x.com>", ["List-Unsubscribe": "<mailto:u@x.com>"])) == .full)
        #expect(f.skipReason(mail("boss@x.com")) == nil)
        // VIP keeps the ordinary limit even if also on the trusted list.
        let both = MailFilter(vipSenders: ["boss@x.com"], trustedNewsletterSenders: ["boss@x.com"])
        #expect(!both.isTrustedNewsletter(mail("boss@x.com")))
        #expect(both.suggestionLimit(for: mail("boss@x.com")) == 3)
    }

    @Test func trustedNewsletterOverridesBulkOnly() {
        let bulk = ["List-Unsubscribe": "<mailto:u@x.com>", "Precedence": "bulk", "Auto-Submitted": "auto-generated"]
        let f = MailFilter(trustedNewsletterSenders: ["News@Uni.edu"])
        #expect(f.tier(mail("Uni <news@uni.edu>", bulk)) == .full)
        #expect(f.isTrustedNewsletter(mail("Uni <news@uni.edu>", bulk)))
        #expect(f.suggestionLimit(for: mail("news@uni.edu")) == 8)
        // An ordinary newsletter with the same headers stays summary-only.
        #expect(f.tier(mail("other@uni.edu", bulk)) == .infoOnly)
        #expect(!f.isTrustedNewsletter(mail("other@uni.edu", bulk)))
        #expect(f.suggestionLimit(for: mail("other@uni.edu")) == 3)
        // Bulk-like local part is overridden too.
        let local = MailFilter(trustedNewsletterSenders: ["newsletter@shop.com"])
        #expect(local.tier(mail("newsletter@shop.com")) == .full)
    }

    @Test func trustedNewsletterNeverOverridesBlockOrIgnore() {
        let blocked = MailFilter(blockedSenders: ["n@x.com"], trustedNewsletterSenders: ["n@x.com"])
        #expect(blocked.tier(mail("n@x.com")) == .skip)
        #expect(!blocked.isTrustedNewsletter(mail("n@x.com")))
        let ignored = MailFilter(ignoredSenders: ["n@x.com"], trustedNewsletterSenders: ["n@x.com"])
        #expect(ignored.tier(mail("n@x.com")) == .skip)
        #expect(ignored.skipReason(mail("n@x.com")) == "ignored sender")
        #expect(!ignored.isTrustedNewsletter(mail("n@x.com")))
    }

    @Test func listUnsubscribeIsInfoOnly() {
        #expect(MailFilter().tier(mail("a@x.com", ["List-Unsubscribe": "<mailto:u@x.com>"])) == .infoOnly)
        #expect(MailFilter().tier(mail("a@x.com", ["List-Unsubscribe": " "])) == .full)
    }

    @Test func precedenceBulkOrList() {
        #expect(MailFilter().tier(mail("a@x.com", ["Precedence": " Bulk "])) == .infoOnly)
        #expect(MailFilter().tier(mail("a@x.com", ["Precedence": "LIST"])) == .infoOnly)
        #expect(MailFilter().tier(mail("a@x.com", ["Precedence": "junk"])) == .full)
    }

    @Test func autoSubmitted() {
        #expect(MailFilter().tier(mail("a@x.com", ["Auto-Submitted": "auto-generated"])) == .infoOnly)
        #expect(MailFilter().tier(mail("a@x.com", ["Auto-Submitted": "no"])) == .full)
    }

    @Test func headerLookupIsCaseInsensitive() {
        #expect(MailFilter().tier(mail("a@x.com", ["list-unsubscribe": "<u>"])) == .infoOnly)
    }

    @Test func localPartSignals() {
        for addr in ["no-reply@x.com", "NoReply@x.com", "weekly-newsletter@x.com"] {
            #expect(MailFilter().tier(mail("Co <\(addr)>")) == .infoOnly)
        }
        // Only the local part counts, not the domain.
        #expect(MailFilter().tier(mail("sam@noreply.com")) == .full)
    }

    @Test func bareAddressAndCaseInsensitivity() {
        let f = MailFilter(blockedSenders: ["Spam@X.com"])
        #expect(f.tier(mail("SPAM@x.COM")) == .skip)
        #expect(f.tier(mail("Name <SPAM@x.com>")) == .skip)
        #expect(MailFilter.address(from: "Name <A@B.com>") == "a@b.com")
        #expect(MailFilter.address(from: " A@B.com ") == "a@b.com")
    }

    @Test func estimatedTierUsesSenderOnly() {
        let f = MailFilter(blockedSenders: ["b@x.com", "bv@x.com"], ignoredSenders: ["i@x.com", "vi@x.com"],
                           vipSenders: ["v@x.com", "bv@x.com", "vi@x.com"],
                           trustedNewsletterSenders: ["newsletter@x.com", "i@x.com"])
        func h(_ s: String) -> MessageHeader {
            MessageHeader(id: "1", account: "a", mailbox: "Inbox", sender: s, subject: "s", receivedAt: Date())
        }
        #expect(f.estimatedTier(for: h("B <b@x.com>")) == .skip)
        #expect(f.estimatedTier(for: h("i@x.com")) == .skip)
        #expect(f.estimatedTier(for: h("v@x.com")) == .full)
        #expect(f.estimatedTier(for: h("no-reply@x.com")) == .infoOnly)
        #expect(f.estimatedTier(for: h("sam@x.com")) == .full)
        // Same precedence as tier(_:), so the preview matches processing.
        #expect(f.estimatedTier(for: h("bv@x.com")) == .skip)
        #expect(f.estimatedTier(for: h("vi@x.com")) == .full)
        #expect(f.estimatedTier(for: h("newsletter@x.com")) == .full)
        for s in ["b@x.com", "bv@x.com", "vi@x.com", "i@x.com", "newsletter@x.com", "sam@x.com"] {
            #expect(f.estimatedTier(for: h(s)) == f.tier(mail(s)), "\(s)")
        }
    }

    @Test func fixtureTiers() throws {
        let emails = try FixtureLoader.loadEmails()
        func tier(_ prefix: String) throws -> MailTier {
            MailFilter().tier(try #require(emails.first { $0.id.hasPrefix(prefix) }))
        }
        for p in ["news-shop-10", "news-tech-09", "news-uni-11", "bill-card-06"] {
            #expect(try tier(p) == .infoOnly, "\(p)")
        }
        #expect(try tier("scam-15") == .full)
        #expect(try tier("inject-16") == .full)
    }
}
