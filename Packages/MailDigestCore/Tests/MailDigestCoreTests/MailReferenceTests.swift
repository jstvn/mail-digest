import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let box = MailboxRef(account: "iCloud", name: "Inbox", accountID: "ACC-1", mailboxURL: "imap://ACC-1/INBOX")

private func header(_ id: String, at t: Date = t0, row: Int64? = nil) -> MessageHeader {
    MessageHeader(id: id, account: "A", mailbox: "Inbox", sender: "s", subject: id, receivedAt: t,
                  sourceReference: row.map { MailMessageReference(messageID: id, storeRowID: $0) })
}

@Suite struct TypedReferenceTests {
    @Test func oldJSONDecodesWithDefaults() throws {
        let boxJSON = #"{"account":"iCloud","name":"Inbox"}"#
        let ref = try JSONDecoder().decode(MailboxRef.self, from: Data(boxJSON.utf8))
        #expect(ref == MailboxRef(account: "iCloud", name: "Inbox"))

        let headerJSON = #"{"id":"m1","account":"A","mailbox":"Inbox","sender":"s","subject":"x","receivedAt":0}"#
        let h = try JSONDecoder().decode(MessageHeader.self, from: Data(headerJSON.utf8))
        #expect(h.sourceReference == MailMessageReference(messageID: "m1", storeRowID: nil))
        #expect(h.accountID == nil && h.mailboxURL == nil)

        let emailJSON = #"{"id":"m1","account":"A","mailbox":"Inbox","sender":"s","subject":"x","receivedAt":0,"body":"b","headers":{}}"#
        let e = try JSONDecoder().decode(EmailMessage.self, from: Data(emailJSON.utf8))
        #expect(e.sourceReference.messageID == "m1")

        let itemJSON = #"{"id":"11111111-1111-1111-1111-111111111111","jobID":"22222222-2222-2222-2222-222222222222","messageID":"m1","mailbox":{"account":"A","name":"Inbox"},"sender":"s","subject":"x","receivedAt":0,"position":1,"state":"queued","attempts":0}"#
        let item = try JSONDecoder().decode(JobItem.self, from: Data(itemJSON.utf8))
        #expect(item.storeRowID == nil)
        #expect(item.reference == MailMessageReference(messageID: "m1", storeRowID: nil))
    }

    @Test func newFieldsRoundTrip() throws {
        let h = MessageHeader(id: "m1", account: "iCloud", mailbox: "Inbox", sender: "s", subject: "x", receivedAt: t0,
                              sourceReference: MailMessageReference(messageID: "m1", storeRowID: 42),
                              accountID: "ACC-1", mailboxURL: "imap://ACC-1/INBOX")
        let back = try JSONDecoder().decode(MessageHeader.self, from: JSONEncoder().encode(h))
        #expect(back == h)
        #expect(back.mailboxRef == box)
    }

    @Test func enqueuePersistsRowIDAndMailboxLocator() async throws {
        let store = InMemoryDigestStore()
        let job = UUID()
        let h = MessageHeader(id: "m1", account: "iCloud", mailbox: "Inbox", sender: "s", subject: "x", receivedAt: t0,
                              sourceReference: MailMessageReference(messageID: "m1", storeRowID: 7),
                              accountID: "ACC-1", mailboxURL: "imap://ACC-1/INBOX")
        try await store.enqueue([h], job: job)
        let item = try #require(try await store.nextQueued(job: job, limit: 1).first)
        #expect(item.storeRowID == 7)
        #expect(item.mailbox == box)
    }

    @Test func runnerPassesRowIDsToSource() async throws {
        let msg = EmailMessage(id: "m1@x", account: "iCloud", mailbox: "Inbox", sender: "Sam <sam@example.com>",
                               subject: "Hi", receivedAt: FixtureLoader.today.addingTimeInterval(-3600),
                               body: "Hello", headers: [:])
        let source = FixtureMailSource(messages: [msg], storeRowIDs: ["m1@x": 4242])
        let inbox = MailboxRef(account: "iCloud", name: "Inbox")
        let runner = JobRunner(source: source, llm: StubLLMClient(results: [:], headlineText: "h"),
                               store: InMemoryDigestStore(), notifier: RecordingNotifier(),
                               clock: FixedClock(FixtureLoader.today),
                               settings: RunnerSettings(timeZone: FixtureLoader.timeZone, filter: MailFilter(),
                                                        dailyMailboxes: [inbox]),
                               sleep: { _ in })
        let plan = JobPlan(kind: .backlog, mailboxes: [inbox], from: FixtureLoader.today.addingTimeInterval(-86_400),
                           to: FixtureLoader.today, excludedMessageIDs: [])
        try await runner.start(plan)
        await runner.waitUntilIdle()
        let calls = await source.fetchReferenceCalls
        #expect(calls.flatMap { $0 } == [MailMessageReference(messageID: "m1@x", storeRowID: 4242)])
    }

    @Test func fetchByIDsConvenienceUsesNilRowIDs() async throws {
        let source = FixtureMailSource(messages: [])
        _ = try await source.fetchMessages(ids: ["a"], in: box)
        #expect(await source.fetchReferenceCalls == [[MailMessageReference(messageID: "a", storeRowID: nil)]])
    }
}

@Suite struct MessageIDTests {
    @Test(arguments: [
        ("<a@b.example>", "a@b.example"), ("  <a@b.example>  ", "a@b.example"), ("a@b.example", "a@b.example"),
        ("<a@b.example> (comment)", "a@b.example"), ("<a@b\r\n .example>", nil), ("a@b.example>", "a@b.example"),
        ("", nil), ("   ", nil), ("<>", nil), ("two words", nil),
    ] as [(String, String?)])
    func canonical(raw: String, expected: String?) {
        #expect(MessageID.canonical(raw) == expected)
    }

    @Test func foldedIDIsUnfolded() {
        #expect(MessageID.canonical("\r\n <abc@x.example>") == "abc@x.example")
    }
}

@Suite struct DecoderWireFormatTests {
    let decoder = MailJSONDecoder()

    @Test func headerListingCountsMissingIdentity() throws {
        let json = """
        [{"id":"<a@x.example>","account":"A","mailbox":"Inbox","sender":"s","subject":"1","receivedAt":"2026-11-04T00:00:00Z",
          "storeRowID":9,"accountID":"ACC","mailboxURL":"imap://ACC/INBOX"},
         {"id":"","account":"A","mailbox":"Inbox","sender":"s","subject":"2","receivedAt":"2026-11-04T00:00:00Z"},
         {"account":"A","mailbox":"Inbox","sender":"s","subject":"3","receivedAt":"2026-11-04T00:00:00Z"},
         {"id":"b@x.example","account":"A","mailbox":"Inbox","sender":"s","subject":"4","receivedAt":"2026-11-04T00:00:00Z"}]
        """
        let listing = try decoder.decodeHeaderListing(Data(json.utf8))
        #expect(listing.missingIdentityCount == 2)
        #expect(listing.headers.map(\.id) == ["a@x.example", "b@x.example"])
        #expect(listing.headers[0].sourceReference.storeRowID == 9)
        #expect(listing.headers[0].accountID == "ACC")
        #expect(listing.headers[0].mailboxURL == "imap://ACC/INBOX")
        #expect(listing.headers[1].sourceReference.storeRowID == nil)
        #expect(listing.headers[1].accountID == nil)
        #expect(try decoder.decodeHeaders(Data(json.utf8)).count == 2)
    }

    @Test func mailboxKeysOptional() throws {
        let json = """
        [{"account":"A","name":"Inbox","kind":"inbox","messageCount":1,"unreadCount":0,"accountID":"ACC","mailboxURL":"imap://ACC/INBOX"},
         {"account":"A","name":"Old","kind":"custom","messageCount":1,"unreadCount":0}]
        """
        let boxes = try decoder.decodeMailboxes(Data(json.utf8))
        #expect(boxes[0].ref.accountID == "ACC" && boxes[0].ref.mailboxURL == "imap://ACC/INBOX")
        #expect(boxes[1].ref.accountID == nil && boxes[1].ref.mailboxURL == nil)
    }

    @Test func fetchStoreRowIDOptional() throws {
        let with = #"{"messages":[{"id":"<m@x.example>","account":"A","mailbox":"I","sender":"s","subject":"x","receivedAt":"2026-11-04T00:00:00Z","body":"b","storeRowID":77}]}"#
        let without = #"{"messages":[{"id":"<m@x.example>","account":"A","mailbox":"I","sender":"s","subject":"x","receivedAt":"2026-11-04T00:00:00Z","body":"b"}]}"#
        #expect(try decoder.decodeFetchOutput(Data(with.utf8)).messages[0].sourceReference ==
                MailMessageReference(messageID: "m@x.example", storeRowID: 77))
        #expect(try decoder.decodeFetchOutput(Data(without.utf8)).messages[0].sourceReference ==
                MailMessageReference(messageID: "m@x.example", storeRowID: nil))
    }
}

@Suite struct MailboxURLTests {
    @Test func parsesShapes() throws {
        let imap = try #require(MailboxURL("imap://CD44D279-C263-4299-A43B-A87D0E8BA87D/INBOX"))
        #expect(imap.scheme == "imap" && imap.accountID == "CD44D279-C263-4299-A43B-A87D0E8BA87D")
        #expect(imap.pathComponents == ["INBOX"] && !imap.isLocal)
        let nested = try #require(MailboxURL("ews://ACC/Parent/Child"))
        #expect(nested.pathComponents == ["Parent", "Child"] && nested.displayPath == "Parent/Child")
        let local = try #require(MailboxURL("local://ACC/Some%20Box"))
        #expect(local.isLocal && local.pathComponents == ["Some Box"])
    }

    @Test func encodedSlashStaysInOneComponent() throws {
        let u = try #require(MailboxURL("imap://ACC/A%2FB/C"))
        #expect(u.pathComponents == ["A/B", "C"])
        // Such a component is not a safe directory name.
        #expect(MailStoreLayout.mailboxDirectoryComponents(for: u) == nil)
    }

    @Test(arguments: ["INBOX", "imap://ACC", "imap://ACC/", "://ACC/x", "imap:///x", "imap://ACC/a//b"])
    func malformed(raw: String) { #expect(MailboxURL(raw) == nil) }
}

@Suite struct MailStoreLayoutTests {
    @Test(arguments: [(999, []), (9865, ["9"]), (19926, ["9", "1"]), (262653, ["2", "6", "2"]),
                      (1234567, ["4", "3", "2", "1"])] as [(Int64, [String])])
    func hashDirectories(row: Int64, expected: [String]) {
        #expect(MailStoreLayout.hashDirectoryComponents(rowID: row) == expected)
    }

    @Test func mailboxDirectoriesAndFileNames() throws {
        let u = try #require(MailboxURL("ews://ACC/Parent/Child"))
        #expect(MailStoreLayout.mailboxDirectoryComponents(for: u) == ["ACC", "Parent.mbox", "Child.mbox"])
        let names = MailStoreLayout.messageFileNames(rowID: 12)
        #expect(names.full == "12.emlx" && names.partial == "12.partial.emlx")
    }

    @Test func rejectsTraversal() throws {
        #expect(MailStoreLayout.mailboxDirectoryComponents(for: try #require(MailboxURL("imap://ACC/../etc"))) == nil)
        #expect(MailStoreLayout.mailboxDirectoryComponents(for: try #require(MailboxURL("imap://ACC/./x"))) == nil)
        #expect(MailStoreLayout.mailboxDirectoryComponents(for: try #require(MailboxURL("imap://ACC/a%00b"))) == nil)
        #expect(MailStoreLayout.mailboxDirectoryComponents(for: try #require(MailboxURL("imap://../x"))) == nil)
    }
}

@Suite struct ActiveAccountPolicyTests {
    let imap = MailboxURL("imap://AAAAAAAA-1111/INBOX")!
    let local = MailboxURL("local://BBBBBBBB-2222/Box")!

    @Test func withoutAutomationUsesExactDirectoryName() {
        let p = ActiveAccountPolicy(automationAccountIDs: nil,
                                    storeDirectoryNames: ["AAAAAAAA-1111", "OrphanedAccount - CCCCCCCC-3333"])
        #expect(p.includes(imap))
        #expect(!p.includes(MailboxURL("imap://CCCCCCCC-3333/INBOX")!))
        #expect(p.includes(local))
    }

    @Test func automationMembershipWins() {
        let p = ActiveAccountPolicy(automationAccountIDs: ["DDDDDDDD-4444"], storeDirectoryNames: ["AAAAAAAA-1111"])
        #expect(!p.includes(imap))
        #expect(p.includes(MailboxURL("ews://DDDDDDDD-4444/INBOX")!))
        #expect(p.includes(local))
    }

    @Test func displayNames() {
        let p = ActiveAccountPolicy(automationAccountIDs: ["AAAAAAAA-1111"], automationNames: ["AAAAAAAA-1111": "iCloud"],
                                    storeDirectoryNames: [])
        #expect(p.displayName(forAccountID: "AAAAAAAA-1111") == "iCloud")
        #expect(p.displayName(forAccountID: "BBBBBBBB-2222", isLocal: true) == "On My Mac")
        #expect(p.displayName(forAccountID: "CCCCCCCC-3333") == "Account (CCCCCCCC)")
    }
}

@Suite struct MailListingDeduplicatorTests {
    @Test func newestWins() {
        let out = MailListingDeduplicator.deduplicate([header("a", at: t0), header("a", at: t0.addingTimeInterval(5)),
                                                       header("b", at: t0.addingTimeInterval(2))])
        #expect(out.map(\.id) == ["a", "b"])
        #expect(out[0].receivedAt == t0.addingTimeInterval(5))
    }

    @Test func sqliteTieKeepsGreatestRowID() {
        let out = MailListingDeduplicator.deduplicate([header("a", row: 5), header("a", row: 9), header("a", row: 7)])
        #expect(out.count == 1 && out[0].sourceReference.storeRowID == 9)
    }

    @Test func jxaTieKeepsEarlierAndOrderIsStable() {
        let first = header("a"), second = header("a"), other = header("b")
        let out = MailListingDeduplicator.deduplicate([first, second, other])
        #expect(out.map(\.id) == ["a", "b"])
    }

    @Test func tiesOrderedByRowIDThenInput() {
        let out = MailListingDeduplicator.deduplicate([header("x", row: 1), header("y", row: 3), header("z", row: 2)])
        #expect(out.map(\.id) == ["y", "z", "x"])
    }

    @Test func bothStylesProduceSameUniqueIDs() {
        let sqlite = (0..<6).map { header("m\($0 % 3)", at: t0.addingTimeInterval(Double($0 % 2)), row: Int64($0)) }
        let jxa = sqlite.map { header($0.id, at: $0.receivedAt) }
        #expect(Set(MailListingDeduplicator.deduplicate(sqlite).map(\.id)) ==
                Set(MailListingDeduplicator.deduplicate(jxa).map(\.id)))
    }
}
