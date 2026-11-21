import Foundation
import Testing
@testable import MailDigestCore

// All content is synthetic.

private let filter = PrivacyPreFilter()
private let amb = PreFilterVerdict.needsTriage(.ambiguousSender, signal: nil)

private func input(sender: String = "Pat <pat@example.com>", body: String,
                   headers: [String: String] = [:], inspection: ContentInspection = .complete) -> PrivacyInput {
    PrivacyInput(sender: sender, subject: "Hello", body: body, headers: headers, inspection: inspection)
}

private func mail(_ sender: String, _ headers: [String: String] = [:]) -> EmailMessage {
    EmailMessage(id: "x", account: "a", mailbox: "Inbox", sender: sender, subject: "s",
                 receivedAt: Date(timeIntervalSince1970: 0), body: "b", headers: headers)
}

/// A relay From address for `original`, built the way Hide My Email builds it.
private func relayFrom(_ name: String, original: String, suffix: String = "abc123def456_0a1b2c3d") -> String {
    let flat = original.replacingOccurrences(of: "@", with: "_at_").replacingOccurrences(of: ".", with: "_")
    return "\(name) <\(flat)_\(suffix)@icloud.com>"
}

private func hme(_ original: String) -> [String: String] {
    ["X-ICLOUD-HME": "p=alias@icloud.com; d=login.example.org; f=me@icloud.com; r=to; s=\(original)"]
}

@Suite struct NumericPatternTests {
    @Test func cardInsideUrlIsIgnored() {
        // 4242 4242 4242 4 is not what matters; any Luhn-valid 13-digit run in a query string must not match.
        #expect(PrivacyPreFilter.luhn("4222222222222"))
        let body = "See https://jobs.example.com/view?id=4222222222222&x=1 for details"
        #expect(filter.classify(input(body: body)) == amb)
        #expect(filter.classify(input(body: "Open www.example.com/t/4222222222222 now")) == amb)
        #expect(filter.classify(input(body: "Open ftp://example.com/4222222222222 now")) == amb)
    }

    @Test func cardInProseStillMatches() {
        #expect(filter.classify(input(body: "Card 4242 4242 4242 4242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Card 4242424242424242 on file")) == .private("pattern.card"))
        // A URL elsewhere in the text does not hide the card.
        #expect(filter.classify(input(body: "Card 4242424242424242 https://example.com/a")) == .private("pattern.card"))
    }

    @Test func tfnNeedsLabel() {
        #expect(PrivacyPreFilter.tfnValid("123456782"))
        #expect(filter.classify(input(body: "Ref 123 456 782 noted")) == amb)
        #expect(filter.classify(input(body: "Ref 123456782 noted")) == amb)
        #expect(filter.classify(input(body: "TFN: 123 456 782")) == .private("pattern.tfn"))
        #expect(filter.classify(input(body: "My TFN is 123456782")) == .private("pattern.tfn"))
        #expect(filter.classify(input(body: "123 456 782 is my TFN")) == .private("pattern.tfn"))
    }

    @Test func tfnLabelTooFarOrNumberInUrl() {
        #expect(filter.classify(input(body: "TFN a b c d e f g h 123 456 782")) == amb)
        #expect(filter.classify(input(body: "Update the TFN at https://example.com/x/123456782 today")) == amb)
    }
}

@Suite struct RelaySenderTests {
    @Test func verifiedRelayGivesOriginal() {
        let from = relayFrom("EatClub", original: "hello@mail.eatclub.com.au")
        #expect(RelaySender.originalSender(from: from, headers: hme("hello@mail.eatclub.com.au"))
                == "hello@mail.eatclub.com.au")
        #expect(RelaySender.displaySender(from: from, headers: hme("hello@mail.eatclub.com.au"))
                == "EatClub <hello@mail.eatclub.com.au>")
    }

    @Test func forgedHeaderOnNonRelayIsIgnored() {
        let h = hme("writer@substack.com")
        #expect(RelaySender.originalSender(from: "Pat <pat@example.com>", headers: h) == nil)
        // The alias must encode the claimed sender, even on icloud.com.
        #expect(RelaySender.originalSender(from: "X <random123@icloud.com>", headers: h) == nil)
        #expect(RelaySender.displaySender(from: "Pat <pat@example.com>", headers: h) == "Pat <pat@example.com>")
    }

    @Test func foldedHeaderIsParsed() {
        let raw = "From: x\nX-ICLOUD-HME: p=a@icloud.com; d=login.example.org;\n f=me@icloud.com; r=to;\n\ts=hello@mail.eatclub.com.au\nSubject: y\n"
        let headers = MailJSONDecoder.filterHeaders(raw)
        #expect(RelaySender.claimedSender(headers: headers) == "hello@mail.eatclub.com.au")
        let from = relayFrom("EatClub", original: "hello@mail.eatclub.com.au")
        #expect(RelaySender.originalSender(from: from, headers: headers) == "hello@mail.eatclub.com.au")
    }

    @Test func absentHeader() {
        #expect(RelaySender.claimedSender(headers: [:]) == nil)
    }

    @Test func filterUsesOriginalSender() {
        let from = relayFrom("Boss", original: "boss@work.example.org")
        let filter = MailFilter(ignoredSenders: ["@spam.example.net"], vipSenders: ["boss@work.example.org"])
        #expect(filter.tier(mail(from, hme("boss@work.example.org"))) == .full)
        // Without the header the relay address matches nothing.
        #expect(filter.tier(mail(from)) == .full)
        let ignored = relayFrom("Spam", original: "x@spam.example.net")
        #expect(filter.tier(mail(ignored, hme("x@spam.example.net"))) == .skip)
        #expect(filter.tier(mail(ignored)) == .full)
        // A forged header on a non-relay From does not trigger rules.
        #expect(filter.tier(mail("Pat <pat@example.com>", hme("x@spam.example.net"))) == .full)
        // The relay address itself still matches.
        #expect(MailFilter(blockedSenders: [MailFilter.address(from: from)]).tier(mail(from, hme("boss@work.example.org"))) == .skip)
    }

    @Test func bulkLocalPartOnOriginal() {
        let from = relayFrom("Shop", original: "no-reply@shop.example.org")
        #expect(MailFilter().tier(mail(from, hme("no-reply@shop.example.org"))) == .infoOnly)
    }

    @Test func allowlistUsesOriginalHost() {
        let from = relayFrom("Writer", original: "writer@substack.com")
        let unsub = ["List-Unsubscribe": "<https://example.com/u>"]
        var verified = unsub; verified.merge(hme("writer@substack.com")) { a, _ in a }
        #expect(filter.classify(input(sender: from, body: "Just saying hi.", headers: verified)) == .public("allowlist.substack"))
        // A forged header on a non-relay sender never reaches the allowlist.
        #expect(filter.classify(input(sender: "Pat <pat@example.com>", body: "Just saying hi.", headers: verified)) == amb)
    }

    @Test func relayOfSensitiveSenderIsSensitive() {
        let from = relayFrom("ATO", original: "noreply@ato.gov.au")
        #expect(filter.classify(input(sender: from, body: "Hello", headers: hme("noreply@ato.gov.au")))
                == .private("domain.gov.au"))
        let bank = relayFrom("Bank", original: "alerts@commbank.com.au")
        #expect(filter.classify(input(sender: bank, body: "Hello", headers: hme("alerts@commbank.com.au")))
                == .private("domain.bank"))
    }

    @Test func unverifiedSensitiveClaimStillSensitive() {
        // Not an encoded alias, but the claim names a sensitive domain: fail closed (local only).
        #expect(filter.classify(input(sender: "Pat <pat@example.com>", body: "Hello", headers: hme("a@ato.gov.au")))
                == .private("domain.gov.au"))
    }

    @Test func systemOneFromLineShowsOriginal() {
        let from = relayFrom("EatClub", original: "hello@mail.eatclub.com.au")
        let email = EmailMessage(id: "i", account: "a", mailbox: "INBOX", sender: from, subject: "Sale",
                                 receivedAt: Date(timeIntervalSince1970: 0), body: "Half price pizza",
                                 headers: hme("hello@mail.eatclub.com.au"))
        let state = TriageInputBuilder().plan(email).inputs.first?.state ?? ""
        #expect(state.contains("From: EatClub <hello@mail.eatclub.com.au>"))
        #expect(!state.contains("icloud.com"))
    }
}

@Suite struct PartialEmlxTests {
    private static let head = "From: Sam <sam@example.com>\nSubject: Hello\nMessage-ID: <p1@example.com>\nDate: Tue, 3 Nov 2026 09:15:00 +1000\n"

    private func parse(_ message: String) throws -> ParsedEmlx {
        let body = Data(message.utf8)
        var data = Data("\(body.count)\n".utf8)
        data.append(body)
        guard case .usable(let p) = EmlxParser().parse(data) else { throw CancellationError() }
        return p
    }

    private func multipart(_ parts: String) -> String {
        Self.head + "MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary=\"b1\"\n\n" + parts + "--b1--\n"
    }

    @Test func allPartsPresentIsComplete() throws {
        let p = try parse(multipart("--b1\nContent-Type: text/plain; charset=utf-8\n\nHello there\n--b1\nContent-Type: text/html; charset=utf-8\n\n<p>Hello there</p>\n"))
        #expect(!p.hasPlaceholderPart)
        let v = PartialEmlxPolicy.verdict(for: p, hasAttachmentsDirectory: false)
        #expect(v.inspection == .complete)
        #expect(v.gap == nil)
    }

    @Test func placeholderTextPartIsPartial() throws {
        let p = try parse(multipart("--b1\nContent-Type: text/plain; charset=utf-8\n\nHello there\n--b1\nContent-Type: text/html; charset=utf-8\nX-Apple-Content-Length: 4096\n\n\n"))
        #expect(p.hasPlaceholderPart)
        let v = PartialEmlxPolicy.verdict(for: p, hasAttachmentsDirectory: false)
        #expect(v.inspection == .uninspectedParts)
        #expect(v.gap == .partialMessage)
    }

    @Test func emptyTextPartIsPartial() throws {
        let p = try parse(multipart("--b1\nContent-Type: text/plain; charset=utf-8\n\nHello there\n--b1\nContent-Type: text/html; charset=utf-8\n\n\n"))
        #expect(p.hasPlaceholderPart)
        #expect(PartialEmlxPolicy.verdict(for: p, hasAttachmentsDirectory: false).gap == .partialMessage)
    }

    @Test func attachmentsDirectoryIsPartial() throws {
        let p = try parse(multipart("--b1\nContent-Type: text/plain; charset=utf-8\n\nHello there\n"))
        let v = PartialEmlxPolicy.verdict(for: p, hasAttachmentsDirectory: true)
        #expect(v.inspection == .uninspectedParts)
        #expect(v.gap == .partialMessage)
    }

    @Test func alreadyIncompleteStaysPartial() throws {
        let p = try parse(Self.head + "Content-Type: multipart/mixed; boundary=\"b1\"\n\n--b1\nContent-Type: text/plain\n\nHi\n--b1\nContent-Type: application/pdf\n\nxx\n--b1--\n")
        #expect(PartialEmlxPolicy.verdict(for: p, hasAttachmentsDirectory: false).gap == .partialMessage)
    }
}
