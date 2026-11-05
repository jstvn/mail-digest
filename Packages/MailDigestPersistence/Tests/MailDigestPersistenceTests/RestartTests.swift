import Foundation
import Testing
import MailDigestCore
import MailDigestPersistence

private let now = Date(timeIntervalSince1970: 1_793_737_800)
private let box = MailboxRef(account: "iCloud", name: "Inbox")
private let count = 24

/// Mail received over the last hours, each with a distinct task so every email yields a suggestion.
private func messages() -> [EmailMessage] {
    (0..<count).map { n in
        EmailMessage(id: "m\(n)@fixture", account: "iCloud", mailbox: "Inbox",
                     sender: "Sam \(n) <sam\(n)@example.com>", subject: "Subject \(n)",
                     receivedAt: now.addingTimeInterval(-3600 - 60 * Double(n)),
                     body: "Hello. Please reply by Friday.", headers: [:])
    }
}

private func rowIDs() -> [String: Int64] {
    Dictionary(uniqueKeysWithValues: (0..<count).map { ("m\($0)@fixture", Int64(1000 + $0)) })
}

private func answers() -> [String: ExtractionResult] {
    Dictionary(uniqueKeysWithValues: messages().map { m in
        (m.id, ExtractionResult(summary: "Summary of \(m.subject)", category: .finance, importance: 2, keyFacts: ["k"], tasks: [
            ExtractedTask(title: "Reply to \(m.subject)", due: nil, dueHasTime: false, priority: .medium,
                          evidence: "Please reply by Friday", confidence: 0.9)]))
    })
}

private func makeRunner(store: any DigestStore, source: FixtureMailSource, llm: StubLLMClient) -> JobRunner {
    JobRunner(source: source, llm: llm, store: store, notifier: RecordingNotifier(), clock: FixedClock(now),
              settings: RunnerSettings(timeZone: TimeZone(identifier: "Australia/Brisbane")!,
                                       dailyMailboxes: [box], waitAfterCheck: .zero),
              sleep: { _ in })
}

private func backlogPlan() -> JobPlan {
    JobPlan(kind: .backlog, mailboxes: [box], from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(60),
            excludedMessageIDs: [])
}

/// Ids and timestamps differ between runs; everything else must match.
private func normalised(_ digest: Digest) -> Digest {
    var d = digest
    d.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    d.suggestions = d.suggestions.map { var s = $0; s.id = d.id; return s }
    return d
}

@Suite struct RestartTests {
    @Test func pausedBacklogSurvivesRestartAndMatchesAnUninterruptedRun() async throws {
        // Reference: one uninterrupted run on the in-memory store.
        let reference = InMemoryDigestStore()
        let refRunner = makeRunner(store: reference, source: FixtureMailSource(messages: messages(), storeRowIDs: rowIDs()),
                                   llm: StubLLMClient(results: answers(), headlineText: "Headline."))
        try await refRunner.start(backlogPlan())
        await refRunner.waitUntilIdle()
        let expected = try #require(await reference.latestDigest())
        #expect(expected.emailCount == count && expected.suggestions.count == count)

        let dir = try TempDir()
        defer { dir.cleanUp() }
        let firstRunIDs: [String]
        let jobID: UUID
        do {
            // Session 1: pause after the 8th email, then drop the runner and the store.
            let store = try GRDBDigestStore(path: dir.databasePath)
            let llm = StubLLMClient(results: answers(), headlineText: "Headline.")
            let runner = makeRunner(store: store, source: FixtureMailSource(messages: messages(), storeRowIDs: rowIDs()), llm: llm)
            let trigger = (try #require(await reference.latestDigest())).info[7].emailID
            await llm.setOnExtract { email in if email.id == trigger { await runner.pause() } }
            try await runner.start(backlogPlan())
            await runner.waitUntilIdle()
            let job = try #require(await store.jobs().first)
            #expect(job.state == .paused)
            #expect(job.totals.done == 8 && job.totals.queued == count - 8)
            firstRunIDs = await llm.extractCalls.map(\.id)
            #expect(firstRunIDs.count == 8)
            jobID = job.id

            // Simulate a crash too: one item was mid-flight and the job was left running.
            let queued = try #require(await store.nextQueued(job: job.id, limit: 1).first)
            try await store.setItemState(queued.id, .processing, error: nil)
            var running = job
            running.state = .running
            try await store.updateJob(running)
        }

        // Session 2: same file, fresh store, runner and fake Mail.
        let store = try GRDBDigestStore(path: dir.databasePath)
        let source = FixtureMailSource(messages: messages(), storeRowIDs: rowIDs())
        let llm = StubLLMClient(results: answers(), headlineText: "Headline.")
        let runner = makeRunner(store: store, source: source, llm: llm)
        let partial = try #require(await store.digest(id: jobID))
        #expect(partial.emailCount == 8) // results were persisted one by one and survive the restart

        try await runner.recoverOnLaunch()
        #expect(try await store.jobs().first?.state == .paused)
        try await runner.resume()
        await runner.waitUntilIdle()

        let secondRunIDs = await llm.extractCalls.map(\.id)
        #expect(secondRunIDs.count == count - 8)
        #expect(Set(secondRunIDs).isDisjoint(with: firstRunIDs)) // nothing reprocessed
        let job = try #require(await store.jobs().first)
        #expect(job.state == .finished && job.totals == JobTotals(queued: 0, done: count, failed: 0, skipped: 0))
        let items = try await store.items(job: jobID)
        #expect(items.allSatisfy { $0.state == .done && $0.attempts == 0 })
        // Native source locators survived and reached the source on resume.
        #expect(items.allSatisfy { $0.storeRowID == rowIDs()[$0.messageID] })
        let references = await source.fetchReferenceCalls.flatMap { $0 }
        #expect(references.count == count - 8)
        #expect(references.allSatisfy { $0.storeRowID == rowIDs()[$0.messageID] })

        let final = try #require(await store.digest(id: jobID))
        #expect(normalised(final) == normalised(expected))
        for email in messages() { #expect(try await store.isProcessed(email.id)) }
    }

    @Test func processedIDsAreNeverReprocessedByALaterDailyRun() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let jobID: UUID
        do {
            let store = try GRDBDigestStore(path: dir.databasePath)
            let runner = makeRunner(store: store, source: FixtureMailSource(messages: messages()),
                                    llm: StubLLMClient(results: answers()))
            try await runner.start(backlogPlan())
            await runner.waitUntilIdle()
            jobID = try #require(await store.jobs().first).id
        }
        let store = try GRDBDigestStore(path: dir.databasePath)
        let llm = StubLLMClient(results: answers())
        let runner = makeRunner(store: store, source: FixtureMailSource(messages: messages()), llm: llm)
        try await runner.startDaily()
        await runner.waitUntilIdle()
        #expect(await llm.extractCalls.isEmpty)
        // Q24: the empty Daily job left no digest, so the backlog digest is still the latest.
        #expect(try await store.latestDigest()?.id == jobID)
        #expect(try await store.jobs().count == 2)
    }

    @Test func retryFailedAfterRestartRebuildsTheDigest() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let bad = "m3@fixture"
        let jobID: UUID
        do {
            let store = try GRDBDigestStore(path: dir.databasePath)
            let runner = makeRunner(store: store, source: FixtureMailSource(messages: messages()),
                                    llm: StubLLMClient(results: answers(), failures: [bad: Int.max]))
            try await runner.start(backlogPlan())
            await runner.waitUntilIdle()
            jobID = try #require(await store.jobs().first).id
            let digest = try #require(await store.digest(id: jobID))
            #expect(digest.emailCount == count && digest.skipped.map(\.id) == [bad])
        }
        let store = try GRDBDigestStore(path: dir.databasePath)
        let runner = makeRunner(store: store, source: FixtureMailSource(messages: messages()),
                                llm: StubLLMClient(results: answers()))
        try await runner.recoverOnLaunch()
        #expect(try await runner.retryFailed(jobID: jobID) == 1)
        await runner.waitUntilIdle()
        let digest = try #require(await store.digest(id: jobID))
        #expect(digest.emailCount == count && digest.skipped.isEmpty && digest.suggestions.count == count)
    }
}
