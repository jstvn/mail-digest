import Foundation
import Testing
@testable import MailDigestCore

private let today = FixtureLoader.today
private let tz = FixtureLoader.timeZone
private let icloud = MailboxRef(account: "iCloud", name: "Inbox")

/// Stands in for Gemini: records every call and can be scripted to fail.
private actor RecordingExtractor: EmailExtractor {
    private(set) var calls: [StubExtractCall] = []
    var error: (any Error)?
    var onExtract: (@Sendable () async throws -> Void)?
    let result = ExtractionResult(summary: "Cloud summary.", category: .other, importance: 2, keyFacts: [], tasks: [])

    init(error: (any Error)? = nil) { self.error = error }
    func setOnExtract(_ hook: (@Sendable () async throws -> Void)?) { onExtract = hook }
    func setError(_ e: (any Error)?) { error = e }

    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                 today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        calls.append(StubExtractCall(id: email.id, tier: tier, trustedNewsletter: trustedNewsletter))
        if let onExtract { try await onExtract() }
        if let error { throw error }
        return result
    }
}

private func email(_ id: String = "m1@x", sender: String = "News <news@example.com>", subject: String = "Weekly news",
                   body: String = "Hello, here is this week's newsletter about gardening.",
                   inspection: ContentInspection = .complete, headers: [String: String] = [:]) -> EmailMessage {
    EmailMessage(id: id, account: "iCloud", mailbox: "Inbox", sender: sender, subject: subject,
                 receivedAt: today.addingTimeInterval(-3600), body: body, headers: headers, contentInspection: inspection)
}

private let allowlisted = ("Writer <writer@substack.com>", ["List-Unsubscribe": "<https://substack.com/unsub>"])

private let eligibleScores = SystemOneScores(noul: 0.02, categoryProbabilities: ["public_newsletter_or_promo": 0.97])
private let lowScores = SystemOneScores(noul: 0.4, categoryProbabilities: ["public_newsletter_or_promo": 0.97])
private let malformedScores = SystemOneScores(noul: nil, categoryProbabilities: [:])

private func config(cloud: RecordingExtractor?, triage: (any SystemOneClient)? = nil,
                    off: LocalReason? = nil) -> CloudRoutingConfig {
    CloudRoutingConfig(cloudExtractor: cloud, cloudModel: "gemini-test", offReason: off, triage: triage,
                       triageModel: "sys1", privacyThreshold: 0.9)
}

private func pipeline(_ llm: StubLLMClient, filter: MailFilter = MailFilter()) -> DigestPipeline {
    DigestPipeline(llm: llm, filter: filter, timeZone: tz, clock: FixedClock(today))
}

private func run(_ p: DigestPipeline, _ e: EmailMessage, _ c: CloudRoutingConfig,
                 stored: PrivacyAssessment? = nil) async throws -> EmailOutcome {
    try await p.process(e, today: today, recentSuggestions: [], senderHasApprovedDecision: false,
                        routingConfig: c, storedAssessment: stored)
}

@Suite struct DigestRouterTests {
    @Test func cloudOffMatchesLegacyCallAndMakesNoTriageOrCloudCalls() async throws {
        let llm = StubLLMClient()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let cloud = RecordingExtractor()
        let e = email()
        let out = try await run(pipeline(llm), e, config(cloud: nil, triage: triage, off: .noCredential))
        #expect(await llm.extractCalls == [StubExtractCall(id: e.id, tier: out.tier, trustedNewsletter: false)])
        #expect(await triage.assessCalls.isEmpty)
        #expect((await triage.preflightCalls).isEmpty)
        #expect(await cloud.calls.isEmpty)
        let r = try #require(out.routing)
        #expect(r.assessment.method == .cloudOff && r.assessment.verdict == .notAssessed)
        #expect(r.execution?.provider == .local && r.execution?.localReason == .noCredential)
        #expect(r.execution?.cloudAttempted == false)
    }

    @Test func defaultConfigReportsCloudDisabled() async throws {
        let out = try await pipeline(StubLLMClient()).process(email(), today: today, recentSuggestions: [],
                                                              senderHasApprovedDecision: false)
        #expect(out.routing?.execution?.localReason == .cloudDisabled)
    }

    @Test func privateRuleStaysLocalWithoutTriageOrCloud() async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let e = email(subject: "Your verification code", body: "Your verification code is 123456")
        let out = try await run(pipeline(llm), e, config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.isEmpty)
        #expect((await triage.assessCalls).isEmpty)
        #expect((await triage.preflightCalls).isEmpty)
        #expect(await llm.extractCalls.count == 1)
        #expect(out.routing?.assessment.verdict == .private && out.routing?.assessment.method == .rule)
        #expect(out.routing?.assessment.ruleID == "kw.otp")
        #expect(out.routing?.execution?.localReason == .privateContent)
    }

    @Test(arguments: [ContentInspection.uninspectedParts, .unknown])
    func incompleteInspectionStaysLocalEvenForAllowlistedSender(inspection: ContentInspection) async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let e = email(sender: allowlisted.0, inspection: inspection, headers: allowlisted.1)
        let out = try await run(pipeline(llm), e, config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.isEmpty)
        #expect((await triage.assessCalls).isEmpty)
        #expect(out.routing?.assessment.method == .inspection)
        #expect(out.routing?.execution?.localReason == .contentNotInspected)
        #expect(await llm.extractCalls.count == 1)
    }

    @Test func trustedSenderCompleteGoesToCloudOnly() async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient()
        let e = email(sender: allowlisted.0, headers: allowlisted.1)
        let out = try await run(pipeline(llm), e, config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.count == 1)
        #expect((await llm.extractCalls).isEmpty)
        #expect(await triage.assessCalls.isEmpty)
        #expect(out.info?.summary == "Cloud summary.")
        #expect(out.routing?.assessment.method == .trustedSender)
        #expect(out.routing?.execution?.provider == .cloud && out.routing?.execution?.model == "gemini-test")
    }

    @Test func needsTriageOutcomes() async throws {
        // Eligible scores go to the cloud.
        var llm = StubLLMClient(), cloud = RecordingExtractor()
        var triage = StubSystemOneClient(results: [.success(eligibleScores)])
        var out = try await run(pipeline(llm), email(), config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.count == 1)
        #expect((await llm.extractCalls).isEmpty)
        #expect(out.routing?.assessment.method == .systemOne && out.routing?.execution?.provider == .cloud)
        #expect(await triage.preflightCalls == ["sys1"])

        // Below threshold: local, not eligible.
        llm = StubLLMClient(); cloud = RecordingExtractor()
        triage = StubSystemOneClient(results: [.success(lowScores)])
        out = try await run(pipeline(llm), email(), config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.isEmpty)
        #expect((await llm.extractCalls).count == 1)
        #expect(out.routing?.execution?.localReason == .notEligible)
        #expect(out.routing?.assessment.triage != nil)

        // Malformed scores: local, triage unavailable.
        llm = StubLLMClient(); cloud = RecordingExtractor()
        triage = StubSystemOneClient(results: [.success(malformedScores)])
        out = try await run(pipeline(llm), email(), config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.isEmpty)
        #expect((await llm.extractCalls).count == 1)
        #expect(out.routing?.assessment.triageFailure == .malformedResponse)
        #expect(out.routing?.execution?.localReason == .triageUnavailable)

        // Thrown triage failure: local, no scores.
        llm = StubLLMClient(); cloud = RecordingExtractor()
        triage = StubSystemOneClient(results: [.failure(.timedOut)])
        out = try await run(pipeline(llm), email(), config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.isEmpty)
        #expect(out.routing?.assessment.triageFailure == .timedOut && out.routing?.assessment.triage == nil)

        // Preflight failure: local, no assess call.
        llm = StubLLMClient(); cloud = RecordingExtractor()
        triage = StubSystemOneClient(preflightResult: .modelMissing, results: [.success(eligibleScores)])
        out = try await run(pipeline(llm), email(), config(cloud: cloud, triage: triage))
        #expect(await cloud.calls.isEmpty)
        #expect((await triage.assessCalls).isEmpty)
        #expect(out.routing?.assessment.triageFailure == .modelMissing)
        #expect(out.routing?.execution?.localReason == .triageUnavailable)

        // No triage client at all.
        llm = StubLLMClient(); cloud = RecordingExtractor()
        out = try await run(pipeline(llm), email(), config(cloud: cloud, triage: nil))
        #expect(await cloud.calls.isEmpty)
        #expect((await llm.extractCalls).count == 1)
        #expect(out.routing?.assessment.triageFailure == .unreachable)
    }

    @Test(arguments: [GeminiError.invalidCredential, .rateLimited, .modelUnavailable, .server(503), .timedOut,
                      .network, .blocked, .malformedResponse])
    func cloudErrorFallsBackToLocalOnce(error: GeminiError) async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor(error: error)
        let e = email(sender: allowlisted.0, headers: allowlisted.1)
        let out = try await run(pipeline(llm), e, config(cloud: cloud))
        #expect(await cloud.calls.count == 1)
        #expect((await llm.extractCalls).count == 1)
        let x = try #require(out.routing?.execution)
        #expect(x.provider == .local && x.cloudAttempted && x.localReason == .cloudFailed)
        #expect(x.cloudFailure == error.code)
    }

    @Test func unknownCloudErrorUsesUnknownCode() async throws {
        struct Boom: Error {}
        let cloud = RecordingExtractor(error: Boom())
        let out = try await run(pipeline(StubLLMClient()), email(sender: allowlisted.0, headers: allowlisted.1),
                                config(cloud: cloud))
        #expect(out.routing?.execution?.cloudFailure == "unknown")
    }

    @Test func bothFailingThrowsWithRoutingAndOriginalError() async throws {
        let llm = StubLLMClient(failures: ["m1@x": Int.max]), cloud = RecordingExtractor(error: GeminiError.rateLimited)
        let e = email(sender: allowlisted.0, headers: allowlisted.1)
        let seen = Box<RoutingProvenance>()
        await #expect(throws: StubLLMError.self) {
            _ = try await pipeline(llm).process(e, today: today, recentSuggestions: [], senderHasApprovedDecision: false,
                                                routingConfig: config(cloud: cloud),
                                                onFailedAttempt: { seen.value = $0 })
        }
        let x = try #require(seen.value?.execution)
        #expect(x.cloudAttempted == true)
        #expect(x.cloudFailure == "rateLimited")
        #expect(x.provider == .local)
    }

    @Test func cancellationDuringCloudDoesNotFallBack() async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor(error: CancellationError())
        await #expect(throws: CancellationError.self) {
            _ = try await run(pipeline(llm), email(sender: allowlisted.0, headers: allowlisted.1), config(cloud: cloud))
        }
        #expect(await llm.extractCalls.isEmpty)
    }

    @Test func cancellationDuringTriagePropagates() async throws {
        struct CancellingTriage: SystemOneClient {
            func preflight(model: String) async throws -> TriageFailure? { nil }
            func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores { throw CancellationError() }
        }
        let llm = StubLLMClient(), cloud = RecordingExtractor()
        await #expect(throws: CancellationError.self) {
            _ = try await run(pipeline(llm), email(), config(cloud: cloud, triage: CancellingTriage()))
        }
        #expect(await llm.extractCalls.isEmpty)
        #expect((await cloud.calls).isEmpty)
    }

    @Test func storedAssessmentIsReusedExceptCloudOff() async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let router = DigestRouter(clock: FixedClock(today))
        let c = config(cloud: cloud, triage: triage)
        let stored = PrivacyAssessment(verdict: .uncertain, method: .systemOne, assessedAt: today)
        let reused = try await router.assess(email(), stored: stored, config: c)
        #expect(reused == stored)
        #expect((await triage.preflightCalls).isEmpty)
        let placeholder = PrivacyAssessment(verdict: .notAssessed, method: .cloudOff, assessedAt: today)
        let fresh = try await router.assess(email(), stored: placeholder, config: c)
        #expect(fresh.method == .systemOne && fresh.verdict == .public)
        #expect(await triage.assessCalls.count == 1)
        _ = llm
    }

    @Test func skippedTierMakesNoRouterCalls() async throws {
        let llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let filter = MailFilter(blockedSenders: ["news@example.com"])
        let out = try await run(pipeline(llm, filter: filter), email(), config(cloud: cloud, triage: triage))
        #expect(out.tier == .skip && out.routing == nil)
        #expect(await cloud.calls.isEmpty)
        #expect((await triage.preflightCalls).isEmpty)
        #expect((await llm.extractCalls).isEmpty)
    }

    /// Defence in depth: Gemini is called iff cloud on, fully inspected and verdict public.
    @Test func cloudCalledOnlyWhenOnCompleteAndPublic() async throws {
        let inspections: [ContentInspection] = [.complete, .uninspectedParts, .unknown]
        let senders: [(String, [String: String], String)] = [
            ("Pal <pal@example.com>", [:], "hello"),
            (allowlisted.0, allowlisted.1, "hello"),
            ("Pal <pal@example.com>", [:], "Your one time code is 123456"),
        ]
        let triageOutcomes: [Result<SystemOneScores, TriageFailure>] = [
            .success(eligibleScores), .success(lowScores), .success(malformedScores), .failure(.timedOut)]
        for cloudOn in [true, false] {
            for inspection in inspections {
                for (sender, headers, body) in senders {
                    for outcome in triageOutcomes {
                        for preflight in [nil, TriageFailure.modelMissing] {
                            let cloud = RecordingExtractor()
                            let triage = StubSystemOneClient(preflightResult: preflight, results: [outcome])
                            let e = email(sender: sender, body: body, inspection: inspection, headers: headers)
                            let c = config(cloud: cloudOn ? cloud : nil, triage: triage, off: .cloudDisabled)
                            let out = try await run(pipeline(StubLLMClient()), e, c)
                            let verdict = try #require(out.routing?.assessment.verdict)
                            let expected = cloudOn && inspection == .complete && verdict == .public
                            #expect((await cloud.calls.count == 1) == expected)
                            #expect((out.routing?.execution?.provider == .cloud) == expected)
                            if !cloudOn { #expect(await triage.preflightCalls.isEmpty) }
                        }
                    }
                }
            }
        }
    }

    /// Even a forged public assessment cannot reach Gemini for uninspected content or with cloud off.
    @Test func executeRechecksIndependently() async throws {
        let router = DigestRouter(clock: FixedClock(today))
        let forged = PrivacyAssessment(verdict: .public, method: .trustedSender, assessedAt: today)
        let cloud = RecordingExtractor()
        let llm = StubLLMClient()
        _ = try await router.execute(email(inspection: .unknown), tier: .full, trustedNewsletter: false, today: today,
                                     timeZone: tz, assessment: forged, config: config(cloud: cloud), local: llm,
                                     localModel: "q")
        _ = try await router.execute(email(), tier: .full, trustedNewsletter: false, today: today, timeZone: tz,
                                     assessment: forged, config: config(cloud: nil), local: llm, localModel: "q")
        #expect(await cloud.calls.isEmpty)
        #expect((await llm.extractCalls).count == 2)
    }
}

// MARK: Runner integration

private func messages(_ n: Int, inspection: ContentInspection = .complete, sender: String = "Pal <pal@example.com>") -> [EmailMessage] {
    (0..<n).map { i in
        EmailMessage(id: "r-\(i)@fixture", account: "iCloud", mailbox: "Inbox", sender: sender, subject: "Note \(i)",
                     receivedAt: today.addingTimeInterval(-10 * 86_400 - 600 * Double(i)),
                     body: "Hello there.", headers: [:], contentInspection: inspection)
    }
}

private func runner(_ source: FixtureMailSource, _ llm: StubLLMClient, _ store: InMemoryDigestStore,
                    config: @escaping @Sendable () async -> CloudRoutingConfig) -> JobRunner {
    JobRunner(source: source, llm: llm, store: store, notifier: RecordingNotifier(), clock: FixedClock(today),
              settings: RunnerSettings(timeZone: tz, dailyMailboxes: [icloud]), routingConfig: config, sleep: { _ in })
}

private func plan() -> JobPlan {
    JobPlan(kind: .backlog, mailboxes: [icloud], from: today.addingTimeInterval(-30 * 86_400),
            to: today.addingTimeInterval(60), excludedMessageIDs: [])
}

@Suite struct DigestRouterRunnerTests {
    @Test func cloudOnPersistsRoutingPerItem() async throws {
        let store = InMemoryDigestStore(), llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let c = config(cloud: cloud, triage: triage)
        let r = runner(FixtureMailSource(messages: messages(2)), llm, store, config: { c })
        try await r.start(plan())
        await r.waitUntilIdle()
        let items = await store.allItems()
        #expect(items.allSatisfy { $0.state == .done && $0.routing?.execution?.provider == .cloud && $0.provider == .cloud })
        #expect(await cloud.calls.count == 2)
        #expect((await llm.extractCalls).isEmpty)
    }

    @Test func togglingCloudOffMidJobAppliesToNextEmail() async throws {
        let store = InMemoryDigestStore(), llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let on = config(cloud: cloud, triage: triage)
        let flag = Box<Bool>()
        flag.value = true
        let ids = Box<[String]>()
        ids.value = []
        let rn = Box<JobRunner>()
        await cloud.setOnExtract { flag.value = false }
        let r = runner(FixtureMailSource(messages: messages(3)), llm, store, config: {
            flag.value == true ? on : .localOnly(reason: .cloudDisabled)
        })
        rn.value = r
        try await r.start(plan())
        await r.waitUntilIdle()
        let items = await store.allItems().sorted { $0.messageID < $1.messageID }
        #expect(items.map { $0.routing?.execution?.provider } == [.cloud, .local, .local])
        #expect(items[1].routing?.execution?.localReason == .cloudDisabled)
        #expect(await cloud.calls.count == 1)
    }

    @Test func bothFailingPersistsFailedAttemptRouting() async throws {
        let store = InMemoryDigestStore()
        let llm = StubLLMClient(failures: ["r-0@fixture": Int.max])
        let cloud = RecordingExtractor(error: GeminiError.server(500))
        let c = config(cloud: cloud, triage: StubSystemOneClient(results: [.success(eligibleScores)]))
        let r = runner(FixtureMailSource(messages: messages(1)), llm, store, config: { c })
        try await r.start(plan())
        await r.waitUntilIdle()
        let item = try #require(await store.allItems().first)
        #expect(item.state == .failed && item.attempts == 3 && item.lastError == "malformed")
        let x = try #require(item.routing?.execution)
        #expect(x.cloudAttempted && x.cloudFailure == "server500" && x.provider == .local)
        #expect(item.routing?.assessment.verdict == .public)
    }

    @Test func cancelDuringCloudKeepsAssessmentAndNoExecutionThenResumeSkipsTriage() async throws {
        let store = InMemoryDigestStore(), llm = StubLLMClient(), cloud = RecordingExtractor()
        let triage = StubSystemOneClient(results: [.success(eligibleScores)])
        let c = config(cloud: cloud, triage: triage)
        let entered = Gate()
        let first = Box<Bool>()
        first.value = true
        await cloud.setOnExtract {
            if first.value == true {
                first.value = false
                await entered.fire()
                try await Task.sleep(for: .seconds(60))
            }
        }
        let r = runner(FixtureMailSource(messages: messages(1)), llm, store, config: { c })
        try await r.start(plan())
        await entered.wait()
        await r.pauseNow()
        await r.waitUntilIdle()
        let item = try #require(await store.allItems().first)
        #expect(item.state == .queued)
        #expect(item.routing?.assessment.verdict == .public && item.routing?.execution == nil)
        #expect(await llm.extractCalls.isEmpty)
        let job = try #require(await store.jobs().first)
        try await r.resume(jobID: job.id)
        await r.waitUntilIdle()
        #expect(await triage.assessCalls.count == 1) // not re-triaged on resume
        #expect(await store.allItems().first?.routing?.execution?.provider == .cloud)
    }

    @Test func uninspectedMailStaysLocalInRunner() async throws {
        let store = InMemoryDigestStore(), llm = StubLLMClient(), cloud = RecordingExtractor()
        let c = config(cloud: cloud, triage: StubSystemOneClient(results: [.success(eligibleScores)]))
        let r = runner(FixtureMailSource(messages: messages(1, inspection: .unknown)), llm, store, config: { c })
        try await r.start(plan())
        await r.waitUntilIdle()
        #expect(await cloud.calls.isEmpty)
        #expect(await store.allItems().first?.routing?.execution?.localReason == .contentNotInspected)
    }
}

@Suite struct DigestRouterStoredOverrideTests {
    @Test func privateRuleOverridesStoredPublicAssessment() async throws {
        let router = DigestRouter(clock: FixedClock(Date(timeIntervalSince1970: 1_000)))
        let email = EmailMessage(id: "m1", account: "a", mailbox: "INBOX", sender: "News <news@substack.com>",
                                 subject: "Your verification code", receivedAt: Date(timeIntervalSince1970: 0),
                                 body: "Use 482913 to sign in.", headers: ["List-Unsubscribe": "<https://x.test/u>"],
                                 contentInspection: .complete)
        let stored = PrivacyAssessment(verdict: .public, method: .trustedSender, ruleID: "allowlist.substack",
                                       assessedAt: Date(timeIntervalSince1970: 0))
        let config = CloudRoutingConfig.localOnly(reason: .cloudDisabled)
        let result = try await router.assess(email, stored: stored, config: config)
        #expect(result.verdict == .private)
        #expect(result.method == .rule)
    }
}
