import Foundation

/// iCloud Hide My Email relay handling. Relayed mail arrives From `<alias>@icloud.com` and the real sender
/// is only named in the `X-ICLOUD-HME` header (`s=`). That header is attacker-controllable, so the claimed
/// sender is trusted only when the relay alias encodes it (the alias local part starts with the sender
/// address with `.` replaced by `_` and `@` by `_at_`).
public enum RelaySender {
    /// Canonical header name kept in `EmailMessage.headers`.
    public static let headerName = "X-ICLOUD-HME"

    /// The `s=` address claimed by the header, lowercased, whether or not it is verified.
    public static func claimedSender(headers: [String: String]) -> String? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare(headerName) == .orderedSame })?.value
        else { return nil }
        for part in value.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard piece.count > 2, piece.prefix(2).lowercased() == "s=" else { continue }
            let address = piece.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  !address.contains(where: \.isWhitespace) else { return nil }
            return address
        }
        return nil
    }

    /// The original sender address, only when `from` is an `icloud.com` relay alias that encodes it.
    public static func originalSender(from: String, headers: [String: String]) -> String? {
        guard let claimed = claimedSender(headers: headers) else { return nil }
        let parts = MailFilter.address(from: from).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "icloud.com" else { return nil }
        let claimedParts = claimed.split(separator: "@")
        func flat(_ s: Substring) -> String { s.replacingOccurrences(of: ".", with: "_") }
        let prefix = "\(flat(claimedParts[0]))_at_\(flat(claimedParts[1]))_"
        return parts[0].hasPrefix(prefix) ? claimed : nil
    }

    /// `from` with a verified original address substituted, keeping any display name; otherwise `from` itself.
    public static func displaySender(from: String, headers: [String: String]) -> String {
        guard let original = originalSender(from: from, headers: headers) else { return from }
        if let open = from.lastIndex(of: "<"), from[open...].contains(">") {
            let name = from[..<open].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? original : "\(name) <\(original)>"
        }
        return original
    }
}
