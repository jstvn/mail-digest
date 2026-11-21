import Foundation
import Testing
@testable import MailDigestCore

private func input(sender: String = "Pat <pat@example.com>", subject: String = "Hello", body: String = "Just saying hi.",
                   headers: [String: String] = [:], inspection: ContentInspection = .complete) -> PrivacyInput {
    PrivacyInput(sender: sender, subject: subject, body: body, headers: headers, inspection: inspection)
}

private let unsub = ["List-Unsubscribe": "<https://example.com/u?id=1>"]
private let filter = PrivacyPreFilter()
private let amb = PreFilterVerdict.needsTriage(.ambiguousSender, signal: nil)
private let substack = "Writer <writer@substack.com>"
private func trusted(_ body: String, subject: String = "Weekly") -> PreFilterVerdict {
    filter.classify(input(sender: substack, subject: subject, body: body, headers: unsub))
}
// Synthetic company footer printed by every newsletter.
private let footer = "\n\nUnsubscribe. Example Media Pty Ltd, 100 Sample Street, Testville."

@Suite struct PrivacyPreFilterTests {
    @Test func otpPhrases() {
        #expect(filter.classify(input(body: "Your verification code is here")) == .private("kw.otp"))
        #expect(filter.classify(input(subject: "Your One-Time Code")) == .private("kw.otp"))
        #expect(filter.classify(input(body: "Use this sign-in code now")) == .private("kw.otp"))
        #expect(filter.classify(input(body: "OTP expires soon")) == .private("kw.otp"))
    }

    @Test func otpNumberOnlyNearOtpWords() {
        #expect(filter.classify(input(body: "Your code is 482913")) == .private("pattern.otp"))
        #expect(filter.classify(input(body: "We shipped 4829 units across the region today.")) == amb)
    }

    @Test func credentials() {
        #expect(filter.classify(input(body: "Click to reset your password")) == .private("kw.credentials"))
        #expect(filter.classify(input(body: "Here is your login link")) == .private("kw.credentials"))
    }

    @Test func cardNumbers() {
        #expect(filter.classify(input(body: "Card 4242 4242 4242 4242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Card 4242-4242-4242-4242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Card 4242424242424242 on file")) == .private("pattern.card"))
        #expect(filter.classify(input(body: "Ref 4242 4242 4242 4241 on file")) == amb)
    }

    @Test func iban() {
        #expect(filter.classify(input(body: "Send to GB82 WEST 1234 5698 7654 32 please")) == .private("pattern.iban"))
        #expect(filter.classify(input(body: "Send to GB82 WEST 1234 5698 7654 33 please")) == amb)
    }

    @Test func bsbAndAccount() {
        #expect(filter.classify(input(body: "BSB 062-000 account 1234567")) == .private("pattern.bsb"))
        #expect(filter.classify(input(body: "062-000 1234567")) == .private("pattern.bsb"))
        #expect(filter.classify(input(body: "Call 062-000 for info")) == amb)
    }

    @Test func tfn() {
        #expect(filter.classify(input(body: "TFN 123 456 782 noted")) == .private("pattern.tfn"))
        #expect(filter.classify(input(body: "Number 123 456 783 noted")) == amb)
        #expect(filter.classify(input(body: "Your TFN is on file")) == .private("kw.tax.record"))
        #expect(filter.classify(input(body: "TFN supplied")) == amb)
    }

    @Test func recordPhrases() {
        #expect(filter.classify(input(subject: "Your statement is ready")) == .private("kw.financial.record"))
        #expect(filter.classify(input(body: "Amount due: $120.50")) == .private("kw.financial.record"))
        #expect(filter.classify(input(body: "Your appointment with Dr Lee")) == .private("kw.medical.record"))
        #expect(filter.classify(input(body: "Your tax return reference 2024")) == .private("kw.tax.record"))
        #expect(filter.classify(input(body: "Notice of assessment attached")) == .private("kw.tax.record"))
    }

    @Test func valueGateNeedsDigitNearby() {
        #expect(filter.classify(input(body: "We track amount due automatically")) == amb)
        #expect(filter.classify(input(body: "Invoice number 42")) == .private("kw.financial.record"))
        // Digit more than six tokens after the phrase does not count.
        #expect(filter.classify(input(body: "amount due one two three four five six seven 9")) == amb)
    }

    @Test func bareTopicWordsTriggerNothing() {
        for w in ["statement", "invoice", "receipt", "payment", "transaction", "medical", "health", "tax", "tfn",
                  "abn", "irs", "prescription", "taxes"] {
            #expect(filter.classify(input(body: "A general note about \(w) topics")) == amb ||
                    filter.classify(input(body: "A general note about \(w) topics"))
                        == .needsTriage(.ambiguousSender, signal: "risk.medical.personal") , "\(w)")
        }
        #expect(filter.classify(input(body: "Take a taxi to the station")) == amb)
    }

    @Test func htmlishBodyStillMatched() {
        #expect(filter.classify(input(body: "<p>Your <b>invoice number</b>&nbsp;7</p>")) == .private("kw.financial.record"))
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
            #expect(filter.classify(input(sender: s)) == amb, "\(s)")
        }
    }

    @Test func publicNewsletter() {
        #expect(filter.classify(input(sender: "Writer <writer@substack.com>", headers: unsub)) == .public("allowlist.substack"))
        #expect(filter.classify(input(sender: "Medium Daily Digest <noreply@medium.com>",
                                      headers: ["list-unsubscribe": "<mailto:u@medium.com>"])) == .public("allowlist.medium"))
    }

    @Test func publicNeedsValidUnsubscribe() {
        #expect(filter.classify(input(sender: "w@substack.com")) == amb)
        #expect(filter.classify(input(sender: "w@substack.com", headers: ["List-Unsubscribe": ""])) == amb)
        #expect(filter.classify(input(sender: "w@substack.com", headers: ["List-Unsubscribe": "<http://x.example>"])) == amb)
        #expect(filter.classify(input(sender: "w@substack.com", headers: ["List-Unsubscribe": "https://x.example"])) == amb)
    }

    @Test func publicIsExactHostOnly() {
        #expect(filter.classify(input(sender: "w@news.substack.com", headers: unsub)) == amb)
        #expect(filter.classify(input(sender: "w@evilsubstack.com", headers: unsub)) == amb)
        #expect(filter.classify(input(sender: "w@substack.com.evil.com", headers: unsub)) == amb)
    }

    @Test func sensitiveContentOverridesPublicSender() {
        #expect(filter.classify(input(sender: "w@substack.com", subject: "Your receipt 4821", headers: unsub)) == .private("kw.financial.record"))
    }

    @Test func githubNeverPublic() {
        #expect(filter.classify(input(sender: "GitHub <noreply@github.com>", headers: unsub)) == amb)
    }

    @Test func unknownSenderNeedsTriage() {
        #expect(filter.classify(input()) == amb)
    }

    @Test func nonCompleteInspectionNeverPublic() {
        for ins in [ContentInspection.uninspectedParts, .unknown] {
            #expect(filter.classify(input(sender: "w@substack.com", headers: unsub, inspection: ins)) == amb)
        }
        // Private still applies regardless of inspection.
        #expect(filter.classify(input(subject: "Invoice number 12", inspection: .unknown)) == .private("kw.financial.record"))
        #expect(filter.classify(input(sender: "w@substack.com", headers: unsub, inspection: .unknown)) != .public("allowlist.substack"))
    }
}

@Suite struct PrivacyContextualRulesTests {
    @Test func publicTopicNewslettersStayPublic() {
        #expect(trusted("Our invoice software helps teams send invoices faster." + footer) == .public("allowlist.substack"))
        #expect(trusted("How tax policy changes affect small businesses, and why taxes matter." + footer) == .public("allowlist.substack"))
        #expect(trusted("New medical research on sleep and health outcomes was published." + footer) == .public("allowlist.substack"))
    }

    @Test func personalRecordsArePrivate() {
        #expect(trusted("Your appointment with Dr Lee is on Tuesday 5 May") == .private("kw.medical.record"))
        #expect(trusted("Your tax file number 000 000 000 is on record") == .private("kw.tax.record"))
        #expect(trusted("Your bank statement for March. Closing balance $1,204.00") == .private("kw.financial.record"))
        #expect(trusted("Amount due: $120.50") == .private("kw.financial.record"))
        #expect(trusted("Use this verification code 123456") == .private("kw.otp"))
        #expect(trusted("Reset your password here") == .private("kw.credentials"))
    }

    @Test func readerDiagnosisWithAddressNeedsRiskTriage() {
        let body = "A reader wrote in. Jane Citizen was diagnosed with lymphoma last year. My home address is 12 Sample Road, Testville." + footer
        #expect(trusted(body) == .needsTriage(.trustedSenderRisk, signal: "risk.medical.identifiable"))
        let diagnosisNearAddress = "I have diabetes and a phone of +61 412 345 678 if you want to reach me."
        #expect(trusted(diagnosisNearAddress) == .needsTriage(.trustedSenderRisk, signal: "risk.medical.identifiable"))
        let dob = "Diagnosed with epilepsy. DOB: 03/04/1980"
        #expect(trusted(dob) == .needsTriage(.trustedSenderRisk, signal: "risk.medical.identifiable"))
    }

    @Test func namedPersonDirectlyTiedToDiagnosis() {
        #expect(trusted("Pat Example, 54, was diagnosed with a rare condition.")
                == .needsTriage(.trustedSenderRisk, signal: "risk.medical.identifiable"))
        #expect(trusted("Pat Example's cancer returned in spring.")
                == .needsTriage(.trustedSenderRisk, signal: "risk.medical.identifiable"))
        #expect(trusted("Dr Pat Example was diagnosed in a famous study.") == .public("allowlist.substack"))
        #expect(trusted("The Study was treated as a landmark.") == .public("allowlist.substack"))
    }

    @Test func anonymisedAndFooterOnlyStayPublic() {
        #expect(trusted("A 54-year-old man was diagnosed with lymphoma and responded to treatment.") == .public("allowlist.substack"))
        #expect(trusted("Readers say this helped them: \"I was diagnosed with depression and found the advice useful.\"")
                == .public("allowlist.substack"))
        // A footer address far (over 300 characters) from a health article.
        let article = "Cancer research is evolving. " + String(repeating: "Labs continue to publish results worldwide. ", count: 12)
        #expect(trusted(article + footer) == .public("allowlist.substack"))
    }

    @Test func publicFigureContactDetailsGiveNoSignal() {
        #expect(trusted("Contact the minister's office: 1 Parliament Drive, Capital City. Phone (02) 6277 7111.") == .public("allowlist.substack"))
    }

    @Test func sensitiveMatterWithIdentifier() {
        #expect(trusted("My divorce is final. I live at, call me on 0412 345 678.")
                == .needsTriage(.trustedSenderRisk, signal: "risk.identifiable.sensitive"))
        #expect(trusted("Our salary survey results are in.") == .public("allowlist.substack"))
    }

    @Test func embeddedConversationTriggersRisk() {
        let body = "Thanks all.\nOn Mon, 3 Jun 2024, Pat Example <pat@example.com> wrote:\nsome quoted text"
        #expect(trusted(body) == .needsTriage(.trustedSenderRisk, signal: "risk.embedded.conversation"))
        #expect(trusted("Hi\n-----Original Message-----\nFrom: x") == .needsTriage(.trustedSenderRisk, signal: "risk.embedded.conversation"))
        #expect(trusted("Hi\n> one\n> two") == .needsTriage(.trustedSenderRisk, signal: "risk.embedded.conversation"))
        #expect(trusted("Hi\n> a single quote") == .public("allowlist.substack"))
        #expect(trusted("On Mon, 3 Jun 2024, Pat\nExample <p@example.com> wrote:\nx")
                == .needsTriage(.trustedSenderRisk, signal: "risk.embedded.conversation"))
    }

    @Test func personalWordingIsRiskNotPrivate() {
        #expect(trusted("Your invoice is overdue") == .needsTriage(.trustedSenderRisk, signal: "risk.financial.personal"))
        #expect(trusted("Ask about prescriptions") == .needsTriage(.trustedSenderRisk, signal: "risk.medical.personal"))
    }

    @Test func phoneIgnoresDates() {
        #expect(trusted("Diagnosed with cancer on 2024-01-15 and again 15-01-2024.") == .public("allowlist.substack"))
    }

    @Test func sensitiveDomains() {
        let bulk = ["List-Unsubscribe": "<mailto:u@bank.example>"]
        #expect(filter.classify(input(sender: "x@commbank.com.au", body: "Hello there")) == .private("domain.bank"))
        #expect(filter.classify(input(sender: "x@ato.gov.au", body: "Service update", headers: bulk))
                == .needsTriage(.sensitiveSender, signal: nil))
        #expect(filter.classify(input(sender: "x@commbank.com.au", subject: "Your statement is ready", headers: bulk))
                == .private("domain.bank"))
        #expect(filter.classify(input(sender: "x@bupa.com.au", body: "Newsletter. Your prescription is ready", headers: bulk))
                == .private("domain.health"))
    }

    @Test func incompleteInspectionAllowlistedIsNotPublic() {
        #expect(filter.classify(input(sender: substack, headers: unsub, inspection: .uninspectedParts)) == amb)
    }
}

@Suite struct RoutingProvenanceCodableTests {
    @Test func roundTrip() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let prov = RoutingProvenance(
            assessment: PrivacyAssessment(
                verdict: .public, method: .systemOne, ruleID: nil,
                triage: TriageScores(model: "kev:4b-q4_K_M", pSensitive: 0.02, pNonSensitive: 0.98,
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
