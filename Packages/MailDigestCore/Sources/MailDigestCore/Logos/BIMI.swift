import Foundation

/// The local-only BIMI step: a `BIMI-Indicator` header carries the sender's logo as a base64 SVG.
public enum BIMIIndicator {
    /// Base64 text longer than this cannot decode to `SVGSafety.maxBytes`, so it is rejected before decoding.
    static let maxEncodedCharacters = SVGSafety.maxBytes / 3 * 4 + 8

    /// The unfolded value of the first `BIMI-Indicator` header in a raw RFC 5322 header block, or nil.
    public static func headerValue(inRawHeaders raw: String) -> String? {
        // Cheap test first: almost no mail has this header, so most messages skip the unfolding work.
        guard raw.range(of: "bimi-indicator", options: .caseInsensitive) != nil else { return nil }
        for line in MailJSONDecoder.unfoldHeaderLines(raw) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("BIMI-Indicator") == .orderedSame
            else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The SVG bytes in a header value: base64 (whitespace from folding ignored), at most 32 KB decoded,
    /// a plain SVG document, and safe per `SVGSafety`. Nil otherwise.
    public static func decodeSVG(headerValue: String) -> Data? {
        let compact = headerValue.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count <= maxEncodedCharacters,
              let data = Data(base64Encoded: compact), SVGSafety.isSafe(data) else { return nil }
        return data
    }
}

/// Parsing of a `default._bimi.<domain>` TXT record.
public enum BIMIRecord {
    /// The `l=` logo URL of a `v=BIMI1; l=https://...;` record. Nil unless the record is BIMI1 and the URL
    /// passes `LogoURLPolicy`.
    public static func logoURL(fromTXT txt: String) -> URL? {
        var version: String?
        var location: String?
        for part in txt.split(separator: ";") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "v", version == nil { version = value }
            if key == "l", location == nil { location = value }
        }
        guard version?.uppercased() == "BIMI1", let location, !location.isEmpty,
              let url = URL(string: location), LogoURLPolicy.isAllowed(url) else { return nil }
        return url
    }
}

/// Which URLs a logo fetch may contact (initial requests and every redirect).
public enum LogoURLPolicy {
    /// HTTPS, a real multi-label host name (no IP literal, no `localhost`), no credentials, default port.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        // Reuses the strict DNS-name check, which also rejects IPv4/IPv6 literals and single labels.
        return !host.hasSuffix(".local") && !host.hasSuffix(".localhost") && SenderDomain.fold(host) != nil
    }
}
