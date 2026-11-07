import Foundation
import Testing
@testable import MailDigestCore

private func input(sender: String = "Pat <pat@example.com>", subject: String = "Hello", body: String = "Just saying hi.",
                   headers: [String: String] = [:], inspection: ContentInspection = .complete) -> PrivacyInput {
    PrivacyInput(sender: sender, subject: subject, body: body, headers: headers, inspection: inspection)
}

private let unsub = ["List-Unsubscribe": "<https://example.com/u?id=1>"]
private let filter = PrivacyPreFilter()

@Suite struct PrivacyPreFilterTests {
    @Test func otpPhrases() {
        #expect(filter.classify(input(body: "Your verification code is here")) == .private("kw.otp"))
        #expect(filter.classify(input(subject: "Your One-Time Code")) == .private("kw.otp"))
        #expect(filter.classify(input(body: "Use this sign-in code now")) == .private("kw.otp"))
        #expect(filter.classify(input(body: "OTP expires soon")) == .private("kw.otp"))
    }

    @Test func otpNumberOnlyNearOtpWords() {
        #expect(filter.classify(input(body: "Your code is 482913")) == .private("pattern.otp"))
        #expect(filter.classify(input(body: "We shipped 4829 units across the region today.")) == .needsTriage)
    }

    @Test func credentials() {
        #expect(filter.classify(input(body: "Click to reset your password")) == .private("kw.credentials"))
        #expect(filter.classify(input(body: "Here is your login link")) == .private("kw.credentials"))
    }

    @Test func cardNumbers() {
        #expect(filter.classify(input(body: "Card 4242 4242 4242 4242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Card 4242-4242-4242-4242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Card 4242424242424242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Ref 4242 4242 4242 4241 on file")) == .needsTriage)
    }

    @Test func iban() {
        #expect(filter.classify(input(body: "Send to GB82 WEST 1234 5698 7654 32 please")) == .private("pattern.iban"))
        #expect(filter.classify(input(body: "Send to GB82 WEST 1234 5698 7654 33 please")) == .needsTriage)
    }

    @Test func bsbAndAccount() {
        #expect(filter.classify(input(body: "BSB 062-000 account 1234567")) == .private("pattern.bsb"))
        #expect(filter.classify(input(body: "062-000 1234567")) == .private("pattern.bsb"))
        #expect(filter.classify(input(body: "Call 062-000 for info")) == .needsTriage)
    }

    @Test func tfn() {
        #expect(filter.classify(input(body: "Number 123 456 782 noted")) == .private("pattern.tfn"))
        #expect(filter.classify(input(body: "Number 123 456 783 noted")) == .needsTriage)
        #expect(filter.classify(input(body: "TFN supplied")) == .private("kw.tax"))
    }

    @Test func keywords() {
        #expect(filter.classify(input(subject: "Your statement is ready")) == .private("kw.financial"))
        #expect(filter.classify(input(subject: "Invoice 42")) == .private("kw.financial"))
        #expect(filter.classify(input(body: "Thanks for your payment")) == .private("kw.financial"))
        #expect(filter.classify(input(body: "Your prescription is ready")) == .private("kw.medical"))
        #expect(filter.classify(input(body: "An appointment with a doctor")) == .private("kw.medical"))
        #expect(filter.classify(input(body: "Lodge your tax return")) == .private("kw.tax"))
        #expect(filter.classify(input(body: "Message from the IRS")) == .private("kw.tax"))
        #expect(filter.classify(input(body: "Take a taxi to the station")) == .needsTriage)
    }

    @Test func htmlishBodyStillMatched() {
        #expect(filter.classify(input(body: "<p>Your <b>invoice</b>&nbsp;is attached</p>")) == .private("kw.financial"))
    }

    @Test func sensitiveDomains() {
        #expect(filter.classify(input(sender: "ATO <noreply@ato.gov.au>")) == .private("domain.gov.au"))
        #expect(filter.classify(input(sender: "x@mail.agency.gov")) == .private("domain.gov"))
        #expect(filter.classify(input(sender: "x@office.gov.uk")) == .private("domain.gov.uk"))
        #expect(filter.classify(input(sender: "x@army.mil")) == .private("domain.mil"))
        #expect(filter.classify(input(sender: "CBA <x@Mail.CommBank.com.au.>")) == .private("domain.bank"))
        #expect(filter.classify(input(sender: "x@paypal.com")) == .private("domain.bank"))
        #expect(filter.classify(input(sender: "x@bupa.com.au")) == .private("domain.health"))
        #expect(filter.classify(input(sender: "x@medicare.gov.au")) == .private("domain.gov.au"))
    }

    @Test func domainBoundaries() {
        for s in ["x@notgov.au", "x@evilgov.au", "x@gov.au.evil.com", "x@fakecommbank.com.au", "x@evilgov"] {
            #expect(filter.classify(input(sender: s)) == .needsTriage, "\(s)")
        }
    }

    @Test func publicNewsletter() {
        #expect(filter.classify(input(sender: "Writer <writer@substack.com>", headers: unsub)) == .public("allowlist.substack"))
        #expect(filter.classify(input(sender: "Medium Daily Digest <noreply@medium.com>",
                                      headers: ["list-unsubscribe": "<mailto:u@medium.com>"])) == .public("allowlist.medium"))
    }

    @Test func publicNeedsValidUnsubscribe() {
        #expect(filter.classify(input(sender: "w@substack.com")) == .needsTriage)
        #expect(filter.classify(input(sender: "w@substack.com", headers: ["List-Unsubscribe": ""])) == .needsTriage)
        #expect(filter.classify(input(sender: "w@substack.com", headers: ["List-Unsubscribe": "<http://x.example>"])) == .needsTriage)
        #expect(filter.classify(input(sender: "w@substack.com", headers: ["List-Unsubscribe": "https://x.example"])) == .needsTriage)
    }

    @Test func publicIsExactHostOnly() {
        #expect(filter.classify(input(sender: "w@news.substack.com", headers: unsub)) == .needsTriage)
        #expect(filter.classify(input(sender: "w@evilsubstack.com", headers: unsub)) == .needsTriage)
        #expect(filter.classify(input(sender: "w@substack.com.evil.com", headers: unsub)) == .needsTriage)
    }

    @Test func sensitiveContentOverridesPublicSender() {
        #expect(filter.classify(input(sender: "w@substack.com", subject: "Your receipt", headers: unsub)) == .private("kw.financial"))
    }

    @Test func githubNeverPublic() {
        #expect(filter.classify(input(sender: "GitHub <noreply@github.com>", headers: unsub)) == .needsTriage)
    }

    @Test func unknownSenderNeedsTriage() {
        #expect(filter.classify(input()) == .needsTriage)
    }

    @Test func nonCompleteInspectionNeverPublic() {
        for ins in [ContentInspection.uninspectedParts, .unknown] {
            #expect(filter.classify(input(sender: "w@substack.com", headers: unsub, inspection: ins)) == .needsTriage)
        }
        // Private still applies regardless of inspection.
        #expect(filter.classify(input(subject: "Invoice", inspection: .unknown)) == .private("kw.financial"))
    }
}

@Suite struct RoutingProvenanceCodableTests {
    @Test func roundTrip() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let prov = RoutingProvenance(
            assessment: PrivacyAssessment(
                verdict: .public, method: .systemOne, ruleID: nil,
                triage: TriageScores(model: "kev:0.8b-q8_0", pSensitive: 0.02, pNonSensitive: 0.98,
                                     categoryProbabilities: ["public_newsletter_or_promo": 0.95],
                                     threshold: 0.9, publicFloor: 0.85),
                triageFailure: nil, assessedAt: t),
            execution: ExecutionRecord(provider: .local, model: "qwen3:4b", cloudAttempted: true,
                                       localReason: .cloudFailed, cloudFailure: "rateLimited", startedAt: t, finishedAt: t))
        let enc = JSONEncoder()
        let data = try enc.encode(prov)
        #expect(try JSONDecoder().decode(RoutingProvenance.self, from: data) == prov)
        #expect(prov.schemaVersion == 1)
    }

    @Test func assessmentOnlyRoundTrip() throws {
        let prov = RoutingProvenance(assessment: PrivacyAssessment(
            verdict: .notAssessed, method: .cloudOff, assessedAt: Date(timeIntervalSince1970: 0)))
        let data = try JSONEncoder().encode(prov)
        #expect(try JSONDecoder().decode(RoutingProvenance.self, from: data) == prov)
    }

    @Test func emailDecodesWithoutInspectionKey() throws {
        let e = EmailMessage(id: "a", account: "x", mailbox: "INBOX", sender: "s", subject: "t",
                             receivedAt: Date(timeIntervalSince1970: 0), body: "b", headers: [:],
                             contentInspection: .complete)
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(EmailMessage.self, from: data).contentInspection == .complete)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "contentInspection")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(EmailMessage.self, from: stripped).contentInspection == .unknown)
        #expect(EmailMessage(id: "a", account: "x", mailbox: "m", sender: "s", subject: "t",
                             receivedAt: Date(), body: "b", headers: [:]).contentInspection == .unknown)
    }
}
