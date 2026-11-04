import Foundation
import Testing
@testable import MailDigestCore

@Suite struct EmailCleanerTests {
    private let cleaner = EmailCleaner()

    @Test func removesQuotedLinesAndCRLF() {
        #expect(cleaner.clean("Hi\r\n> old\r\n  > older\r\nBye") == "Hi\nBye")
    }

    @Test func cutsAttribution() {
        #expect(cleaner.clean("Reply\n\nOn Mon, 2 Nov 2026, Sam wrote:\nold stuff") == "Reply")
    }

    @Test func cutsTwoLineAttribution() {
        let body = "Reply\nOn Mon, 2 Nov 2026 at 10:00, Sam Taylor <sam@example.com>\nwrote:\nold"
        #expect(cleaner.clean(body) == "Reply")
    }

    @Test func cutsSignature() {
        #expect(cleaner.clean("Body\n-- \nSam\nPhone") == "Body")
        #expect(cleaner.clean("Body\n--\nSam") == "Body")
        #expect(cleaner.clean("Body\n--- not a sig\nmore") == "Body\n--- not a sig\nmore")
    }

    @Test func removesBareURLLinesKeepsInline() {
        let body = "See below\nhttps://track.example.com/a?b=1\n<https://x.com/y>\n(http://z.com)\nVisit https://x.com now"
        #expect(cleaner.clean(body) == "See below\nVisit https://x.com now")
    }

    @Test func collapsesBlankLines() {
        #expect(cleaner.clean("\n\nA\n \n\t\n\nB\n\n") == "A\n\nB")
    }

    @Test func truncation() {
        let exact = String(repeating: "a", count: 24_000)
        #expect(cleaner.clean(exact) == exact)
        #expect(cleaner.clean(exact + "b") == exact + "\n[truncated]")
    }

    @Test func quoteFixture() throws {
        let email = try #require(try FixtureLoader.loadEmails().first { $0.id.hasPrefix("quote-17") })
        let cleaned = cleaner.clean(email.body)
        #expect(cleaned == "Sounds good, let's meet Tuesday at 3pm.")
        #expect(!cleaned.contains(">"))
        #expect(!cleaned.contains("Sent from my phone"))
    }
}
