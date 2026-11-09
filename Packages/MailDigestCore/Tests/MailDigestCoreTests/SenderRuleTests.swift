import Foundation
import Testing
@testable import MailDigestCore

@Suite struct SenderRuleTests {
    private func header(_ sender: String) -> MessageHeader {
        MessageHeader(id: sender, account: "a", mailbox: "Inbox", sender: sender, subject: "s", receivedAt: Date())
    }

    @Test func domainMatchesDomainAndSubdomainsOnly() {
        let set = SenderRuleSet(["@Example.com"])
        #expect(set.matches("a@example.com"))
        #expect(set.matches("Ann <A@MAIL.Example.com>"))
        #expect(set.matches("a@x.y.example.com"))
        #expect(!set.matches("a@notexample.com"))
        #expect(!set.matches("a@example.com.evil.net"))
        #expect(!set.matches("a@example.org"))
        #expect(!set.matches("noaddress"))
    }

    @Test func exactRuleMatchesCaseInsensitivelyAndOnlyThatAddress() {
        let set = SenderRuleSet(["Ann@Example.com"])
        #expect(set.matches("ann@example.com"))
        #expect(!set.matches("bob@example.com"))
        #expect(!set.matches("ann@mail.example.com"))
    }

    @Test func validity() {
        for ok in ["a@b.com", "@example.com", "@mail.example.co.uk", "Ann <a@b.com>"] { #expect(SenderRule.isValid(ok), "\(ok)") }
        for bad in ["", "@", "@.", "@com", "@.com", "@example.", "@a..com", "a@", "a b@c.com", "@exa mple.com", "a@b@c.com", "plain"] {
            #expect(!SenderRule.isValid(bad), "\(bad)")
        }
        #expect(SenderRule("@Example.com")?.kind == .domain)
        #expect(SenderRule("a@example.com")?.kind == .address)
    }

    @Test func exactBeatsDomainWithinOneList() {
        let set = SenderRuleSet(["@example.com", "boss@example.com"])
        #expect(set.matchedRule(for: "boss@example.com")?.kind == .address)
        #expect(set.matchedRule(for: "other@example.com")?.kind == .domain)
        #expect(set.matchedRule(for: "other@example.com")?.text == "@example.com")
        let filter = MailFilter(vipSenders: ["@example.com", "boss@example.com"])
        #expect(filter.matchedRule(for: "boss@example.com", in: .vip)?.text == "boss@example.com")
        #expect(filter.matchedRule(for: "x@example.com", in: .vip)?.text == "@example.com")
        #expect(filter.matchedRule(for: "x@example.com", in: .blocked) == nil)
    }

    @Test func precedenceAcrossListsIgnoresRuleKind() {
        // Blocked domain beats a VIP exact address.
        let f1 = MailFilter(blockedSenders: ["@example.com"], vipSenders: ["a@example.com"])
        #expect(f1.estimatedTier(for: header("a@example.com")) == .skip)
        // VIP domain beats an Ignored exact address.
        let f2 = MailFilter(ignoredSenders: ["a@example.com"], vipSenders: ["@example.com"])
        #expect(f2.estimatedTier(for: header("a@mail.example.com")) == .full)
        #expect(f2.estimatedTier(for: header("a@example.com")) == .full)
        // Ignored domain beats a Newsletter exact address; Newsletter domain alone is full.
        let f3 = MailFilter(ignoredSenders: ["@example.com"], trustedNewsletterSenders: ["n@example.com"])
        #expect(f3.estimatedTier(for: header("n@example.com")) == .skip)
        let f4 = MailFilter(trustedNewsletterSenders: ["@news.example.com"])
        #expect(f4.estimatedTier(for: header("n@news.example.com")) == .full)
        #expect(f4.estimatedTier(for: header("n@example.com")) == .full) // plain mail is full anyway
    }

    @Test func trustedNewsletterDomainRespectsHigherLists() {
        func mail(_ sender: String) -> EmailMessage {
            EmailMessage(id: "x", account: "a", mailbox: "Inbox", sender: sender, subject: "s",
                         receivedAt: Date(timeIntervalSince1970: 0), body: "b", headers: [:])
        }
        let f = MailFilter(blockedSenders: ["@bad.example.com"], trustedNewsletterSenders: ["@example.com"])
        #expect(f.isTrustedNewsletter(mail("a@example.com")))
        #expect(!f.isTrustedNewsletter(mail("a@bad.example.com")))
        #expect(f.skipReason(mail("a@bad.example.com")) == "blocked sender")
        #expect(MailFilter(ignoredSenders: ["@example.com"]).skipReason(mail("a@example.com")) == "ignored sender")
    }

    @Test func containsAndAddHandleDomains() {
        var s = DigestSettings()
        let r1281 = s.add(sender: "@Example.com", to: .ignored)
        #expect(r1281)
        #expect(s.ignoredSenders == ["@example.com"])
        let r3421 = s.add(sender: "@example.com", to: .ignored)
        #expect(!r3421)
        // An address already covered by the domain is "already listed" and not added again.
        #expect(s.contains(sender: "Ann <a@mail.example.com>", in: .ignored))
        let r3889 = s.add(sender: "a@example.com", to: .ignored)
        #expect(!r3889)
        #expect(!s.contains(sender: "a@example.com", in: .vip))
        #expect(!s.contains(sender: "a@notexample.com", in: .ignored))
        let r2158 = s.add(sender: "@", to: .ignored)
        #expect(!r2158)
        let r1853 = s.add(sender: "@com", to: .ignored)
        #expect(!r1853)
        // An exact entry does not cover its domain.
        var t = DigestSettings()
        t.add(sender: "a@example.com", to: .vip)
        #expect(!t.contains(sender: "@example.com", in: .vip))
        let r4189 = t.add(sender: "@example.com", to: .vip)
        #expect(r4189)
        t.remove("@EXAMPLE.com", from: .vip)
        #expect(t.vipSenders == ["a@example.com"])
    }

    @Test func recentSendersSkipAddressesCoveredByDomainRule() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ sender: String) -> JobItem {
            JobItem(id: UUID(), jobID: UUID(), messageID: UUID().uuidString, mailbox: MailboxRef(account: "a", name: "Inbox"),
                    sender: sender, subject: "s", receivedAt: t, position: 1, state: .done,
                    outcome: nil, seconds: nil, attempts: 1, lastError: nil)
        }
        let ranked = RecentSender.rank([item("a@example.com"), item("b@other.com")], excludingRules: ["@example.com"])
        #expect(ranked.map(\.address) == ["b@other.com"])
    }

    @Test func ignoreSuggestionIsSuppressedByDomainRule() {
        var s = DigestSettings()
        s.ignoredSenders = ["@example.com"]
        let ds = (0..<5).map { i in
            Decision(suggestionID: UUID(), sender: "a@mail.example.com", action: .dismissed,
                     decidedAt: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(IgnoreRuleSuggester.suggestion(for: "a@mail.example.com", decisions: ds, settings: s) == nil)
    }

    @Test func previewCountAndConfirmUseDomainRuleOnIgnoredList() {
        let ref = MailboxRef(account: "iCloud", name: "Inbox")
        let builder = JobPreviewBuilder(filter: MailFilter(ignoredSenders: ["@example.com"]))
        let plan = JobPlan(kind: .backlog, mailboxes: [ref], from: .distantPast, to: .distantFuture, excludedMessageIDs: [])
        let headers = ["a@example.com", "b@mail.example.com", "c@notexample.com"].map(header)
        let p = builder.build(plan: plan, headers: [ref: headers], isProcessedOrQueued: [], averageSecondsPerEmail: nil, limit: nil)
        #expect(p.toProcess.filter { builder.filter.matches($0.sender, in: .ignored) }.count == 2)
        let on = builder.confirmed(p, excluded: [], skipIgnoredSenders: true, secondsPerEmail: 10)
        #expect(on.toProcess.map(\.id) == ["c@notexample.com"])
    }
}
