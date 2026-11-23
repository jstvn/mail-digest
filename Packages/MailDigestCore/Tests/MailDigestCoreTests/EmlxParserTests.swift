import Foundation
import Testing
@testable import MailDigestCore

/// Builds `.emlx` data with a correct byte count. All content is synthetic.
private func emlx(_ message: String, trailer: Bool = false, lineEnding: String = "\n") -> Data {
    let text = lineEnding == "\n" ? message : message.replacingOccurrences(of: "\n", with: lineEnding)
    let body = Data(text.utf8)
    var data = Data("\(body.count)\n".utf8)
    data.append(body)
    if trailer {
        data.append(Data("<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict><key>flags</key><integer>1</integer></dict></plist>\n".utf8))
    }
    return data
}

private let baseHeaders = """
From: Sam Taylor <sam@example.com>
Subject: Hello
Message-ID: <abc123@example.com>
Date: Tue, 3 Nov 2026 09:15:00 +1000
"""

private func usable(_ data: Data) throws -> ParsedEmlx {
    guard case .usable(let p) = EmlxParser().parse(data) else {
        Issue.record("expected usable result")
        throw CancellationError()
    }
    return p
}

private func reason(_ data: Data) -> EmlxUnusableReason? {
    if case .unusable(let r) = EmlxParser().parse(data) { return r }
    return nil
}

@Suite struct EmlxParserTests {
    @Test func plainText() throws {
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\n\nHi there,\nSee you Friday.\n"))
        #expect(p.body == "Hi there,\nSee you Friday.")
        #expect(p.messageID == "abc123@example.com")
        #expect(p.sender == "Sam Taylor <sam@example.com>")
        #expect(p.subject == "Hello")
        #expect(p.dateHeader == Date(timeIntervalSince1970: 1_793_661_300 - 0)) // 2026-11-02T23:15:00Z
    }

    @Test func bareAddressSender() throws {
        let p = try usable(emlx("From: sam@example.com\nSubject: x\n\nbody"))
        #expect(p.sender == "sam@example.com")
        #expect(p.messageID == nil)
    }

    @Test func htmlOnlyBecomesReadableText() throws {
        let html = """
        <html><head><title>T</title><style>p{color:red}</style></head><body>
        <script>alert(1)</script><p>Tom &amp; Jerry&nbsp;&#8211; caf&#xE9;</p>
        <p>Visit <a href="https://example.org/x">our site</a> or <a href="https://example.org">https://example.org</a>.</p>
        <div>Line<br>break</div></body></html>
        """
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/html; charset=utf-8\n\n\(html)"))
        #expect(p.body.contains("Tom & Jerry \u{2013} caf\u{E9}"))
        // Q98: a phrase label no longer repeats its href.
        #expect(p.body.contains("Visit our site or"))
        #expect(!p.body.contains("example.org/x"))
        #expect(p.body.contains("or https://example.org."))
        #expect(!p.body.contains("(https://example.org)"))
        #expect(p.body.contains("Line\nbreak"))
        for bad in ["alert", "color", "<", "T\n"] { #expect(!p.body.contains(bad)) }
    }

    // Q98 link labels
    @Test func linkLabelRules() {
        let h = EmlxParser.htmlToText
        #expect(h(#"<a href="https://x.com/t?u=1">Read more</a>"#) == "Read more")
        #expect(h(#"<a href="https://x.com/t">https://x.com</a>"#) == "https://x.com (https://x.com/t)")
        #expect(h(#"<a href="https://x.com/t">example.com</a>"#) == "example.com (https://x.com/t)")
        #expect(h(#"<a href="https://x.com/t"> </a>"#) == "https://x.com/t")
        #expect(h(#"<a href="https://x.com/t">https://x.com/t</a>"#) == "https://x.com/t")
    }

    @Test func namedEntitiesAndLeftoverTags() {
        #expect(EmlxParser.decodeEntities("a&ndash;b &lsquo;x&rsquo; &hellip; &copy; &euro;5 &zwnj;&zwj;&shy;")
            == "a\u{2013}b \u{2018}x\u{2019} \u{2026} \u{A9} \u{20AC}5 \u{200C}\u{200D}\u{AD}")
        // Entity-decoded markup is stripped for HTML-derived text only.
        #expect(EmlxParser.htmlToText("<p>a &lt;div class=\"x\"&gt;b&lt;/div&gt; c</p>") == "a b c")
        #expect(EmlxParser.htmlToText("<p>mail &lt;sam@example.com&gt; &lt;https://x.com&gt;</p>")
            == "mail <sam@example.com> <https://x.com>")
    }

    @Test func plainTextKeepsAngleTags() throws {
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\n\nWrite <b>bold</b> and <div> here\n"))
        #expect(p.body.contains("<b>bold</b>") && p.body.contains("<div>"))
    }

    @Test func foldedHeadersAndEncodedWords() throws {
        let msg = """
        From: =?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?= <jose@example.org>
        Subject: =?UTF-8?Q?Caf=C3=A9_menu?=
         =?UTF-8?Q?_and_more?= folded
        Message-ID:
         <folded@example.com>

        text
        """
        let p = try usable(emlx(msg))
        #expect(p.sender == "Jos\u{E9} Garc\u{ED}a <jose@example.org>")
        #expect(p.subject == "Caf\u{E9} menu and more folded")
        #expect(p.messageID == "folded@example.com")
    }

    @Test func base64Body() throws {
        let b64 = Data("Pay the invoice by Friday.".utf8).base64EncodedString()
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n\(b64)\n"))
        #expect(p.body == "Pay the invoice by Friday.")
        #expect(!p.body.contains(b64))
    }

    @Test func quotedPrintableSoftBreaks() throws {
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nA long li=\nne with caf=C3=A9 and =3D sign.\n"))
        #expect(p.body == "A long line with caf\u{E9} and = sign.")
    }

    @Test func nestedMultipartIgnoresAttachment() throws {
        let msg = """
        \(baseHeaders)
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        preamble text
        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain; charset=utf-8

        Plain version
        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML version</p>
        --inner--
        --outer
        Content-Type: text/plain; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"

        SECRET ATTACHMENT TEXT
        --outer
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --outer--
        """
        let p = try usable(emlx(msg))
        #expect(p.body == "Plain version")
        #expect(!p.body.contains("SECRET"))
        #expect(!p.body.contains("JVBERi"))
        #expect(!p.body.contains("--outer"))
    }

    @Test func htmlPreferredOnlyWhenNoPlain() throws {
        let msg = """
        \(baseHeaders)
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/html; charset=utf-8

        <p>Only HTML</p>
        --b--
        """
        #expect(try usable(emlx(msg)).body == "Only HTML")
    }

    @Test func htmlOutsideAlternativeIsReadAlongsidePlain() throws {
        let msg = """
        \(baseHeaders)
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: text/plain; charset=utf-8

        Plain note
        --m
        Content-Type: text/html; charset=utf-8

        <p>Separate HTML content</p>
        --m--
        """
        let p = try usable(emlx(msg))
        #expect(p.body.contains("Plain note") && p.body.contains("Separate HTML content"))
        // An alternative group still prefers plain and does not duplicate it.
        let alt = """
        \(baseHeaders)
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: multipart/alternative; boundary="a"

        --a
        Content-Type: text/plain; charset=utf-8

        Same text
        --a
        Content-Type: text/html; charset=utf-8

        <p>Same text</p>
        --a--
        --m--
        """
        #expect(try usable(emlx(alt)).body == "Same text")
    }

    @Test func partialStyleWithBodyIsUsableAndEmptyIsNot() throws {
        let withBody = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain\n\nStart of the message"))
        #expect(withBody.body == "Start of the message")
        #expect(reason(emlx("\(baseHeaders)\nContent-Type: text/plain\n\n  \n")) == .noUsableTextPart)
        #expect(reason(emlx("\(baseHeaders)\n")) == .noUsableTextPart)
    }

    @Test func lengthPrefixFailures() {
        #expect(reason(Data("abc\nFrom: a@example.com\n\nx".utf8)) == .malformedLengthPrefix)
        #expect(reason(Data("-5\nFrom: a@example.com\n\nx".utf8)) == .malformedLengthPrefix)
        #expect(reason(Data("12345".utf8)) == .malformedLengthPrefix)
        #expect(reason(Data("\nFrom: a@example.com\n\nx".utf8)) == .malformedLengthPrefix)
        #expect(reason(Data("999\nFrom: a@example.com\n\nx".utf8)) == .truncated)
    }

    @Test func prefixWithSurroundingSpacesIsAccepted() throws {
        let message = "From: a@example.com\n\nbody"
        let data = Data("  \(message.utf8.count)  \n\(message)".utf8)
        #expect(try usable(data).body == "body")
    }

    @Test func malformedHeaders() {
        #expect(reason(emlx("this is not a header\n\nbody")) == .malformedHeaders)
    }

    @Test func missingClosingBoundary() {
        let msg = "\(baseHeaders)\nContent-Type: multipart/mixed; boundary=\"b\"\n\n--b\nContent-Type: text/plain\n\nHello\n"
        #expect(reason(emlx(msg)) == .mimeStructure)
        let noBoundary = "\(baseHeaders)\nContent-Type: multipart/mixed; boundary=\"zzz\"\n\njust text\n"
        #expect(reason(emlx(noBoundary)) == .mimeStructure)
        #expect(reason(emlx("\(baseHeaders)\nContent-Type: multipart/mixed\n\nx")) == .mimeStructure)
    }

    @Test func injectedDecoderHandlesCharsetsOutsideThePortableSet() throws {
        let data = emlx("\(baseHeaders)\nContent-Type: text/plain; charset=x-made-up\n\nhello")
        let parser = EmlxParser { bytes, charset in
            charset == "x-made-up" ? String(decoding: bytes, as: UTF8.self) : nil
        }
        guard case .usable(let p) = parser.parse(data) else {
            Issue.record("expected usable result")
            return
        }
        #expect(p.body == "hello")
        // A decoder that declines still leaves the body undecodable.
        #expect(EmlxParser { _, _ in nil }.parse(data) == .unusable(.undecodableBody))
    }

    @Test func unknownCharsetAndEncodingAreUndecodable() {
        #expect(reason(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=x-made-up\n\nhello")) == .undecodableBody)
        #expect(reason(emlx("\(baseHeaders)\nContent-Type: text/plain\nContent-Transfer-Encoding: uuencode\n\nhello")) == .undecodableBody)
        #expect(reason(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n!!!notbase64!!!")) == .undecodableBody)
    }

    @Test func invalidUTF8IsUndecodable() {
        var data = Data("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\n\n".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x41])
        var out = Data("\(data.count)\n".utf8)
        out.append(data)
        #expect(reason(out) == .undecodableBody)
    }

    @Test func latin1AndWindows1252() throws {
        func make(_ charset: String, _ bytes: [UInt8]) -> Data {
            var m = Data("\(baseHeaders)\nContent-Type: text/plain; charset=\(charset)\nContent-Transfer-Encoding: 8bit\n\n".utf8)
            m.append(contentsOf: bytes)
            var out = Data("\(m.count)\n".utf8)
            out.append(m)
            return out
        }
        #expect(try usable(make("iso-8859-1", [0x63, 0x61, 0x66, 0xE9])).body == "caf\u{E9}")
        #expect(try usable(make("windows-1252", [0x93, 0x68, 0x69, 0x94])).body == "\u{201C}hi\u{201D}")
    }

    @Test func resentMessageIDIsNeverUsed() throws {
        let both = try usable(emlx("Resent-Message-ID: <resent@example.com>\nMessage-ID: <orig@example.com>\nFrom: a@example.com\n\nbody"))
        #expect(both.messageID == "orig@example.com")
        let onlyResent = try usable(emlx("Resent-Message-ID: <resent@example.com>\nFrom: a@example.com\n\nbody"))
        #expect(onlyResent.messageID == nil)
    }

    @Test func crlfLineEndingsAndTrailerIgnored() throws {
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\n\nLine one\nLine two\n", trailer: true, lineEnding: "\r\n"))
        #expect(p.body == "Line one\nLine two")
        #expect(!p.body.contains("plist"))
        #expect(p.subject == "Hello")
    }

    @Test func filterHeadersAndRawBlock() throws {
        let p = try usable(emlx("\(baseHeaders)\nList-Unsubscribe: <mailto:u@example.com>\nPrecedence: bulk\n\nbody"))
        #expect(p.filterHeaders["List-Unsubscribe"] == "<mailto:u@example.com>")
        #expect(p.filterHeaders["Precedence"] == "bulk")
        #expect(p.rawHeaderBlock.contains("Subject: Hello"))
    }

    @Test func sourceEnumCodable() throws {
        let data = try JSONEncoder().encode([EmlxSource.emlx, .partialEmlx, .jxa])
        #expect(String(decoding: data, as: UTF8.self) == #"["emlx","partialEmlx","jxa"]"#)
    }
}

@Suite struct EmlxInspectionTests {
    @Test func plainOnlyIsComplete() throws {
        let p = try usable(emlx("\(baseHeaders)\nContent-Type: text/plain; charset=utf-8\n\nHi\n"))
        #expect(p.inspection == .complete)
    }

    @Test func plainAndHtmlAlternativeIsComplete() throws {
        let p = try usable(emlx("""
        \(baseHeaders)
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        Hello
        --b1
        Content-Type: text/html; charset=utf-8

        <p>Hello</p>
        --b1--
        """))
        #expect(p.inspection == .complete)
    }

    @Test func attachmentIsUninspected() throws {
        let p = try usable(emlx("""
        \(baseHeaders)
        Content-Type: multipart/mixed; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        See attached
        --b1
        Content-Type: text/plain; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"

        secret notes
        --b1--
        """))
        #expect(p.inspection == .uninspectedParts)
        #expect(p.body == "See attached")
    }

    @Test func inlineImageIsUninspected() throws {
        let p = try usable(emlx("""
        \(baseHeaders)
        Content-Type: multipart/related; boundary="b1"

        --b1
        Content-Type: text/html; charset=utf-8

        <p>Hi <img src="cid:x"></p>
        --b1
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <x>
        Content-Disposition: inline

        iVBORw0KGgo=
        --b1--
        """))
        #expect(p.inspection == .uninspectedParts)
    }

    @Test func calendarPartIsUninspected() throws {
        let p = try usable(emlx("""
        \(baseHeaders)
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        Meeting invite
        --b1
        Content-Type: text/calendar; method=REQUEST

        BEGIN:VCALENDAR
        END:VCALENDAR
        --b1--
        """))
        #expect(p.inspection == .uninspectedParts)
    }

    @Test func undecodableSecondRepresentationIsUninspected() throws {
        let p = try usable(emlx("""
        \(baseHeaders)
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        Hello
        --b1
        Content-Type: text/html; charset=x-unknown-charset

        <p>Hello</p>
        --b1--
        """))
        #expect(p.inspection == .uninspectedParts)
    }

    // MARK: Inspection gap

    @Test func completeMessageHasNoGap() throws {
        #expect(try usable(emlx("\(baseHeaders)\nContent-Type: text/plain\n\nHi")).inspectionGap == nil)
    }

    private func multipart(_ parts: String...) -> Data {
        emlx("\(baseHeaders)\nContent-Type: multipart/mixed; boundary=\"b1\"\n\n"
             + parts.map { "--b1\n\($0)\n" }.joined() + "--b1--\n")
    }

    private static let text = "Content-Type: text/plain; charset=utf-8\n\nHello"
    private static let attachment = "Content-Type: application/pdf\nContent-Disposition: attachment; filename=\"a.pdf\"\n\nxx"
    private static let image = "Content-Type: image/png\n\nxx"
    private static let badHTML = "Content-Type: text/html; charset=x-unknown-charset\n\n<p>x</p>"

    @Test func gapPerCondition() throws {
        #expect(try usable(multipart(Self.text, Self.attachment)).inspectionGap == .attachment)
        #expect(try usable(multipart(Self.text, Self.image)).inspectionGap == .nonTextPart)
        #expect(try usable(multipart(Self.text, Self.badHTML)).inspectionGap == .undecodablePart)
        #expect(try usable(multipart(Self.text, Self.image)).inspection == .uninspectedParts)
    }

    @Test func gapPriorityIsAttachmentThenNonTextThenUndecodable() throws {
        // Order of parts must not matter.
        #expect(try usable(multipart(Self.image, Self.text, Self.attachment, Self.badHTML)).inspectionGap == .attachment)
        #expect(try usable(multipart(Self.attachment, Self.image, Self.text)).inspectionGap == .attachment)
        #expect(try usable(multipart(Self.text, Self.badHTML, Self.image)).inspectionGap == .nonTextPart)
        #expect(try usable(multipart(Self.badHTML, Self.image, Self.text)).inspectionGap == .nonTextPart)
    }
}
