import Foundation

/// Prepares an email body for the model: drops quoted replies, signatures and conservatively detected
/// newsletter footers, strips tracking query parameters from URLs (Q11, Q98) and normalises invisible characters.
public struct EmailCleaner: Sendable {
    /// Longest cleaned body, in Characters, that is passed on.
    public static let maxCharacters = 24_000

    public init() {}

    /// Returns the cleaned body, truncated with a marker if it exceeds `maxCharacters`.
    public func clean(_ body: String) -> String {
        let text = Self.normaliseCharacters(body.replacingOccurrences(of: "\r\n", with: "\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var kept: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { i += 1; continue }
            if line == "-- " || line == "--" { break }
            if trimmed.hasPrefix("On ") {
                if trimmed.hasSuffix("wrote:") { break }
                // Mail clients often wrap the attribution onto a second line.
                if i + 1 < lines.count,
                   lines[i + 1].trimmingCharacters(in: .whitespaces).hasSuffix("wrote:") { break }
            }
            // Q11/Q98: URL-only lines are kept; only tracking parameters are removed.
            kept.append(Self.collapseSpaces(Self.stripTrackingParameters(line)))
            i += 1
        }

        // Collapse blank runs to one blank line.
        var collapsed: [String] = []
        for line in kept {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, collapsed.last?.isEmpty == true { continue }
            collapsed.append(blank ? "" : line)
        }
        var result = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result = Self.removingFooter(from: result)

        if result.count > Self.maxCharacters {
            return String(result.prefix(Self.maxCharacters)) + "\n[truncated]"
        }
        return result
    }

    // MARK: Character normalisation

    private static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{034F}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}",
    ]

    /// Removes invisible padding characters and maps figure/narrow no-break spaces to a plain space.
    private static func normaliseCharacters(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if invisibleScalars.contains(u) { continue }
            scalars.append(u == "\u{2007}" || u == "\u{202F}" ? " " : u)
        }
        return String(scalars)
    }

    /// Collapses runs of spaces and tabs inside a line to one space.
    private static func collapseSpaces(_ line: String) -> String {
        var out = ""
        var previousWasSpace = false
        for ch in line {
            if ch == " " || ch == "\t" {
                if !previousWasSpace { out.append(" ") }
                previousWasSpace = true
            } else {
                out.append(ch)
                previousWasSpace = false
            }
        }
        return out
    }

    // MARK: Tracking parameters (Q11, Q98)

    private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)

    /// True for query keys that only identify a campaign or click, never the content.
    private static func isTrackingKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k.hasPrefix("utm_") { return true }
        return ["fbclid", "gclid", "dclid", "msclkid", "yclid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok"].contains(k)
    }

    /// Removes recognised tracking parameters from every URL in `line`; everything else is untouched.
    static func stripTrackingParameters(_ line: String) -> String {
        guard line.contains("?"), let regex = urlRegex else { return line }
        let ns = line as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var url = ns.substring(with: m.range)
            // Trailing sentence punctuation is not part of the URL.
            var trailing = ""
            while let c = url.last, ".,;:!?".contains(c) { trailing.insert(c, at: trailing.startIndex); url.removeLast() }
            out += stripTracking(inURL: url) + trailing
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func stripTracking(inURL url: String) -> String {
        guard let q = url.firstIndex(of: "?") else { return url }
        let base = url[..<q]
        let afterQ = url[url.index(after: q)...]
        let fragmentStart = afterQ.firstIndex(of: "#")
        let query = fragmentStart.map { afterQ[..<$0] } ?? afterQ
        let fragment = fragmentStart.map { String(afterQ[$0...]) } ?? ""
        let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { param in
            let key = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return !isTrackingKey(String(key))
        }
        let rebuilt = kept.joined(separator: "&")
        return rebuilt.isEmpty ? String(base) + fragment : "\(base)?\(rebuilt)\(fragment)"
    }

    // MARK: Footer removal (Q98)

    private static let unsubscribeSignals = ["unsubscribe", "manage preferences", "email preferences", "opt out", "opt-out"]
    private static let legalSignals = ["privacy policy", "privacy statement", "\u{A9}", "copyright", "all rights reserved"]
    private static let otherFooterSignals = [
        "you are receiving this", "you received this", "this email was sent to", "view in browser",
        "no longer wish to receive",
    ]
    private static let dateRegexes: [NSRegularExpression] = [
        // Month and weekday names, full or abbreviated, as whole words ("may" is handled separately).
        #"\b(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?|mon(day)?|tue(s(day)?)?|wed(nesday)?|thu(r(s(day)?)?)?|fri(day)?|sat(urday)?|sun(day)?)\b"#,
        #"\b\d{1,2}[/.\-]\d{1,2}([/.\-]\d{2,4})?\b"#,
        #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b\d{1,2}\s?(am|pm)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    /// "May" only counts when capitalised: lowercase "may" is a common verb ("you may unsubscribe").
    private static let mayRegex = try? NSRegularExpression(pattern: #"\bMay\b"#)

    private static func containsDateOrDeadline(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if dateRegexes.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        return mayRegex?.firstMatch(in: text, range: range) != nil
    }

    /// Removes a trailing newsletter footer only when it is clearly boilerplate: it must have an unsubscribe
    /// signal and a privacy/copyright signal, contain no date or deadline, and be at most 40% of the body.
    /// Anything less certain is kept, because a missed deadline costs more than a few extra tokens.
    static func removingFooter(from text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let allSignals = unsubscribeSignals + legalSignals + otherFooterSignals
        var start = paragraphs.count
        while start > 0, allSignals.contains(where: { paragraphs[start - 1].lowercased().contains($0) }) {
            start -= 1
        }
        guard start < paragraphs.count else { return text }
        let run = paragraphs[start...]
        let runText = run.joined(separator: "\n\n")
        let lower = runText.lowercased()
        guard unsubscribeSignals.contains(where: { lower.contains($0) }),
              legalSignals.contains(where: { lower.contains($0) }),
              !run.contains(where: containsDateOrDeadline),
              Double(runText.count) <= 0.4 * Double(text.count) else { return text }
        return paragraphs[..<start].joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
