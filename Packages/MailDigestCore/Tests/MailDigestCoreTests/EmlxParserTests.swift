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
        #expect(p.body.contains("our site (https://example.org/x)"))
        #expect(p.body.contains("or https://example.org."))
        #expect(!p.body.contains("(https://example.org)"))
        #expect(p.body.contains("Line\nbreak"))
        for bad in ["alert", "color", "<", "T\n"] { #expect(!p.body.contains(bad)) }
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
