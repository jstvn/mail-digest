import Foundation
import MailDigestCore

/// Decodes charsets that `String.Encoding` lacks on other platforms (gbk, gb2312, gb18030,
/// windows-1256 and similar) through CoreFoundation's IANA name table. Used by `EmlxParser`.
enum CoreFoundationCharsetDecoder {
    /// Returns nil when the charset is unknown or the bytes do not decode.
    static func decode(_ bytes: Data, charset: String) -> String? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        guard !name.isEmpty else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return String(data: bytes, encoding: String.Encoding(rawValue: ns))
    }

    /// A parser wired to this decoder.
    static func makeParser() -> EmlxParser {
        EmlxParser(charsetDecoder: { decode($0, charset: $1) })
    }
}
