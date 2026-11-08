import Foundation
import Testing
@testable import MailDigestCore

@Suite struct PrivacyAssessmentTextTests {
    private func prepare(_ s: String) -> String { PrivacyAssessmentText.prepare(body: s) }

    @Test func htmlKeepsVisibleTextOnly() {
        let html = "<html><head><title>T</title><style>.a{color:red}</style></head><body><!-- hidden note -->"
            + "<script>var x=1;</script><div>Hello&nbsp;<b>world</b></div><p>Second &amp; last</p><br>End</body></html>"
        let t = prepare(html)
        #expect(t == "Hello world Second & last End")
    }

    @Test func plainTextWithStrayAngleBracketKeepsContent() {
        #expect(prepare("if a < b and c > d then <ok> remains") == "if a < b and c > d then <ok> remains")
    }

    @Test func entitiesDecodedInPlainText() {
        #expect(prepare("Tom &amp; Jerry &lt;3 &quot;hi&quot; it&#39;s&nbsp;fine") == "Tom & Jerry <3 \"hi\" it's fine")
    }

    @Test func removesZeroWidthAndNormalisesCRLF() {
        #expect(prepare("a\u{200B}b\r\nc\u{FEFF}d") == "ab cd")
    }

    @Test func quoteMarkersGoButTextStays() {
        #expect(prepare("Reply\n> quoted one\n>> nested two\n> > spaced three") == "Reply quoted one nested two spaced three")
    }

    @Test func keepsContentAfterReplyAndSignatureMarkers() {
        let t = prepare("Hi\nOn Tue, Sam wrote:\n> secret-A\n--\nName\nsecret-B")
        #expect(t == "Hi On Tue, Sam wrote: secret-A -- Name secret-B")
    }

    @Test func trackingStrippedAndLongURLShortened() {
        let long = "https://click.example.test/track/" + String(repeating: "a1b2", count: 40) + "?x=1"
        let t = prepare("See https://news.example.test/a?id=7&utm_source=x now and \(long) end https://short.test/p")
        #expect(t.contains("https://news.example.test/a?id=7 now"))
        #expect(t.contains("and https://click.example.test/… end"))
        #expect(t.contains("https://short.test/p"))
        #expect(!t.contains("utm_") && !t.contains("a1b2"))
    }
}
