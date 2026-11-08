import Foundation

/// Prepares the text the privacy triage reads. Unlike `EmailCleaner` (which prepares text for the digest
/// model and drops quoted replies and signatures), nothing is removed because of where it appears:
/// sensitive details in a quoted reply or below a signature separator still have to reach the classifier.
public enum PrivacyAssessmentText {
    /// URLs longer than this are shortened to scheme and host; the tail is tracking, not email text.
    static let maxURLLength = 100

    private static let htmlRegex = try? NSRegularExpression(
        pattern: #"<(html|head|body|div|p|table|br|span|a|style|script)[\s/>]|<!--"#, options: .caseInsensitive)
    private static let quoteMarkerRegex = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]*)+"#, options: .anchorsMatchLines)
    private static let invisible: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{2060}", "\u{FEFF}", "\u{00AD}",
    ]

    /// One whitespace-collapsed string holding all of the message's visible text.
    public static func prepare(body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if looksLikeHTML(text) {
            // Also decodes entities, drops style/script/head blocks and comments, and breaks lines at block tags.
            text = EmlxParser.htmlToText(text)
        } else {
            text = decodeCommonEntities(text)
        }
        text.unicodeScalars.removeAll { invisible.contains($0) }
        // Keep the quoted text; only the leading ">" markers go.
        if let regex = quoteMarkerRegex {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: "")
        }
        text = shortenLongURLs(TriageInputBuilder.stripTracking(text))
        return TriageInputBuilder.collapse(text)
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        guard let regex = htmlRegex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `&amp;` last, so "&amp;lt;" becomes "&lt;" and not "<".
    private static func decodeCommonEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func shortenLongURLs(_ text: String) -> String {
        guard let regex = TriageInputBuilder.urlRegex else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range)
            if url.count > maxURLLength, let parts = URLComponents(string: url), let scheme = parts.scheme,
               let host = parts.host {
                out += "\(scheme)://\(host)/…"
            } else {
                out += url
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
