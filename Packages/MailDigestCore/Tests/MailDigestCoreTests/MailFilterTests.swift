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

    @Test func vipBeatsBlockAndBulk() {
        let f = MailFilter(blockedSenders: ["boss@x.com"], vipSenders: ["boss@x.com"])
        #expect(f.tier(mail("Boss <boss@x.com>")) == .full)
        #expect(f.tier(mail("Boss <boss@x.com>", ["List-Unsubscribe": "<mailto:u@x.com>"])) == .full)
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
        let f = MailFilter(blockedSenders: ["b@x.com"], ignoredSenders: ["i@x.com"], vipSenders: ["v@x.com"])
        func h(_ s: String) -> MessageHeader {
            MessageHeader(id: "1", account: "a", mailbox: "Inbox", sender: s, subject: "s", receivedAt: Date())
        }
        #expect(f.estimatedTier(for: h("B <b@x.com>")) == .skip)
        #expect(f.estimatedTier(for: h("i@x.com")) == .skip)
        #expect(f.estimatedTier(for: h("v@x.com")) == .full)
        #expect(f.estimatedTier(for: h("no-reply@x.com")) == .infoOnly)
        #expect(f.estimatedTier(for: h("sam@x.com")) == .full)
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
