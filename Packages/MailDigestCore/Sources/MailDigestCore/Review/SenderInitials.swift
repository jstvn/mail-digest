import Foundation

/// Initials for a sender avatar.
public enum SenderInitials {
    /// First letters of the first two words of the display name; for a bare address, the first two letters
    /// of the local part. Uppercase. Empty when nothing usable is left.
    public static func make(sender: String) -> String {
        let name = ReviewPresentation.senderName(sender)
        if name.contains("@") {
            let local = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return String(local.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(words.first?.prefix(2) ?? "").uppercased()
    }
}
