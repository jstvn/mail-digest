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

    // Q11/Q98: replaces the old test that expected URL-only lines to be deleted.
    @Test func keepsBareURLLines() {
        let body = "See below\nhttps://track.example.com/a?b=1\n<https://x.com/y>\n(http://z.com)\nVisit https://x.com now"
        #expect(cleaner.clean(body) == body)
    }

    @Test func stripsTrackingParameters() {
        #expect(cleaner.clean("https://a.com/p?utm_source=x&id=7&UTM_medium=y&fbclid=z#frag")
            == "https://a.com/p?id=7#frag")
        #expect(cleaner.clean("https://a.com/p?utm_source=x&gclid=1&mc_eid=2") == "https://a.com/p")
        #expect(cleaner.clean("https://a.com/p?utm_source=x#top") == "https://a.com/p#top")
        #expect(cleaner.clean("https://a.com/p?ref=news&b=2&mkt_tok=q&c=3") == "https://a.com/p?ref=news&b=2&c=3")
        #expect(cleaner.clean("https://a.com/p?utmx=1&source=2") == "https://a.com/p?utmx=1&source=2")
        #expect(cleaner.clean("Go to <https://a.com/?_hsenc=1&_hsmi=2&q=x>, then (https://b.com/?msclkid=9).")
            == "Go to <https://a.com/?q=x>, then (https://b.com/).")
    }

    @Test func removesInvisibleAndCollapsesSpaces() {
        #expect(cleaner.clean("Hel\u{200B}lo\u{034F}\u{FEFF}\u{00AD} wo\u{2060}rld\u{200C}\u{200D}") == "Hello world")
        #expect(cleaner.clean("A\u{2007}\u{202F}B  \t C") == "A B C")
    }

    // MARK: footer (Q98)

    private let article = "Our new release ships next month with many improvements to sync and search for everyone."

    @Test func removesClassicNewsletterFooter() {
        let footer = "You are receiving this because you subscribed.\n\nUnsubscribe | Manage preferences\n\n© 2026 Example Inc. Privacy Policy"
        #expect(cleaner.clean("\(article)\n\n\(article)\n\n\(footer)") == "\(article)\n\n\(article)")
    }

    @Test func footerKeptWhenItHasDateOrDeadline() {
        for extra in ["Offer ends 12/03.", "Valid until Friday", "Expires 2026-11-24", "Closes at 5pm", "Call by 10:00", "See you 3.12.2026", "Sent in November"] {
            let body = "\(article)\n\n\(article)\n\n\(extra). Unsubscribe here. Privacy Policy"
            #expect(cleaner.clean(body) == body, "\(extra)")
        }
    }

    @Test func footerKeptWithoutPrivacyOrCopyrightSignal() {
        let body = "\(article)\n\n\(article)\n\nUnsubscribe from this list."
        #expect(cleaner.clean(body) == body)
    }

    @Test func footerKeptWhenOver40Percent() {
        let body = "Short.\n\nUnsubscribe here. © Example. Privacy Policy and all the other legal text."
        #expect(cleaner.clean(body) == body)
    }

    @Test func footerKeptWhenNonFooterParagraphIsLast() {
        let body = "\(article)\n\n\(article)\n\nUnsubscribe. Privacy Policy.\n\nP.S. Bring the signed form."
        #expect(cleaner.clean(body) == body)
    }

    @Test func copyrightYearAloneDoesNotBlockRemoval() {
        let body = "\(article)\n\n\(article)\n\nUnsubscribe | © 2026 Example Inc."
        #expect(cleaner.clean(body) == "\(article)\n\n\(article)")
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
