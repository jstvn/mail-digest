import Foundation
import Testing
@testable import MailDigestCore

private let filter = PrivacyPreFilter()
private let today = FixtureLoader.today
private let unsub = ["List-Unsubscribe": "<https://example.com/u?id=1>"]

/// A Hide My Email relayed message: the verified `s=` sender matches the alias local part; no List-Unsubscribe.
private func relayed(_ original: String, claimed: String? = nil) -> (from: String, headers: [String: String]) {
    let flat = original.replacingOccurrences(of: "@", with: "_at_").replacingOccurrences(of: ".", with: "_")
    return ("Sender <\(flat)_abc123def456_0a1b2c3d@icloud.com>",
            ["X-ICLOUD-HME": "p=alias@icloud.com; d=login.example.org; f=me@icloud.com; r=to; s=\(claimed ?? original)"])
}

private func input(_ sender: String, headers: [String: String], subject: String = "Hello",
                   body: String = "Just saying hi.") -> PrivacyInput {
    PrivacyInput(sender: sender, subject: subject, body: body, headers: headers, inspection: .complete)
}

@Suite struct Q96PreFilterTests {
    @Test func relayedAllowlistedWithoutUnsubscribeIsPublic() {
        let r = relayed("noreply@glassdoor.com")
        #expect(filter.classify(input(r.from, headers: r.headers)) == .public("allowlist.glassdoor"))
    }

    @Test func relayedReplySubjectIsNotPublic() {
        let r = relayed("noreply@glassdoor.com")
        let v = filter.classify(input(r.from, headers: r.headers, subject: "Re: your application"))
        #expect(v == .needsTriage(.ambiguousSender, signal: nil))
    }

    @Test func relayedWithInReplyToOrReferencesIsNotPublic() {
        let r = relayed("noreply@glassdoor.com")
        for name in ["In-Reply-To", "References"] {
            var h = r.headers
            h[name] = "<abc@example.com>"
            #expect(filter.classify(input(r.from, headers: h)) == .needsTriage(.ambiguousSender, signal: nil))
        }
    }

    @Test func unverifiedRelayHasNoBulkEvidence() {
        // `s=` names a different sender than the alias local part, so Q89 verification fails.
        let r = relayed("noreply@glassdoor.com", claimed: "other@example.com")
        #expect(PrivacyPreFilter.bulkEvidence(sender: r.from, subject: "Hi", headers: r.headers) == nil)
        #expect(filter.classify(input(r.from, headers: r.headers)) == .needsTriage(.ambiguousSender, signal: nil))
    }

    @Test func directMailWithoutUnsubscribeHasNoBulkEvidence() {
        #expect(PrivacyPreFilter.bulkEvidence(sender: "a@glassdoor.com", subject: "Hi", headers: [:]) == nil)
        #expect(filter.classify(input("a@glassdoor.com", headers: [:])) == .needsTriage(.ambiguousSender, signal: nil))
    }

    @Test func unsubscribeWinsWhenBothHold() {
        let r = relayed("noreply@glassdoor.com")
        #expect(PrivacyPreFilter.bulkEvidence(sender: r.from, subject: "Hi", headers: r.headers.merging(unsub) { $1 })
                == .listUnsubscribe)
        #expect(PrivacyPreFilter.bulkEvidence(sender: r.from, subject: "Hi", headers: r.headers) == .hideMyEmail)
    }

    @Test func sensitiveDomainRelayWithoutUnsubscribeStaysPrivate() {
        let r = relayed("news@medibank.com.au")
        let v = filter.classify(input(r.from, headers: r.headers))
        if case .private = v {} else { Issue.record("expected private, got \(v)") }
    }

    @Test(arguments: [
        ("RE: RE: Re: Next steps for your Nike claim", true), ("Fwd: x", true), ("Re[2]: x", true),
        ("回复：x", true), ("  fw: x", true), ("AW: x", true), ("Antw: x", true), ("轉寄：x", true),
        ("Re : x", true), ("Re(3): x", true),
        ("Reminder: x", false), ("Rebates: x", false), ("Re-imagine your feed", false), ("Hello", false),
        ("Trial ends", false), ("", false),
    ])
    func replyPrefixes(_ subject: String, _ expected: Bool) {
        #expect(PrivacyPreFilter.isReplyOrForward(subject: subject, headers: [:]) == expected)
    }

    @Test func filterHeadersKeepsReplyHeaders() {
        let raw = "In-Reply-To: <a@b>\nReferences: <a@b> <c@d>\nSubject: x\nIn-Reply-To: <z@z>"
        #expect(MailJSONDecoder.filterHeaders(raw) == ["In-Reply-To": "<a@b>", "References": "<a@b> <c@d>"])
    }
}

private actor NoopExtractor: EmailExtractor {
    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                 today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        ExtractionResult(summary: "s", category: .other, importance: 2, keyFacts: [], tasks: [])
    }
}

@Suite struct Q96RouterTests {
    private let scores = SystemOneScores(noul: 0.05, categoryProbabilities: [SystemOneSpec.publicCategory: 0.75])

    private func assess(sender: String, headers: [String: String], subject: String = "Hi") async throws -> PrivacyAssessment {
        let e = EmailMessage(id: "m", account: "iCloud", mailbox: "Inbox", sender: sender, subject: subject,
                             receivedAt: today, body: "Hello, a quiet note.", headers: headers, contentInspection: .complete)
        let cfg = CloudRoutingConfig(cloudExtractor: NoopExtractor(), cloudModel: "g", offReason: nil,
                                     triage: StubSystemOneClient(results: [.success(scores)]), triageModel: "sys1",
                                     privacyThreshold: 0.9)
        return try await DigestRouter(clock: FixedClock(today)).assess(e, stored: nil, config: cfg)
    }

    @Test func relayedLinkedInMessagesWaivesWithHideMyEmail() async throws {
        let r = relayed("messages-noreply@linkedin.com")
        let a = try await assess(sender: r.from, headers: r.headers)
        #expect(a.triageTrigger == .ambiguousSender)
        #expect(a.verdict == .public && a.triage?.publicFloorWaiver == .hideMyEmail)
    }

    @Test func relayedReplyDoesNotWaive() async throws {
        let r = relayed("messages-noreply@linkedin.com")
        let a = try await assess(sender: r.from, headers: r.headers, subject: "Re: hello")
        #expect(a.verdict == .uncertain && a.triage?.publicFloorWaiver == nil)
    }

    @Test func unsubscribeBasisWhenBoth() async throws {
        let r = relayed("messages-noreply@linkedin.com")
        let a = try await assess(sender: r.from, headers: r.headers.merging(unsub) { $1 })
        #expect(a.triage?.publicFloorWaiver == .listUnsubscribe)
    }

    @Test func directWithoutUnsubscribeDoesNotWaive() async throws {
        let a = try await assess(sender: "a@example.com", headers: [:])
        #expect(a.verdict == .uncertain && a.triage?.publicFloorWaiver == nil)
    }
}

@Suite struct Q96ProvenanceTests {
    private func decode(_ extra: String) throws -> TriageScores {
        let json = #"{"model":"m","pSensitive":0.1,"pNonSensitive":0.9,"categoryProbabilities":{},"threshold":0.85,"publicFloor":0.85"# + extra + "}"
        return try JSONDecoder().decode(TriageScores.self, from: Data(json.utf8))
    }

    @Test func oldBoolDecodes() throws {
        #expect(try decode(#","publicFloorWaived":true"#).publicFloorWaiver == .listUnsubscribe)
        #expect(try decode(#","publicFloorWaived":false"#).publicFloorWaiver == nil)
        #expect(try decode("").publicFloorWaiver == nil)
    }

    @Test func newBasisRoundTrips() throws {
        for w in [PublicFloorWaiver.listUnsubscribe, .hideMyEmail] {
            let t = TriageScores(model: "m", pSensitive: 0.1, pNonSensitive: 0.9, categoryProbabilities: [:],
                                 threshold: 0.85, publicFloor: 0.85, publicFloorWaiver: w)
            #expect(try JSONDecoder().decode(TriageScores.self, from: JSONEncoder().encode(t)) == t)
        }
    }

    @Test func replayRoutingAppliesWaiver() {
        let chunk = ReplayChunk(pSensitive: 0.05, categoryProbabilities: [SystemOneSpec.publicCategory: 0.75],
                                stateLength: 1, latencySeconds: 0)
        #expect(ReplayRouting.route(method: .systemOne, chunks: [chunk], totalChunks: 1, failure: nil, threshold: 0.9) == .local)
        #expect(ReplayRouting.route(method: .systemOne, chunks: [chunk], totalChunks: 1, failure: nil, threshold: 0.9,
                                    publicFloorWaived: true) == .cloud)
    }
}
