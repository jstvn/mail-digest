import Foundation
import Testing
@testable import MailDigestCore

private let filter = PrivacyPreFilter()
private let unsub = ["List-Unsubscribe": "<https://example.com/u?id=1>"]
private let amb = PreFilterVerdict.needsTriage(.ambiguousSender, signal: nil)
private let today = FixtureLoader.today

private func input(_ sender: String, body: String = "Just saying hi.", headers: [String: String] = unsub,
                   subject: String = "Hello") -> PrivacyInput {
    PrivacyInput(sender: sender, subject: subject, body: body, headers: headers, inspection: .complete)
}

private let glassdoorBody = """
Brisbane jobs for you

Senior Software Engineer
Acme Digital Pty Ltd - Brisbane QLD
$100K - $138K (Glassdoor Est.)
4.1 stars

iOS Developer
Example Labs - Brisbane QLD
$95K - $120K (Glassdoor Est.)

Product Designer
Sample Studio - Fortitude Valley QLD
$90K - $110K (Glassdoor Est.)

You are receiving this job alert because you created it on Glassdoor.
Unsubscribe | Manage alerts https://www.glassdoor.com/alerts/manage?token=abc123
Glassdoor, Inc., 100 Sample Street, Testville
"""

@Suite struct Q95AllowlistTests {
    @Test func glassdoorAndHosts() {
        #expect(filter.classify(input("Glassdoor Jobs <noreply@glassdoor.com>")) == .public("allowlist.glassdoor"))
        #expect(filter.classify(input("a@letterboxd.com")) == .public("allowlist.letterboxd"))
        #expect(filter.classify(input("a@em.linkedin.com")) == .public("allowlist.linkedin.em"))
        #expect(filter.classify(input("a@email.seek.com.au")) == .public("allowlist.seek"))
        #expect(filter.classify(input("a@jora.com")) == .public("allowlist.jora"))
    }

    @Test func linkedInAddressesAreExact() {
        #expect(filter.classify(input("LinkedIn Job Alerts <jobs-noreply@linkedin.com>")) == .public("allowlist.linkedin.jobs"))
        #expect(filter.classify(input("JobAlerts-Noreply@LinkedIn.com")) == .public("allowlist.linkedin.jobalerts"))
        #expect(filter.classify(input("newsletters-noreply@linkedin.com")) == .public("allowlist.linkedin.newsletters"))
        #expect(filter.classify(input("messages-noreply@linkedin.com")) == amb)
        #expect(filter.classify(input("invitations@linkedin.com")) == amb)
        #expect(filter.classify(input("messaging-digest-noreply@linkedin.com")) == amb)
        #expect(filter.classify(input("jobs-noreply@linkedin.com.evil.com")) == amb)
    }

    @Test func noSubdomainMatching() {
        #expect(filter.classify(input("a@sub.glassdoor.com")) == amb)
        #expect(filter.classify(input("a@evilglassdoor.com")) == amb)
    }

    @Test func allowlistStillNeedsUnsubscribe() {
        #expect(filter.classify(input("a@glassdoor.com", headers: [:])) == amb)
    }

    @Test func hideMyEmailRelayUsesVerifiedOriginal() {
        let original = "noreply@glassdoor.com"
        let flat = original.replacingOccurrences(of: "@", with: "_at_").replacingOccurrences(of: ".", with: "_")
        let from = "Glassdoor <\(flat)_abc123def456_0a1b2c3d@icloud.com>"
        var headers = unsub
        headers["X-ICLOUD-HME"] = "p=alias@icloud.com; d=login.example.org; f=me@icloud.com; r=to; s=\(original)"
        #expect(filter.classify(input(from, headers: headers)) == .public("allowlist.glassdoor"))
    }

    @Test func glassdoorJobAlertFixtureStaysPublic() {
        #expect(filter.classify(input("Glassdoor Jobs <noreply@glassdoor.com>", body: glassdoorBody,
                                      subject: "Software Engineer in Brisbane and more")) == .public("allowlist.glassdoor"))
    }
}

@Suite struct Q95EvaluatorTests {
    private func verdict(_ sens: Double, _ pub: Double, waive: Bool) -> PrivacyVerdict {
        let s = SystemOneScores(noul: sens, categoryProbabilities: [SystemOneSpec.publicCategory: pub])
        return TriageEvaluator().evaluate(s, model: "m", threshold: 0.85, waivePublicFloor: waive, assessedAt: today).verdict
    }

    @Test func waiverOn() {
        #expect(verdict(0.149, 0.809, waive: true) == .public)
        #expect(verdict(0.103, 0.737, waive: true) == .public)
        #expect(verdict(0.167, 0.852, waive: true) == .uncertain)
        #expect(verdict(0.212, 0.816, waive: true) == .uncertain)
        #expect(verdict(0.55, 0.9, waive: true) == .private)
    }

    @Test func waiverOff() {
        #expect(verdict(0.149, 0.809, waive: false) == .uncertain)
        #expect(verdict(0.103, 0.737, waive: false) == .uncertain)
    }

    @Test func waiverStillFailsClosedOnMissingPublicScore() {
        let s = SystemOneScores(noul: 0.05, categoryProbabilities: [:])
        let a = TriageEvaluator().evaluate(s, model: "m", threshold: 0.85, waivePublicFloor: true, assessedAt: today)
        #expect(a.verdict == .uncertain && a.triageFailure == .malformedResponse)
    }

    @Test func oldTriageJSONDecodesWithoutWaiver() throws {
        let json = #"{"model":"m","pSensitive":0.1,"pNonSensitive":0.9,"categoryProbabilities":{},"threshold":0.85,"publicFloor":0.85}"#
        let t = try JSONDecoder().decode(TriageScores.self, from: Data(json.utf8))
        #expect(t.publicFloorWaived == false)
        let round = try JSONDecoder().decode(TriageScores.self, from: JSONEncoder().encode(
            TriageScores(model: "m", pSensitive: 0.1, pNonSensitive: 0.9, categoryProbabilities: [:],
                         threshold: 0.85, publicFloor: 0.85, publicFloorWaived: true)))
        #expect(round.publicFloorWaived)
    }
}

private actor NoopExtractor: EmailExtractor {
    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                 today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        ExtractionResult(summary: "s", category: .other, importance: 2, keyFacts: [], tasks: [])
    }
}

@Suite struct Q95RouterTests {
    // pNonSensitive 0.9 passes the 0.9 threshold; public 0.75 fails the 0.85 floor.
    private let scores = SystemOneScores(noul: 0.05, categoryProbabilities: [SystemOneSpec.publicCategory: 0.75])

    private func assess(sender: String, body: String = "Hello, a quiet note.",
                        headers: [String: String]) async throws -> PrivacyAssessment {
        let e = EmailMessage(id: "m", account: "iCloud", mailbox: "Inbox", sender: sender, subject: "Hi",
                             receivedAt: today, body: body, headers: headers, contentInspection: .complete)
        let triage = StubSystemOneClient(results: [.success(scores)])
        let cfg = CloudRoutingConfig(cloudExtractor: NoopExtractor(), cloudModel: "g", offReason: nil,
                                     triage: triage, triageModel: "sys1", privacyThreshold: 0.9)
        return try await DigestRouter(clock: FixedClock(today)).assess(e, stored: nil, config: cfg)
    }

    @Test func ambiguousWithUnsubscribeWaives() async throws {
        let a = try await assess(sender: "a@example.com", headers: unsub)
        #expect(a.triageTrigger == .ambiguousSender)
        #expect(a.verdict == .public && a.triage?.publicFloorWaived == true)
    }

    @Test func noUnsubscribeDoesNotWaive() async throws {
        let a = try await assess(sender: "a@example.com", headers: [:])
        #expect(a.verdict == .uncertain && a.triage?.publicFloorWaived == false)
    }

    @Test func sensitiveSenderDoesNotWaive() async throws {
        let a = try await assess(sender: "news@medibank.com.au", headers: unsub)
        #expect(a.triageTrigger == .sensitiveSender)
        #expect(a.verdict == .uncertain && a.triage?.publicFloorWaived == false)
    }

    @Test func trustedSenderRiskDoesNotWaive() async throws {
        let body = "A reader wrote in. Jane Citizen was diagnosed with lymphoma last year. My home address is 12 Sample Road, Testville."
        let a = try await assess(sender: "w@substack.com", body: body, headers: unsub)
        #expect(a.triageTrigger == .trustedSenderRisk)
        #expect(a.verdict == .uncertain && a.triage?.publicFloorWaived == false)
    }

    @Test func riskSignalOnAmbiguousSenderDoesNotWaive() async throws {
        let body = "A reader wrote in. Jane Citizen was diagnosed with lymphoma last year. My home address is 12 Sample Road, Testville."
        let a = try await assess(sender: "a@example.com", body: body, headers: unsub)
        #expect(a.riskSignal != nil)
        #expect(a.verdict == .uncertain && a.triage?.publicFloorWaived == false)
    }
}
