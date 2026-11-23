import Foundation

/// Where a message body came from; the app records this as body provenance.
public enum EmlxSource: String, Codable, Sendable, Equatable {
    case emlx, partialEmlx, jxa
}

/// Why an `.emlx` file could not give a trustworthy body. Carries no message content (it is logged).
public enum EmlxUnusableReason: String, Codable, Sendable, Equatable, Error {
    /// The leading byte-count line is missing or not a decimal number.
    case malformedLengthPrefix
    /// Fewer bytes are present than the length prefix declares.
    case truncated
    /// The RFC 5322 header block is missing or invalid.
    case malformedHeaders
    /// A declared multipart boundary is missing, never found, or never closed.
    case mimeStructure
    /// The selected text part has an unknown transfer encoding or charset, or does not decode.
    case undecodableBody
    /// There is no text part, or the body is empty after cleanup.
    case noUsableTextPart
}

/// A successfully parsed message.
public struct ParsedEmlx: Sendable, Equatable {
    /// Canonical `Message-ID` header (never `Resent-Message-ID`); nil when absent or unusable.
    public var messageID: String?
    /// "Name <addr>", or the bare address when there is no display name.
    public var sender: String
    public var subject: String
    public var dateHeader: Date?
    /// Readable text only: no MIME boundaries, base64, attachments or plist trailer.
    public var body: String
    public var rawHeaderBlock: String
    /// `List-Unsubscribe`, `Precedence`, `Auto-Submitted`, `X-ICLOUD-HME`.
    public var filterHeaders: [String: String]
    /// `.complete` only when every MIME leaf is text/plain or text/html and decoded (Q66).
    public var inspection: ContentInspection
    /// Why `inspection` is not `.complete`. When several apply the priority is
    /// attachment, then non-text part, then undecodable part. Nil when complete.
    public var inspectionGap: InspectionGap?
    /// True when some MIME leaf is a placeholder for content Mail has not downloaded: it carries an
    /// `X-Apple-Content-Length` header, or it is a text part with an empty body. Only meaningful for
    /// `.partial.emlx` files (see `PartialEmlxPolicy`).
    public var hasPlaceholderPart: Bool

    public init(messageID: String?, sender: String, subject: String, dateHeader: Date?, body: String,
                rawHeaderBlock: String, filterHeaders: [String: String], inspection: ContentInspection = .unknown,
                inspectionGap: InspectionGap? = nil, hasPlaceholderPart: Bool = false) {
        self.hasPlaceholderPart = hasPlaceholderPart
        self.inspectionGap = inspectionGap
        self.inspection = inspection
        self.messageID = messageID
        self.sender = sender
        self.subject = subject
        self.dateHeader = dateHeader
        self.body = body
        self.rawHeaderBlock = rawHeaderBlock
        self.filterHeaders = filterHeaders
    }
}

public enum EmlxParseResult: Sendable, Equatable {
    case usable(ParsedEmlx)
    case unusable(EmlxUnusableReason)
}

/// Parses Apple Mail `.emlx` data (byte count, RFC 5322 message, optional plist trailer).
/// Partial files get no special treatment: the same usability rules apply (Q31).
public struct EmlxParser: Sendable {
    /// Decodes bytes in a charset outside the portable built-in set; returns nil when it can't.
    public typealias CharsetDecoder = @Sendable (_ bytes: Data, _ charset: String) -> String?

    /// Fallback for charsets that `String.Encoding` doesn't cover on every platform (for example
    /// GBK or windows-1256). The app supplies a CoreFoundation-backed decoder; Core stays portable.
    private let charsetDecoder: CharsetDecoder?

    public init(charsetDecoder: CharsetDecoder? = nil) {
        self.charsetDecoder = charsetDecoder
    }

    public func parse(_ data: Data) -> EmlxParseResult {
        let content: [UInt8]
        switch Self.messageBytes(from: data) {
        case .success(let bytes): content = bytes
        case .failure(let reason): return .unusable(reason)
        }
        let (headerBytes, bodyBytes) = Self.splitHeaderBody(content)
        guard let headers = Self.parseHeaders(headerBytes) else { return .unusable(.malformedHeaders) }
        let entity = Entity(headers: headers.fields, body: bodyBytes)

        let text: String
        let inspection: ContentInspection
        let gap: InspectionGap?
        let placeholder: Bool
        do {
            (text, inspection, gap, placeholder) = try Self.extractBody(entity, charsetDecoder: charsetDecoder)
        } catch let reason as EmlxUnusableReason {
            return .unusable(reason)
        } catch {
            return .unusable(.undecodableBody)
        }

        let rawBlock = headers.raw
        let messageID = entity.header("message-id").flatMap(MessageID.canonical)
        let from = entity.header("from").map(Self.decodeAddress) ?? ""
        let subject = entity.header("subject").map(Self.decodeEncodedWords) ?? ""
        return .usable(ParsedEmlx(
            messageID: messageID, sender: from, subject: subject,
            dateHeader: entity.header("date").flatMap(Self.parseRFC5322Date), body: text,
            rawHeaderBlock: rawBlock, filterHeaders: MailJSONDecoder.filterHeaders(rawBlock),
            inspection: inspection, inspectionGap: gap, hasPlaceholderPart: placeholder))
    }

    // MARK: Length prefix

    private static func messageBytes(from data: Data) -> Result<[UInt8], EmlxUnusableReason> {
        let bytes = Array(data)
        guard let nl = bytes.prefix(32).firstIndex(of: 0x0A) else { return .failure(.malformedLengthPrefix) }
        let digits = bytes[..<nl].filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let count = Int(String(decoding: digits, as: UTF8.self)) else {
            return .failure(.malformedLengthPrefix)
        }
        let start = nl + 1
        guard bytes.count - start >= count else { return .failure(.truncated) }
        return .success(Array(bytes[start..<(start + count)]))
    }

    // MARK: Entities and headers

    private struct Entity {
        var headers: [(name: String, value: String)]
        var body: [UInt8]

        func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
    }

    /// Splits at the first empty line (CRLF or LF). Without one, everything is header.
    private static func splitHeaderBody(_ bytes: [UInt8]) -> (header: [UInt8], body: [UInt8]) {
        var i = 0
        while i < bytes.count {
            let end = bytes[i...].firstIndex(of: 0x0A) ?? bytes.count
            let lineEnd = (end > i && bytes[end - 1] == 0x0D) ? end - 1 : end
            if lineEnd == i { return (Array(bytes[..<i]), end < bytes.count ? Array(bytes[(end + 1)...]) : []) }
            i = end + 1
        }
        return (bytes, [])
    }

    private static func string(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func parseHeaders(_ bytes: [UInt8]) -> (fields: [(name: String, value: String)], raw: String)? {
        let raw = string(bytes).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var fields: [(name: String, value: String)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == " " || line.first == "\t" {
                guard !fields.isEmpty else { return nil }
                fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            fields.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return fields.isEmpty ? nil : (fields, raw)
    }

    /// Splits `type/subtype; k=v; k="v"` into lowercase type and parameters.
    private static func parseParameterised(_ value: String) -> (main: String, params: [String: String]) {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle(); current.append(ch) }
            else if ch == ";" && !quoted { parts.append(current); current = "" }
            else { current.append(ch) }
        }
        parts.append(current)
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let key = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            if params[key] == nil { params[key] = v }
        }
        return (parts[0].trimmingCharacters(in: .whitespaces).lowercased(), params)
    }

    // MARK: MIME

    private static let maxDepth = 12

    private static func extractBody(_ root: Entity, charsetDecoder: CharsetDecoder?) throws -> (String, ContentInspection, InspectionGap?, Bool) {
        var plain: [Entity] = []
        var html: [Entity] = []
        var looseHTML: [Entity] = []
        var gap: InspectionGap?
        var placeholder = false
        try collect(root, depth: 0, underAlternative: false, plain: &plain, html: &html, looseHTML: &looseHTML,
                    gap: &gap, placeholder: &placeholder)

        var decodeFailed = false
        var result: String?
        // An HTML part outside a multipart/alternative group is separate content, not another rendering of the
        // plain text, so it is read alongside the plain parts instead of being ignored.
        // `optional` parts only add text; failing to decode one flags the message but keeps the plain parts.
        let groups: [[(entity: Entity, isHTML: Bool, optional: Bool)]] = [
            plain.map { ($0, false, false) } + (plain.isEmpty ? [] : looseHTML.map { ($0, true, true) }),
            (html + (plain.isEmpty ? looseHTML : [])).map { ($0, true, false) },
        ]
        for candidates in groups where !candidates.isEmpty {
            var pieces: [String] = []
            var groupFailed = false
            for (e, isHTML, optional) in candidates {
                do {
                    let text = try decodeText(e, charsetDecoder: charsetDecoder)
                    let cleaned = isHTML ? htmlToText(text) : normalise(text)
                    if !cleaned.isEmpty { pieces.append(cleaned) }
                } catch {
                    // An untrustworthy part: try the other representation, else report undecodable.
                    decodeFailed = true
                    if !optional { groupFailed = true; break }
                }
            }
            if groupFailed { continue }
            // Keep looping so every part is decode-checked for the inspection verdict.
            if result == nil, !pieces.isEmpty { result = pieces.joined(separator: "\n\n") }
        }
        if let result {
            // Priority: attachment > nonTextPart > undecodablePart (deterministic).
            if gap == nil, decodeFailed { gap = .undecodablePart }
            return (result, gap == nil ? .complete : .uninspectedParts, gap, placeholder)
        }
        throw decodeFailed ? EmlxUnusableReason.undecodableBody : EmlxUnusableReason.noUsableTextPart
    }

    private static func collect(_ e: Entity, depth: Int, underAlternative: Bool, plain: inout [Entity],
                                html: inout [Entity], looseHTML: inout [Entity],
                                gap: inout InspectionGap?, placeholder: inout Bool) throws {
        guard depth <= maxDepth else { throw EmlxUnusableReason.mimeStructure }
        let ct = parseParameterised(e.header("content-type") ?? "text/plain")
        if !ct.main.hasPrefix("multipart/") {
            if e.header("x-apple-content-length") != nil { placeholder = true }
            if ct.main.hasPrefix("text/"), e.body.allSatisfy({ $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) {
                placeholder = true
            }
        }
        let disposition = parseParameterised(e.header("content-disposition") ?? "").main
        if disposition == "attachment" { gap = .attachment; return }

        if ct.main.hasPrefix("multipart/") {
            guard let boundary = ct.params["boundary"], !boundary.isEmpty else { throw EmlxUnusableReason.mimeStructure }
            let alternative = underAlternative || ct.main == "multipart/alternative"
            for part in try splitMultipart(e.body, boundary: boundary) {
                let (h, b) = splitHeaderBody(part)
                // A part may have no headers at all (defaults to text/plain); only a bad block is an error.
                let fields = h.isEmpty ? [] : (parseHeaders(h)?.fields ?? [])
                if !h.isEmpty && fields.isEmpty { throw EmlxUnusableReason.mimeStructure }
                try collect(Entity(headers: fields, body: b), depth: depth + 1, underAlternative: alternative,
                            plain: &plain, html: &html, looseHTML: &looseHTML, gap: &gap,
                            placeholder: &placeholder)
            }
        } else if ct.main == "text/plain" {
            plain.append(e)
        } else if ct.main == "text/html" {
            // Inside a multipart, outside any alternative group: separate content. A lone HTML message stays `html`.
            if depth > 0, !underAlternative { looseHTML.append(e) } else { html.append(e) }
        } else {
            // Images, calendar, PDF, S/MIME, message/*, unknown: never read, so never "complete".
            if gap != .attachment { gap = .nonTextPart }
        }
    }

    private static func splitMultipart(_ bytes: [UInt8], boundary: String) throws -> [[UInt8]] {
        let marker = Array(("--" + boundary).utf8)
        var parts: [[UInt8]] = []
        var partStart: Int?
        var sawFirst = false
        var closed = false
        var i = 0
        while i < bytes.count {
            let nl = bytes[i...].firstIndex(of: 0x0A) ?? bytes.count
            let contentEnd = (nl > i && bytes[nl - 1] == 0x0D) ? nl - 1 : nl
            let line = bytes[i..<contentEnd]
            if line.starts(with: marker) {
                let rest = line.dropFirst(marker.count).filter { $0 != 0x20 && $0 != 0x09 }
                let isClose = rest == [0x2D, 0x2D]
                if rest.isEmpty || isClose {
                    if let ps = partStart {
                        // The line break before a delimiter belongs to the delimiter.
                        var end = i
                        if end > ps, bytes[end - 1] == 0x0A { end -= 1 }
                        if end > ps, bytes[end - 1] == 0x0D { end -= 1 }
                        parts.append(Array(bytes[ps..<max(ps, end)]))
                    }
                    sawFirst = true
                    if isClose { closed = true; break }
                    partStart = min(nl + 1, bytes.count)
                }
            }
            i = nl + 1
        }
        guard sawFirst, closed else { throw EmlxUnusableReason.mimeStructure }
        return parts
    }

    // MARK: Body decoding

    private struct Undecodable: Error {}

    private static func decodeText(_ e: Entity, charsetDecoder: CharsetDecoder?) throws -> String {
        let cte = (e.header("content-transfer-encoding") ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
        let raw: [UInt8]
        switch cte {
        case "7bit", "8bit", "binary": raw = e.body
        case "quoted-printable": raw = decodeQuotedPrintable(e.body)
        case "base64":
            let compact = e.body.filter { $0 != 0x0A && $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }
            guard let d = Data(base64Encoded: Data(compact)) else { throw Undecodable() }
            raw = Array(d)
        default: throw Undecodable()
        }
        let charset = parseParameterised(e.header("content-type") ?? "text/plain").params["charset"] ?? "us-ascii"
        if let encoding = stringEncoding(forCharset: charset) {
            guard let s = String(data: Data(raw), encoding: encoding) else { throw Undecodable() }
            return s
        }
        guard let s = charsetDecoder?(Data(raw), charset.trimmingCharacters(in: .whitespaces)) else { throw Undecodable() }
        return s
    }

    /// Only charsets available as `String.Encoding` on both Apple platforms and Linux; others are untrustworthy.
    static func stringEncoding(forCharset name: String) -> String.Encoding? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "iso8859-1", "l1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "utf-16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "iso-2022-jp": return .iso2022JP
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "euc-jp": return .japaneseEUC
        default: return nil
        }
    }

    private static func decodeQuotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == 0x3D else { out.append(b); i += 1; continue }
            if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }                       // soft break LF
            if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue } // soft break CRLF
            if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                out.append(h << 4 | l); i += 3; continue
            }
            out.append(b); i += 1
        }
        return out
    }

    private static func normalise(_ text: String) -> String {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return lf.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTML to text

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "\u{A9}",
        "reg": "\u{AE}", "trade": "\u{2122}", "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bull": "\u{2022}",
        "middot": "\u{B7}", "euro": "\u{20AC}", "pound": "\u{A3}", "yen": "\u{A5}", "cent": "\u{A2}",
        "laquo": "\u{AB}", "raquo": "\u{BB}", "times": "\u{D7}", "deg": "\u{B0}", "eacute": "\u{E9}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{AD}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "&", let semi = scalars[i...].prefix(12).firstIndex(of: ";") else {
                out.append(scalars[i]); i += 1; continue
            }
            let name = String(String.UnicodeScalarView(scalars[(i + 1)..<semi]))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = namedEntities[name]
            }
            if let r = replacement { out.append(contentsOf: r.unicodeScalars); i = semi + 1 }
            else { out.append(scalars[i]); i += 1 }
        }
        return String(out)
    }

    private static let doubleBreakTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "ul", "ol"]
    private static let singleBreakTags: Set<String> = ["br", "div", "li", "tr", "hr", "section", "article", "header", "footer", "pre"]
    private static let skippedTags: Set<String> = ["script", "style", "head"]

    static func htmlToText(_ html: String) -> String {
        let s = Array(html.unicodeScalars)
        var out = ""
        var anchorHref: String?
        var anchorText = ""
        var i = 0

        func append(_ text: String) {
            if anchorHref != nil { anchorText += text } else { out += text }
        }
        func hasPrefixIgnoringCase(_ p: String, at idx: Int) -> Bool {
            let pu = Array(p.unicodeScalars)
            guard idx + pu.count <= s.count else { return false }
            for k in 0..<pu.count where Character(s[idx + k]).lowercased() != Character(pu[k]).lowercased() { return false }
            return true
        }
        func finishAnchor() {
            guard let href = anchorHref else { return }
            anchorHref = nil
            let text = collapse(anchorText)
            anchorText = ""
            let skip = href.isEmpty || href.hasPrefix("#") || href.lowercased().hasPrefix("javascript:")
            if skip || text == href { out += text.isEmpty ? href : text }
            else if text.isEmpty { out += href }
            // Q98: a phrase label stands alone; the href is long tracking noise for the model.
            else if !looksLikeURLOrDomain(text) { out += text }
            else { out += "\(text) (\(href))" }
        }

        while i < s.count {
            guard s[i] == "<" else {
                var j = i
                while j < s.count, s[j] != "<" { j += 1 }
                append(decodeEntities(String(String.UnicodeScalarView(s[i..<j]))))
                i = j
                continue
            }
            if hasPrefixIgnoringCase("<!--", at: i) {
                var j = i + 4
                while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                i = j + 3
                continue
            }
            // Find the end of the tag, ignoring ">" inside quoted attribute values.
            var j = i + 1
            var quote: Unicode.Scalar?
            while j < s.count {
                if let q = quote { if s[j] == q { quote = nil } }
                else if s[j] == "\"" || s[j] == "'" { quote = s[j] }
                else if s[j] == ">" { break }
                j += 1
            }
            guard j < s.count else { break }   // unterminated tag: drop the rest
            let tagText = String(String.UnicodeScalarView(s[(i + 1)..<j]))
            i = j + 1

            let closing = tagText.hasPrefix("/")
            let body = closing ? String(tagText.dropFirst()) : tagText
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()

            if !closing, skippedTags.contains(name) {
                // Drop everything up to the matching close tag.
                var k = i
                while k < s.count, !hasPrefixIgnoringCase("</\(name)", at: k) { k += 1 }
                while k < s.count, s[k] != ">" { k += 1 }
                i = min(k + 1, s.count)
                continue
            }
            if name == "a" {
                if closing { finishAnchor() }
                else { finishAnchor(); anchorHref = attribute("href", in: body) ?? ""; anchorText = "" }
            } else if doubleBreakTags.contains(name) {
                append("\n\n")
            } else if singleBreakTags.contains(name) {
                append("\n")
            }
        }
        finishAnchor()
        return tidy(stripLeftoverTags(out))
    }

    private static let bareDomainRegex = try? NSRegularExpression(
        pattern: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}([/?#].*)?$"#)
    private static let leftoverTagRegex = try? NSRegularExpression(
        pattern: #"</?[A-Za-z][A-Za-z0-9]*(\s[^<>]*)?/?>"#)

    /// True when a link label is itself a URL or bare domain, so the href adds nothing but is worth keeping.
    private static func looksLikeURLOrDomain(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
            || lower.hasPrefix("mailto:") { return true }
        guard let regex = bareDomainRegex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Entity-decoded markup such as "&lt;div&gt;" would otherwise survive as tags. "<https://x>" and
    /// "<name@host>" do not match because a tag name must be followed by whitespace, "/" or ">".
    private static func stripLeftoverTags(_ text: String) -> String {
        guard text.contains("<"), let regex = leftoverTagRegex else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        let rest = tag[r.upperBound...]
        guard let first = rest.first else { return nil }
        if first == "\"" || first == "'" {
            let inner = rest.dropFirst()
            guard let end = inner.firstIndex(of: first) else { return nil }
            return decodeEntities(String(inner[..<end]))
        }
        return decodeEntities(String(rest.prefix { !$0.isWhitespace && $0 != ">" }))
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Collapses spaces within lines and limits runs of blank lines to one.
    private static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var blank = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let c = collapse(String(line))
            if c.isEmpty {
                if !blank && !lines.isEmpty { lines.append("") }
                blank = true
            } else {
                lines.append(c)
                blank = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Header values

    /// Decodes RFC 2047 encoded words (B and Q); whitespace between adjacent encoded words is dropped.
    static func decodeEncodedWords(_ value: String) -> String {
        var out = ""
        var rest = Substring(value)
        var lastWasEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            if let (decoded, remainder) = decodeWord(rest[start.lowerBound...]) {
                if !(lastWasEncoded && before.allSatisfy({ $0.isWhitespace })) { out += before }
                out += decoded
                rest = remainder
                lastWasEncoded = true
            } else {
                out += rest[..<start.upperBound]
                rest = rest[start.upperBound...]
                lastWasEncoded = false
            }
        }
        out += rest
        return out
    }

    private static func decodeWord(_ s: Substring) -> (String, Substring)? {
        // =?charset?enc?text?=
        let body = s.dropFirst(2)
        let fields = body.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let end = fields[2].range(of: "?=") else { return nil }
        let charset = fields[0].split(separator: "*").first.map(String.init) ?? ""
        let text = fields[2][..<end.lowerBound]
        guard !text.contains(" "), let encoding = stringEncoding(forCharset: charset) else { return nil }
        let bytes: [UInt8]
        switch fields[1].lowercased() {
        case "b":
            guard let d = Data(base64Encoded: String(text)) else { return nil }
            bytes = Array(d)
        case "q":
            bytes = decodeQuotedPrintable(Array(text.utf8.map { $0 == 0x5F ? 0x20 : $0 }))
        default: return nil
        }
        guard let decoded = String(data: Data(bytes), encoding: encoding) else { return nil }
        return (decoded, fields[2][end.upperBound...])
    }

    private static func decodeAddress(_ value: String) -> String {
        guard let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") else {
            return decodeEncodedWords(value).trimmingCharacters(in: .whitespaces)
        }
        let addr = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        var name = decodeEncodedWords(String(value[..<open])).trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return name.isEmpty ? addr : "\(name) <\(addr)>"
    }

    /// Parses an RFC 5322 date such as `Tue, 3 Nov 2026 09:15:00 +1000 (AEST)`.
    static func parseRFC5322Date(_ value: String) -> Date? {
        var v = value
        while let open = v.firstIndex(of: "("), let close = v[open...].firstIndex(of: ")") {
            v.removeSubrange(open...close)
        }
        var tokens = v.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let first = tokens.first, first.hasSuffix(",") { tokens.removeFirst() }
        guard tokens.count >= 4, let day = Int(tokens[0]) else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let month = months.firstIndex(of: tokens[1].prefix(3).lowercased()), var year = Int(tokens[2]) else { return nil }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }
        let hms = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard hms.count >= 2 else { return nil }

        var offset = 0
        if tokens.count >= 5 {
            let z = tokens[4]
            if let sign = z.first, sign == "+" || sign == "-", z.count == 5, let n = Int(z.dropFirst()) {
                offset = (n / 100 * 3600 + n % 100 * 60) * (sign == "-" ? -1 : 1)
            } else {
                let zones = ["EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7]
                offset = (zones[z.uppercased()] ?? 0) * 3600
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = DateComponents(year: year, month: month + 1, day: day, hour: hms[0], minute: hms[1],
                                   second: hms.count > 2 ? hms[2] : 0)
        return cal.date(from: comps)?.addingTimeInterval(TimeInterval(-offset))
    }
}
