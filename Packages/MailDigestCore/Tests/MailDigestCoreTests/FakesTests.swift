import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_793_737_800)
private let inbox = MailboxRef(account: "iCloud", name: "Inbox")

private func msg(_ id: String, _ offset: TimeInterval, box: MailboxRef = inbox) -> EmailMessage {
    EmailMessage(id: id, account: box.account, mailbox: box.name, sender: "a@b.c", subject: id,
                 receivedAt: t0.addingTimeInterval(offset), body: "body", headers: [:])
}

private func header(_ id: String) -> MessageHeader {
    MessageHeader(id: id, account: "iCloud", mailbox: "Inbox", sender: "s", subject: id, receivedAt: t0)
}

@Suite struct FakesTests {
    @Test func fixturesLoad() throws {
        let emails = try FixtureLoader.loadEmails()
        let results = try FixtureLoader.loadResultsByEmailID()
        #expect(emails.count >= 15)
        #expect(Set(emails.map(\.id)).count == emails.count)
        #expect(emails.allSatisfy { !$0.id.contains("<") && !$0.id.contains(">") })
        #expect(emails.allSatisfy { results[$0.id] != nil })
        let quote = try #require(emails.first { $0.id.hasPrefix("quote-17") })
        #expect(quote.body.contains("wrote:"))
        let assess = try #require(emails.first { $0.id.hasPrefix("uni-assessment-01") })
        #expect(assess.headers.isEmpty)
        let news = try #require(emails.first { $0.id.hasPrefix("news-uni-11") })
        #expect(news.headers["Precedence"] == "list")
        #expect(news.headers["List-Unsubscribe"]?.contains("mailto:") == true)
    }

    @Test func fixtureEvidenceMatchesBodyExceptInjection() throws {
        let emails = try FixtureLoader.loadEmails()
        let results = try FixtureLoader.loadResultsByEmailID()
        for e in emails {
            for task in results[e.id]?.tasks ?? [] {
                let found = e.body.contains(task.evidence)
                #expect(found == !e.id.hasPrefix("inject-16"), "\(e.id)")
            }
        }
    }

    @Test func mailSourceListsAndFetches() async throws {
        let other = MailboxRef(account: "Outlook", name: "Inbox")
        let source = FixtureMailSource(messages: [
            msg("old", -100), msg("new", 0), msg("mid", -50), msg("edge", 100), msg("o", -10, box: other),
        ])
        let headers = try await source.listHeaders(in: inbox, from: t0.addingTimeInterval(-100), to: t0.addingTimeInterval(100))
        #expect(headers.map(\.id) == ["new", "mid", "old"])
        let boxes = try await source.listMailboxes()
        #expect(boxes.count == 2 && boxes.allSatisfy { $0.kind == .inbox })
        let fetched = try await source.fetchMessages(ids: ["mid", "missing", "new"], in: inbox)
        #expect(fetched.map(\.id) == ["mid", "new"])
        #expect(await source.fetchCalls == [["mid", "missing", "new"]])
        #expect(await source.listCalls == 1)
    }

    @Test func generatedInbox() async throws {
        let source = FixtureMailSource.generatedInbox(count: 3000, mailboxes: [inbox], endingAt: t0)
        let headers = try await source.listHeaders(in: inbox, from: .distantPast, to: t0.addingTimeInterval(1))
        #expect(headers.count == 3000)
        #expect(headers.first?.id == "gen-0@fixture")
        let full = try await source.fetchMessages(ids: ["gen-14@fixture", "gen-1@fixture"], in: inbox)
        #expect(full[0].headers["List-Unsubscribe"] != nil)
        #expect(full[1].headers.isEmpty)
    }

    @Test func stubLLMFailuresAndInfoOnly() async throws {
        let withTask = ExtractionResult(summary: "s", category: .uni, importance: 3, keyFacts: [], tasks: [
            ExtractedTask(title: "T", due: nil, dueHasTime: false, priority: .low, evidence: "e", confidence: 0.9)])
        let stub = StubLLMClient(results: ["a": withTask], failures: ["a": 2, "z": Int.max])
        let a = msg("a", 0)
        for _ in 0..<2 {
            await #expect(throws: StubLLMError.malformed) {
                _ = try await stub.extract(a, tier: .full, today: t0, timeZone: .gmt)
            }
        }
        let ok = try await stub.extract(a, tier: .full, today: t0, timeZone: .gmt)
        #expect(ok.tasks.count == 1)
        let info = try await stub.extract(a, tier: .infoOnly, today: t0, timeZone: .gmt)
        #expect(info.tasks.isEmpty)
        await #expect(throws: StubLLMError.malformed) {
            _ = try await stub.extract(msg("z", 0), tier: .full, today: t0, timeZone: .gmt)
        }
        #expect(await stub.extractCalls.count == 5)
        #expect(try await stub.headline(for: [], suggestionCount: 0) == "Stub headline.")
        #expect(await stub.headlineCalls == 1)
        await stub.setHealthy(false)
        await #expect(throws: StubLLMError.unhealthy) { try await stub.healthCheck() }
    }

    @Test func stubLLMHookRespectsCancellation() async throws {
        let stub = StubLLMClient(onExtract: { _ in try await Task.sleep(for: .seconds(30)) })
        let task = Task { try await stub.extract(msg("a", 0), tier: .full, today: t0, timeZone: .gmt) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func stoppedJobIsNotReservedForBacklog() async throws {
        let store = InMemoryDigestStore()
        let job = Job(id: UUID(), kind: .backlog, mailboxes: [], scopeFrom: Date(timeIntervalSince1970: 0),
                      scopeTo: Date(timeIntervalSince1970: 10), state: .paused, createdAt: Date(timeIntervalSince1970: 10),
                      totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        try await store.createJob(job)
        try await store.enqueue([header("a")], job: job.id)
        #expect(try await store.isReservedFromBacklog("a"))
        var stopped = job
        stopped.state = .stopped
        try await store.updateJob(stopped)
        #expect(try await store.isQueued("a"))
        #expect(try await !store.isReservedFromBacklog("a"))
    }

    @Test func storeQueueBasics() async throws {
        let store = InMemoryDigestStore()
        let job = UUID()
        try await store.enqueue([header("a"), header("b")], job: job)
        try await store.enqueue([header("c")], job: job)
        var items = try await store.items(job: job)
        #expect(items.map(\.position) == [1, 2, 3])
        #expect(try await store.isQueued("b"))
        #expect(try await store.nextQueued(job: job, limit: 2).map(\.messageID) == ["a", "b"])

        try await store.setItemState(items[0].id, .processing, error: nil)
        try await store.setItemState(items[1].id, .done, error: nil)
        items = try await store.items(job: job)
        // Q22: starting an item does not count as an attempt; a requeue with an item error does.
        #expect(items[0].attempts == 0)
        #expect(try await store.isQueued("a"))
        #expect(try await !store.isQueued("b"))
        #expect(try await store.requeueInterrupted() == 1)
        #expect(try await store.nextQueued(job: job, limit: 5).map(\.messageID) == ["a", "c"])

        try await store.recordItemOutcome(items[0].id, outcome: "ok", seconds: 2, finishedAt: Date(timeIntervalSince1970: 0))
        #expect(await store.allItems().first?.outcome == "ok")
    }

    @Test func storeDigestsAndSuggestions() async throws {
        let store = InMemoryDigestStore()
        #expect(try await store.lastRunDate() == nil)
        let s = Suggestion(id: UUID(), emailID: "e", title: "T", due: nil, dueHasTime: false, priority: .low,
                           evidence: "x", confidence: 0.8, preselected: true, flags: [], status: .pending, reminderID: nil)
        var d1 = Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 1, suggestions: [s], info: [], skipped: [])
        let d2 = Digest(id: UUID(), createdAt: t0.addingTimeInterval(-86_400), headline: "old", emailCount: 0,
                        suggestions: [], info: [], skipped: [])
        try await store.save(d1); try await store.save(d2)
        d1.headline = "h2"
        try await store.save(d1)
        #expect(await store.allDigests().count == 2)
        #expect(try await store.latestDigest()?.headline == "h2")
        #expect(try await store.lastRunDate() == t0)
        var changed = s
        changed.status = .approved
        try await store.update(changed)
        #expect(try await store.recentSuggestions(since: t0).first?.status == .approved)
        #expect(try await store.recentSuggestions(since: t0.addingTimeInterval(1)).isEmpty)
        try await store.markProcessed(ProcessedEmail(id: "e", receivedAt: t0, tier: .full, processedAt: t0))
        #expect(await store.processedIDs() == ["e"])
    }

    @Test func reminderWriterListLifecycle() async throws {
        let writer = RecordingReminderWriter()
        let id = try await writer.ensureList(named: "Mail Digest", storedID: nil)
        #expect(id == "list-1")
        #expect(try await writer.ensureList(named: "Mail Digest", storedID: id) == id)
        try await writer.renameList(id: id, to: "Digest")
        #expect(await writer.lists[id] == "Digest")
        await #expect(throws: RecordingReminderError.self) { try await writer.renameList(id: "nope", to: "x") }
        await writer.deleteList(id: id)
        let again = try await writer.ensureList(named: "Digest", storedID: id)
        #expect(again == "list-2")
        #expect(await writer.createdLists == ["list-1", "list-2"])

        let s = Suggestion(id: UUID(), emailID: "e", title: "T", due: nil, dueHasTime: false, priority: .low,
                           evidence: "x", confidence: 0.8, preselected: true, flags: [], status: .pending, reminderID: nil)
        #expect(try await writer.write(s, category: .uni, email: nil, toList: again) == "rem-1")
        await writer.setFailingSuggestionIDs([s.id])
        await #expect(throws: RecordingReminderError.writeFailed) { _ = try await writer.write(s, category: .uni, email: nil, toList: again) }
        #expect(await writer.written.count == 1)
    }

    @Test func mailActionsTrashAndRestore() async throws {
        let actions = RecordingMailActions(locations: ["a": inbox, "b": inbox], missingIDs: ["gone"])
        let results = try await actions.moveToTrash(messageIDs: ["a", "gone"])
        #expect(results[0].succeeded && results[0].originalMailbox == "Inbox")
        #expect(!results[1].succeeded && results[1].error == "not found")
        #expect(await actions.location(of: "a") == MailboxRef(account: "iCloud", name: "Trash"))
        try await actions.restore(results)
        #expect(await actions.location(of: "a") == inbox)
        let moved = try await actions.move(messageIDs: ["b"], toMailboxNamed: "Processed", createIfMissing: true)
        #expect(await actions.location(of: "b") == MailboxRef(account: "iCloud", name: "Processed"))
        try await actions.restore(moved)
        #expect(await actions.location(of: "b") == inbox)
        #expect(await actions.calls.count == 2)
    }

    @Test func fixedClock() {
        let clock = FixedClock(t0)
        clock.advance(by: 60)
        #expect(clock.now() == t0.addingTimeInterval(60))
        clock.set(t0)
        #expect(clock.now() == t0)
    }
}
