import Foundation

/// Canonical form of an RFC 5322 Message-ID, shared by every mail source so identity matches.
public enum MessageID {
    /// Returns the id without angle brackets, or nil when the value is empty or has no usable id
    /// (for example contains whitespace inside the id).
    public static func canonical(_ raw: String) -> String? {
        // Unfold: header folding inserts CR/LF + whitespace.
        let unfolded = raw.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unfolded.isEmpty else { return nil }

        var value = unfolded
        if let open = value.firstIndex(of: "<"),
           let close = value[value.index(after: open)...].firstIndex(of: ">") {
            // Take the first <...> token; ignore comments or extra ids around it.
            value = String(value[value.index(after: open)..<close])
        } else {
            if value.hasPrefix("<") { value.removeFirst() }
            if value.hasSuffix(">") { value.removeLast() }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return value
    }
}
