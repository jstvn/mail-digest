import Foundation
import MailDigestCore

let t0 = Date(timeIntervalSince1970: 1_793_737_800)

/// A unique database path inside a fresh temporary directory (removed by `TempDir.cleanUp`).
struct TempDir {
    let url: URL
    var databasePath: String { url.appendingPathComponent("nested/digest.sqlite").path }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MailDigestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

actor RecordingNotifier: Notifier {
    private(set) var messages: [String] = []
    func post(_ message: String) async { messages.append(message) }
}

let inbox = MailboxRef(account: "iCloud", name: "Inbox", accountID: "ACC-1", mailboxURL: "imap://ACC-1/INBOX")

func makeJob(id: UUID = UUID(), kind: JobKind = .backlog, state: JobState = .running, at date: Date = t0) -> Job {
    Job(id: id, kind: kind, mailboxes: [inbox], scopeFrom: date.addingTimeInterval(-3600), scopeTo: date,
        state: state, createdAt: date, totals: JobTotals(queued: 3, done: 0, failed: 0, skipped: 0),
        autoPaused: false, lastError: nil)
}

func makeHeader(_ id: String, rowID: Int64? = nil, at date: Date = t0) -> MessageHeader {
    MessageHeader(id: id, account: inbox.account, mailbox: inbox.name, sender: "Sam <sam@example.com>",
                  subject: "Subject \(id)", receivedAt: date,
                  sourceReference: MailMessageReference(messageID: id, storeRowID: rowID),
                  accountID: inbox.accountID, mailboxURL: inbox.mailboxURL)
}

func makeInfo(_ email: String, pinned: Bool = false) -> InfoItem {
    InfoItem(id: email, emailID: email, category: .work, importance: 3, summary: "Summary \(email)",
             keyFacts: ["a", "b"], pinned: pinned)
}

func makeSuggestion(_ email: String, title: String = "Task", category: EmailCategory? = .work) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: title, due: t0.addingTimeInterval(86_400.123), dueHasTime: true,
               priority: .high, evidence: "Please reply", confidence: 0.9, preselected: true, flags: ["f"],
               status: .pending, reminderID: nil, category: category)
}

func makeDigest(id: UUID = UUID(), at date: Date = t0, headline: String = "h") -> Digest {
    Digest(id: id, createdAt: date, headline: headline, emailCount: 0, suggestions: [], info: [], skipped: [])
}
