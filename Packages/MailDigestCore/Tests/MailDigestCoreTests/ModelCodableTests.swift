import XCTest
@testable import MailDigestCore

final class ModelCodableTests: XCTestCase {
    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_003_600)
    private let uuid1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let uuid2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let box = MailboxRef(account: "iCloud", name: "Inbox")

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(back, value, file: file, line: line)
    }

    private var suggestion: Suggestion {
        Suggestion(id: uuid1, emailID: "m1", title: "Pay rent", due: d2, dueHasTime: true, priority: .high,
                   evidence: "Rent due Friday", confidence: 0.9, preselected: false,
                   flags: ["money-new-sender"], status: .pending, reminderID: nil)
    }
    private var info: InfoItem {
        InfoItem(id: "m1", emailID: "m1", category: .finance, importance: 4, summary: "Rent due.",
                 keyFacts: ["$400"], pinned: true)
    }
    private var item: JobItem {
        JobItem(id: uuid2, jobID: uuid1, messageID: "m1", mailbox: box, sender: "a@b.c", subject: "Hi",
                receivedAt: d1, position: 1, state: .failed, outcome: "x", seconds: 1.5, attempts: 2, lastError: "boom")
    }
    private var summary: JobItemSummary {
        JobItemSummary(messageID: "m1", sender: "a@b.c", subject: "Hi", mailbox: box, position: 3, outcome: nil)
    }

    func testEmailModels() throws {
        try roundTrip(EmailMessage(id: "m1", account: "iCloud", mailbox: "Inbox", sender: "A <a@b.c>", subject: "S",
                                   receivedAt: d1, body: "body", headers: ["Precedence": "bulk"]))
        try roundTrip(MessageHeader(id: "m1", account: "iCloud", mailbox: "Inbox", sender: "A", subject: "S", receivedAt: d1))
        try roundTrip(ProcessedEmail(id: "m1", receivedAt: d1, tier: .infoOnly, processedAt: d2))
        for t in [MailTier.skip, .infoOnly, .full] { try roundTrip(t) }
    }

    func testDigestModels() throws {
        try roundTrip(info)
        try roundTrip(suggestion)
        try roundTrip(SkippedEmail(id: "m2", sender: "s", subject: "t", reason: "blocked"))
        try roundTrip(Digest(id: uuid1, createdAt: d1, headline: "h", emailCount: 2, suggestions: [suggestion],
                             info: [info], skipped: [SkippedEmail(id: "m2", sender: "s", subject: "t", reason: "r")]))
        try roundTrip(Decision(suggestionID: uuid1, sender: "s", action: .approved, decidedAt: d2))
        for c in Category.allCases { try roundTrip(c) }
        try roundTrip(Priority.low)
        try roundTrip(SuggestionStatus.failed)
    }

    func testMailboxAndActionModels() throws {
        try roundTrip(box)
        try roundTrip(MailboxInfo(ref: box, messageCount: 10, unreadCount: 2, kind: .inbox))
        try roundTrip(MailboxKind.custom)
        try roundTrip(MailActionResult(messageID: "m1", account: "iCloud", originalMailbox: "Inbox", succeeded: false, error: "nf"))
        try roundTrip(MailActionResult(messageID: "m1", account: "iCloud", originalMailbox: "Inbox", succeeded: true,
                                       error: nil, destinationMailbox: "Trash"))
        // Data saved before `destinationMailbox` existed still decodes.
        let old = #"{"messageID":"m","account":"a","originalMailbox":"Inbox","succeeded":true}"#
        let decoded = try JSONDecoder().decode(MailActionResult.self, from: Data(old.utf8))
        XCTAssertNil(decoded.destinationMailbox)
        XCTAssertTrue(decoded.succeeded)
    }

    func testExtractionModels() throws {
        let task = ExtractedTask(title: "T", due: "2026-01-02", dueHasTime: false, priority: .medium, evidence: "e", confidence: 0.5)
        try roundTrip(task)
        try roundTrip(ExtractedTask(title: "T", due: nil, dueHasTime: false, priority: .low, evidence: "e", confidence: 0.1))
        try roundTrip(ExtractionResult(summary: "s", category: .uni, importance: 3, keyFacts: ["a"], tasks: [task]))
    }

    func testExtractionResultSnakeCaseAndNullDue() throws {
        let json = """
        {"summary":"s","category":"work","importance":2,"key_facts":["f"],
         "tasks":[{"title":"T","due":null,"due_has_time":true,"priority":"high","evidence":"e","confidence":0.8}]}
        """
        let r = try JSONDecoder().decode(ExtractionResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.keyFacts, ["f"])
        XCTAssertNil(r.tasks[0].due)
        XCTAssertTrue(r.tasks[0].dueHasTime)

        let out = try String(decoding: JSONEncoder().encode(r.tasks[0]), as: UTF8.self)
        XCTAssertTrue(out.contains("\"due\":null"), out)
        XCTAssertTrue(out.contains("\"due_has_time\":true"), out)
        let whole = try String(decoding: JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertTrue(whole.contains("\"key_facts\""), whole)
    }

    func testJobModels() throws {
        try roundTrip(JobPlan(kind: .backlog, mailboxes: [box], from: d1, to: d2, excludedMessageIDs: ["a", "b"]))
        try roundTrip(JobTotals(queued: 1, done: 2, failed: 3, skipped: 4))
        try roundTrip(Job(id: uuid1, kind: .daily, mailboxes: [box], scopeFrom: d1, scopeTo: d2, state: .paused,
                          createdAt: d1, totals: JobTotals(queued: 1, done: 2, failed: 3, skipped: 4), autoPaused: true))
        try roundTrip(item)
        try roundTrip(summary)
        try roundTrip(MailboxProgress(done: 1, total: 5))
        try roundTrip(JobProgress(jobID: uuid1, kind: .backlog, state: .running, done: 4, total: 9, failed: 1,
                                  avgSecondsPerEmail: 12.5, eta: 60, stage: .summarising, current: summary,
                                  lastFinished: summary, nextUp: nil,
                                  countsByMailbox: [box: MailboxProgress(done: 4, total: 9)]))
        for s in [JobState.idle, .listing, .running, .pausing, .paused, .stopping, .finished, .failed] { try roundTrip(s) }
        for s in [JobStage.listing, .fetching, .summarising, .validating, .saving] { try roundTrip(s) }
        for s in [JobItemState.queued, .processing, .done, .failed, .skipped] { try roundTrip(s) }
    }
}
