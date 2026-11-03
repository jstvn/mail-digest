import Foundation

/// Strips quoted replies, signatures and bare tracking URLs from an email body before it goes to the model.
public struct EmailCleaner: Sendable {
    /// Longest cleaned body, in Characters, that is passed on.
    public static let maxCharacters = 24_000

    public init() {}

    /// Returns the cleaned body, truncated with a marker if it exceeds `maxCharacters`.
    public func clean(_ body: String) -> String {
        let text = body.replacingOccurrences(of: "\r\n", with: "\n")
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
            if Self.isBareURL(trimmed) { i += 1; continue }
            kept.append(line)
            i += 1
        }

        // Collapse blank runs to one blank line.
        var collapsed: [String] = []
        for line in kept {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, collapsed.last?.isEmpty == true { continue }
            collapsed.append(blank ? "" : line)
        }
        let result = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count > Self.maxCharacters {
            return String(result.prefix(Self.maxCharacters)) + "\n[truncated]"
        }
        return result
    }

    /// True for a line holding only an http(s) URL, optionally wrapped in <> or ().
    private static func isBareURL(_ trimmed: String) -> Bool {
        var s = Substring(trimmed)
        if let f = s.first, let l = s.last, (f == "<" && l == ">") || (f == "(" && l == ")") {
            s = s.dropFirst().dropLast()
        }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return false }
        return !s.contains { $0.isWhitespace }
    }
}
