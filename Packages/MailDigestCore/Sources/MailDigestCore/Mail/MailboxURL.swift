import Foundation

/// A parsed Mail mailbox URL such as `imap://ACCOUNT-UUID/Parent/Child`.
public struct MailboxURL: Sendable, Equatable, Hashable {
    public let scheme: String
    public let accountID: String
    /// Percent-decoded path components; `%2F` stays inside a single component.
    public let pathComponents: [String]

    /// Components joined by "/", for display.
    public var displayPath: String { pathComponents.joined(separator: "/") }
    /// True for "On My Mac" mailboxes.
    public var isLocal: Bool { scheme == "local" }

    /// Returns nil when there is no `://`, no account, or no path.
    public init?(_ string: String) {
        guard let sep = string.range(of: "://") else { return nil }
        let scheme = String(string[..<sep.lowerBound])
        let rest = string[sep.upperBound...]
        guard !scheme.isEmpty, let slash = rest.firstIndex(of: "/") else { return nil }
        let account = String(rest[..<slash])
        guard !account.isEmpty else { return nil }
        // Split on the encoded path first so an encoded "/" inside a name is not a separator.
        let encoded = rest[rest.index(after: slash)...].split(separator: "/", omittingEmptySubsequences: false)
        var components: [String] = []
        for part in encoded {
            guard let decoded = String(part).removingPercentEncoding else { return nil }
            components.append(decoded)
        }
        // A single trailing slash is tolerated; any other empty component is malformed.
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty, !components.contains("") else { return nil }
        self.scheme = scheme
        self.accountID = account
        self.pathComponents = components
    }
}

/// Pure path computation for Mail's on-disk store layout. Performs no I/O.
public enum MailStoreLayout {
    /// Hash directories for a message row ID: the decimal digits of `rowID / 1000`, least significant first.
    public static func hashDirectoryComponents(rowID: Int64) -> [String] {
        guard rowID >= 0 else { return [] }
        var n = rowID / 1000
        var out: [String] = []
        while n > 0 {
            out.append(String(n % 10))
            n /= 10
        }
        return out
    }

    /// Nested directory names under the store root: the account ID, then each path component with a
    /// `.mbox` suffix (`["ACC", "Parent.mbox", "Child.mbox"]`); nil if any part could escape the store.
    public static func mailboxDirectoryComponents(for url: MailboxURL) -> [String]? {
        let parts = [url.accountID] + url.pathComponents
        guard parts.allSatisfy(isSafe) else { return nil }
        return [url.accountID] + url.pathComponents.map { $0 + ".mbox" }
    }

    /// File names for a message: the full file and the partial (not fully downloaded) variant.
    public static func messageFileNames(rowID: Int64) -> (full: String, partial: String) {
        ("\(rowID).emlx", "\(rowID).partial.emlx")
    }

    private static func isSafe(_ component: String) -> Bool {
        !(component.isEmpty || component == "." || component == ".."
            || component.contains("/") || component.unicodeScalars.contains("\0"))
    }
}
