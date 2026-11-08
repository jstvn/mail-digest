import Foundation
import Testing
@testable import MailDigestCore

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/mail/\(name)")
    return try Data(contentsOf: url)
}

@Suite struct MailJSONDecoderTests {
    let decoder = MailJSONDecoder()

    @Test func decodesMailboxes() throws {
        let boxes = try decoder.decodeMailboxes(fixture("list-mailboxes.json"))
        #expect(boxes.count == 14)
        let bin = try #require(boxes.first { $0.ref == MailboxRef(account: "Outlook", name: "Bin") })
        #expect(bin.kind == .trash)
        let nested = try #require(boxes.first { $0.ref.name == "Projects/Uni" })
        #expect(nested.kind == .custom)
        #expect(nested.unreadCount == 2)
        let unknown = try #require(boxes.first { $0.ref.name == "Conversation History" })
        #expect(unknown.kind == .custom)
        #expect(Set(boxes.filter { $0.ref.account == "iCloud" }.map(\.kind)) ==
                [.inbox, .archive, .sent, .drafts, .junk, .trash, .custom])
    }

    @Test func decodesHeadersAndStripsBrackets() throws {
        let headers = try decoder.decodeHeaders(fixture("list-mail.json"))
        #expect(headers.count == 5)
        #expect(headers.allSatisfy { !$0.id.contains("<") && !$0.id.contains(">") })
        #expect(headers[0].id == "a1@example.com")
        #expect(headers[0].receivedAt == Date(timeIntervalSince1970: 1_793_693_700))
        #expect(abs(headers[1].receivedAt.timeIntervalSince1970 - 1_793_691_612.345) < 0.001)
    }

    @Test func idsLoseWhitespaceToo() throws {
        let json = #"[{"id":" <x@y> \n","account":"a","mailbox":"m","sender":"s","subject":"t","receivedAt":"2026-11-03T08:15:00Z"}]"#
        #expect(try decoder.decodeHeaders(Data(json.utf8))[0].id == "x@y")
    }

    @Test func decodesFetchObjectForm() throws {
        let result = try decoder.decodeFetchOutput(fixture("fetch-mail.json"))
        #expect(result.messages.count == 2)
        #expect(result.missingIDs == ["gone1@example.com"])
        #expect(result.messages.allSatisfy { $0.contentInspection == .unknown && $0.inspectionGap == .structureUnavailable })
        let first = result.messages[0]
        #expect(first.id == "f1@example.com")
        // Mixed-case names are canonicalised and the folded value is joined with one space.
        #expect(first.headers == [
            "List-Unsubscribe": "<mailto:unsub@example.com>, <https://example.com/unsub?id=1>",
            "Precedence": "bulk",
        ])
        // Parsing stops at the blank line, so the body-section header is ignored.
        #expect(result.messages[1].headers == ["Auto-Submitted": "auto-generated"])
    }

    @Test func decodesBareArrayFetchForm() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: fixture("fetch-mail.json")) as? [String: Any])
        let bare = try JSONSerialization.data(withJSONObject: try #require(object["messages"]))
        let result = try decoder.decodeFetchOutput(bare)
        #expect(result.messages.count == 2)
        #expect(result.missingIDs.isEmpty)
    }

    @Test func filterHeadersKeepsOnlyThree() {
        let raw = "From: a@b.c\nSubject: hi\nLIST-UNSUBSCRIBE: <mailto:x@y>\nprecedence: list\nAuto-Submitted: auto-replied\nX-Other: no\n"
        #expect(MailJSONDecoder.filterHeaders(raw) == [
            "List-Unsubscribe": "<mailto:x@y>", "Precedence": "list", "Auto-Submitted": "auto-replied",
        ])
    }

    @Test func filterHeadersHandlesCRLFTabFoldAndFirstWins() {
        let raw = "List-Unsubscribe: <a>,\r\n\t<b>\r\nPrecedence: bulk\r\nPrecedence: list\r\n\r\nAuto-Submitted: yes\r\n"
        #expect(MailJSONDecoder.filterHeaders(raw) == ["List-Unsubscribe": "<a>, <b>", "Precedence": "bulk"])
        #expect(MailJSONDecoder.filterHeaders("").isEmpty)
    }

    @Test func parsesDatesWithAndWithoutMilliseconds() throws {
        func one(_ date: String) throws -> Date {
            let json = #"{"id":"i","account":"a","mailbox":"m","sender":"s","subject":"t","receivedAt":"\#(date)","body":"b","rawHeaders":""}"#
            return try decoder.decodeMessage(Data(json.utf8)).receivedAt
        }
        #expect(try one("2026-11-03T08:15:00Z") == one("2026-11-03T08:15:00.000Z"))
        #expect(try one("2026-11-03T18:15:00+10:00") == one("2026-11-03T08:15:00Z"))
    }

    @Test func invalidDateThrowsWithString() {
        let json = #"[{"id":"i","account":"a","mailbox":"m","sender":"s","subject":"t","receivedAt":"yesterday"}]"#
        #expect(throws: MailDecodingError.invalidDate("yesterday")) {
            try decoder.decodeHeaders(Data(json.utf8))
        }
    }

    @Test func malformedJSONThrows() {
        #expect(throws: MailDecodingError.self) { try decoder.decodeMailboxes(Data("not json".utf8)) }
        #expect(throws: MailDecodingError.self) { try decoder.decodeHeaders(Data("{}".utf8)) }
        #expect(throws: MailDecodingError.self) { try decoder.decodeFetchOutput(Data("[1]".utf8)) }
        #expect(throws: MailDecodingError.self) { try decoder.decodeMessage(Data("[]".utf8)) }
    }

    @Test func allEmailFixturesLoadViaDecoder() throws {
        let emails = try FixtureLoader.loadEmails()
        #expect(emails.count == 18)
        #expect(emails.allSatisfy { !$0.id.contains("<") })
    }

    @Test func leadingBlankLinesDoNotHideHeaders() {
        let raw = "\n\nPrecedence: bulk\nFrom: a@b.c\n\nList-Unsubscribe: <x>"
        #expect(MailJSONDecoder.filterHeaders(raw) == ["Precedence": "bulk"])
    }
}
