import Foundation

/// Decides whether untrusted SVG bytes are safe to hand to the system renderer. The SVG comes from a sender
/// (email header or a website), so anything that could run code or reach outside the document is rejected.
/// This is deliberately a conservative, string-level screen: a false rejection only means initials are shown.
public enum SVGSafety {
    /// The BIMI size limit for a logo, in bytes.
    public static let maxBytes = 32 * 1024

    private static let forbiddenFragments = [
        "<script", "<foreignobject", "<image", "<iframe", "<embed", "<object", "<animate", "<set", "<audio", "<video",
        "<!doctype", "<!entity", "<?xml-stylesheet", "@import", "xml:base", "javascript:", "&#", "\\",
    ]
    private static let eventHandler = try! NSRegularExpression(pattern: #"[\s"'/]on[a-z]+\s*="#)
    private static let hrefValue = try! NSRegularExpression(pattern: #"href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    private static let urlFunction = try! NSRegularExpression(pattern: #"url\(\s*([^)]*)\)"#)

    /// True when `data` is a plain SVG document within the size cap with no active or external content.
    public static func isSafe(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        guard isSVGDocument(lower) else { return false }
        if forbiddenFragments.contains(where: lower.contains) { return false }
        let whole = NSRange(lower.startIndex..., in: lower)
        if eventHandler.firstMatch(in: lower, range: whole) != nil { return false }
        // Only same-document references (`#id`) are allowed; the xmlns declarations are not references.
        for match in hrefValue.matches(in: lower, range: whole) {
            let value = (1...3).lazy.compactMap { i -> String? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : Range(r, in: lower).map { String(lower[$0]) }
            }.first ?? ""
            if !value.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return false }
        }
        for match in urlFunction.matches(in: lower, range: whole) {
            guard let r = Range(match.range(at: 1), in: lower) else { return false }
            let value = lower[r].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            if !value.hasPrefix("#") { return false }
        }
        return true
    }

    /// True when the text, after an optional BOM, XML declaration and comments, starts at an `<svg` element.
    private static func isSVGDocument(_ lower: String) -> Bool {
        var rest = Substring(lower.drop(while: { $0 == "\u{FEFF}" || $0.isWhitespace }))
        while true {
            if rest.hasPrefix("<?xml"), let end = rest.range(of: "?>") {
                rest = rest[end.upperBound...].drop(while: \.isWhitespace)
            } else if rest.hasPrefix("<!--"), let end = rest.range(of: "-->") {
                rest = rest[end.upperBound...].drop(while: \.isWhitespace)
            } else {
                break
            }
        }
        guard rest.hasPrefix("<svg") else { return false }
        let next = rest.dropFirst(4).first
        return next == nil || next!.isWhitespace || next == ">" || next == "/"
    }
}
