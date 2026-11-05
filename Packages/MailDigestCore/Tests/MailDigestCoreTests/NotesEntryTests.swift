import Foundation
import Testing
@testable import MailDigestCore

private let utc = TimeZone(identifier: "UTC")!
private let day = Date(timeIntervalSince1970: 1_793_737_800) // 2026-11-03 in UTC

private func item(summary: String = "Rent is due", facts: [String] = ["$450", "Fri"]) -> InfoItem {
    InfoItem(id: "e", emailID: "e", category: .finance, importance: 3, summary: summary, keyFacts: facts, pinned: false)
}

@Suite struct NotesEntryTests {
    @Test func titleHasDateSenderAndSubject() {
        let email = EmailContext(sender: "Landlord <rent@x.com>", subject: "November rent",
                                 mailbox: MailboxRef(account: "iCloud", name: "Inbox"))
        let e = NotesEntry.make(for: item(), email: email, date: day, timeZone: utc)
        #expect(e.title == "3 Nov 2026 · Landlord · November rent")
        #expect(e.summary == "Rent is due" && e.keyFacts == ["$450", "Fri"])
    }

    @Test func titleIsJustTheDateWithoutContext() {
        #expect(NotesEntry.make(for: item(), email: nil, date: day, timeZone: utc).title == "3 Nov 2026")
    }

    @Test func htmlEscapesUntrustedText() {
        let e = NotesEntry(title: "A <b>&</b>", summary: "x \"y\" 'z'\nnext", keyFacts: ["<script>alert(1)</script>"])
        #expect(e.html == "<div><b>A &lt;b&gt;&amp;&lt;/b&gt;</b></div><div>x &quot;y&quot; &#39;z&#39;<br>next</div>"
            + "<ul><li>&lt;script&gt;alert(1)&lt;/script&gt;</li></ul><div><br></div>")
    }

    @Test func htmlOmitsEmptyFactList() {
        #expect(!NotesEntry(title: "t", summary: "s", keyFacts: []).html.contains("<ul>"))
    }

    @Test func titleCollapsesLineBreaksInSubject() {
        let email = EmailContext(sender: "a@b.com", subject: "Line one\nLine two", mailbox: MailboxRef(account: "A", name: "Inbox"))
        #expect(NotesEntry.make(for: item(), email: email, date: day, timeZone: utc).title.contains("Line one Line two"))
    }

    @Test func recordingWriterRecordsAndFails() async throws {
        let w = RecordingNotesWriter()
        let e = NotesEntry(title: "t", summary: "s", keyFacts: [])
        try await w.append(e)
        #expect(await w.entries == [e])
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await RecordingNotesWriter(failure: Boom()).append(e) }
    }
}
