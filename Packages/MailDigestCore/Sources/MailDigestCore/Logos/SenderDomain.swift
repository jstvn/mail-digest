import Foundation

/// Reduces a sender to the one thing a logo lookup may use: its registrable domain.
/// Pure string logic with a small built-in list of multi-label public suffixes, no network.
public enum SenderDomain {
    /// Two-label public suffixes where the registrable domain has three labels (`example.co.uk`).
    /// Deliberately small: a miss only means the logo lookup uses a slightly wrong domain and fails to initials.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz", "school.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.in", "net.in", "org.in", "ac.in", "gov.in",
        "co.za", "org.za", "com.br", "com.cn", "com.hk", "com.sg", "com.mx", "com.tr", "com.tw", "co.kr", "co.il",
    ]

    /// Webmail and ISP-style domains that never get a logo lookup. Compared after folding.
    public static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "proton.me",
    ]

    /// The registrable domain of `host` (`email.uber.com` becomes `uber.com`, `mail.qut.edu.au` becomes
    /// `qut.edu.au`), lower-cased. Nil for a bare suffix, a single label or anything that isn't a plain DNS name.
    public static func fold(_ host: String) -> String? {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d })
            else { return nil }
        }
        // An all-numeric last label means an IP address, not a name.
        if let last = labels.last, last.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return nil }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels.count >= 3 ? labels.suffix(3).joined(separator: ".") : nil
        }
        return lastTwo
    }

    /// True when the (already folded) domain is on the personal-mail list.
    public static func isPersonal(_ foldedDomain: String) -> Bool {
        personalDomains.contains(foldedDomain.lowercased())
    }

    /// The folded domain for a sender string (`Name <addr@host>`, a bare address, or a bare domain as used by
    /// domain sender rules). Nil when no usable domain can be found. Never returns anything but a domain.
    public static func foldedDomain(fromSender sender: String) -> String? {
        let address = MailFilter.address(from: sender)
        let host: Substring
        if let at = address.lastIndex(of: "@") {
            host = address[address.index(after: at)...]
        } else {
            host = address[...]
        }
        return fold(String(host))
    }

    /// The domain a network logo lookup may use: folded and not a personal-mail domain.
    public static func lookupDomain(fromSender sender: String) -> String? {
        guard let domain = foldedDomain(fromSender: sender), !isPersonal(domain) else { return nil }
        return domain
    }
}
