import Foundation

/// Everything the pre-filter looks at. `body` is the full, uncleaned text.
public struct PrivacyInput: Sendable, Equatable {
    public var sender: String
    public var subject: String
    public var body: String
    public var headers: [String: String]
    public var inspection: ContentInspection

    public init(sender: String, subject: String, body: String, headers: [String: String] = [:],
                inspection: ContentInspection = .unknown) {
        self.sender = sender
        self.subject = subject
        self.body = body
        self.headers = headers
        self.inspection = inspection
    }
}

public enum PreFilterVerdict: Sendable, Equatable {
    /// Stays local; carries the stable rule id.
    case `private`(String)
    /// Trusted newsletter sender; eligible for the cloud.
    case `public`(String)
    case needsTriage
}

/// Deterministic, pure rules (Q61, Q66). Private always wins; no match is not evidence of safety.
/// Matched text is never returned, stored or logged: only the rule id.
public struct PrivacyPreFilter: Sendable {
    public init() {}

    // MARK: Rule tables (edit here to maintain)

    /// Sensitive sender domains, matched on host label boundaries (`host == d` or `host` ends with `.d`).
    static let sensitiveDomains: [(suffix: String, ruleID: String)] = [
        ("gov", "domain.gov"), ("gov.au", "domain.gov.au"), ("gov.uk", "domain.gov.uk"), ("mil", "domain.mil"),
        // Banks and payment providers
        ("commbank.com.au", "domain.bank"), ("anz.com", "domain.bank"), ("westpac.com.au", "domain.bank"),
        ("nab.com.au", "domain.bank"), ("ing.com.au", "domain.bank"), ("macquarie.com.au", "domain.bank"),
        ("bankofamerica.com", "domain.bank"), ("chase.com", "domain.bank"), ("paypal.com", "domain.bank"),
        ("wise.com", "domain.bank"),
        // Health (medicare.gov.au is already covered by gov.au)
        ("healthengine.com.au", "domain.health"), ("hotdoc.com.au", "domain.health"),
        ("bupa.com.au", "domain.health"), ("medibank.com.au", "domain.health"),
    ]

    /// Public senders: exact hosts only, no subdomain wildcard (Q61).
    static let publicHosts: [(host: String, ruleID: String)] = [
        ("substack.com", "allowlist.substack"), ("medium.com", "allowlist.medium"),
    ]

    /// Word-boundary phrases (token sequences, lowercase). Plural forms are listed explicitly.
    static let phrases: [(ruleID: String, phrases: [[String]])] = [
        ("kw.otp", [["otp"], ["verification", "code"], ["verification", "codes"], ["one", "time", "code"],
                    ["one", "time", "password"], ["sign", "in", "code"], ["signin", "code"],
                    ["security", "code"], ["login", "code"], ["passcode"]]),
        ("kw.credentials", [["password", "reset"], ["reset", "your", "password"], ["credentials"],
                            ["login", "link"], ["magic", "link"]]),
        ("kw.financial", [["statement"], ["statements"], ["invoice"], ["invoices"], ["receipt"], ["receipts"],
                          ["payment"], ["payments"], ["transaction"], ["transactions"]]),
        ("kw.medical", [["medical"], ["health"], ["prescription"], ["prescriptions"],
                        ["appointment", "with", "a", "doctor"], ["appointment", "with", "your", "doctor"],
                        ["appointment", "with", "doctor"], ["doctor", "appointment"]]),
        ("kw.tax", [["tax"], ["taxes"], ["tfn"], ["abn"], ["irs"]]),
    ]

    private static let otpWords: Set<String> = ["code", "codes", "otp", "pin", "passcode", "verification", "verify"]

    public func classify(_ input: PrivacyInput) -> PreFilterVerdict {
        if let id = privateRule(for: input) { return .private(id) }
        if input.inspection == .complete, let id = publicRule(for: input) { return .public(id) }
        return .needsTriage
    }

    // MARK: Private

    private func privateRule(for input: PrivacyInput) -> String? {
        if let host = Self.host(of: input.sender) {
            for d in Self.sensitiveDomains where host == d.suffix || host.hasSuffix("." + d.suffix) {
                return d.ruleID
            }
        }
        let text = input.subject + "\n" + input.body
        let tokens = Self.tokens(text)
        for rule in Self.phrases {
            for phrase in rule.phrases where Self.contains(tokens, phrase) { return rule.ruleID }
        }
        if Self.hasCardNumber(text) { return "pattern.card" }
        if Self.hasIBAN(text) { return "pattern.iban" }
        if Self.hasBSBAccount(text) { return "pattern.bsb" }
        if Self.hasTFN(text) { return "pattern.tfn" }
        if Self.hasOTPCode(tokens) { return "pattern.otp" }
        return nil
    }

    private func publicRule(for input: PrivacyInput) -> String? {
        guard let host = Self.host(of: input.sender),
              let entry = Self.publicHosts.first(where: { $0.host == host }) else { return nil }
        let unsub = input.headers.first { $0.key.lowercased() == "list-unsubscribe" }?.value.lowercased() ?? ""
        guard unsub.contains("<https:") || unsub.contains("<mailto:") else { return nil }
        return entry.ruleID
    }

    // MARK: Helpers

    /// Lowercased host of "Name <a@b>" or "a@b"; trailing dot removed. IDN is left as-is.
    static func host(of sender: String) -> String? {
        var addr = Substring(sender)
        if let open = sender.lastIndex(of: "<"), let close = sender[open...].firstIndex(of: ">") {
            addr = sender[sender.index(after: open)..<close]
        }
        guard let at = addr.lastIndex(of: "@") else { return nil }
        var host = addr[addr.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Lowercase alphanumeric runs; punctuation and HTML tags just act as separators.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    private static func contains(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard let first = phrase.first, tokens.count >= phrase.count else { return false }
        var i = 0
        while i <= tokens.count - phrase.count {
            if tokens[i] == first, Array(tokens[i..<(i + phrase.count)]) == phrase { return true }
            i += 1
        }
        return false
    }

    /// Digit groups separated by single spaces or dashes, e.g. "4242 4242" -> ["4242","4242"].
    private static func digitGroupRuns(_ text: String) -> [[String]] {
        var runs: [[String]] = []
        var groups: [String] = []
        var current = ""
        var pendingSep = false   // a single separator was seen after the last group
        func flushRun() { if !current.isEmpty { groups.append(current); current = "" }; if !groups.isEmpty { runs.append(groups) }; groups = []; pendingSep = false }
        for ch in text {
            if ch.isASCII, ch.isNumber {
                current.append(ch); pendingSep = false
            } else if (ch == " " || ch == "-"), !current.isEmpty, !pendingSep {
                groups.append(current); current = ""; pendingSep = true
            } else {
                flushRun()
            }
        }
        flushRun()
        return runs
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static func hasCardNumber(_ text: String) -> Bool {
        for run in digitGroupRuns(text) {
            for start in run.indices {
                var digits = ""
                for end in start..<run.count {
                    digits += run[end]
                    if digits.count > 19 { break }
                    if digits.count >= 13, luhn(digits) { return true }
                }
            }
        }
        return false
    }

    /// Valid TFN checksum for 9 digits: weighted sum divisible by 11.
    static func tfnValid(_ digits: String) -> Bool {
        let weights = [1, 4, 3, 7, 5, 8, 6, 9, 10]
        let ds = digits.compactMap { $0.wholeNumberValue }
        guard ds.count == 9 else { return false }
        return zip(ds, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0
    }

    static func hasTFN(_ text: String) -> Bool {
        for run in digitGroupRuns(text) where run.count >= 3 {
            for start in 0...(run.count - 3) {
                let w = run[start..<(start + 3)]
                if w.allSatisfy({ $0.count == 3 }), tfnValid(w.joined()) { return true }
            }
        }
        return false
    }

    private static let bsbRegex = try? NSRegularExpression(
        pattern: #"(?<![\d-])\d{3}-\d{3}(?!\d)[\s,:;-]*(?:acc(?:ount)?\.?\s*(?:no\.?|number|#)?\s*:?\s*)?\d{6,10}(?!\d)"#,
        options: [.caseInsensitive])
    private static let ibanRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?(?![A-Za-z0-9])"#)

    static func hasBSBAccount(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return bsbRegex?.firstMatch(in: text, range: range) != nil
    }

    static func hasIBAN(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for m in ibanRegex?.matches(in: text, range: range) ?? [] {
            guard let r = Range(m.range, in: text) else { continue }
            var groups = text[r].split(separator: " ").map(String.init)
            // The optional trailing group may be an ordinary capitalised word; try without it too.
            for _ in 0..<2 {
                let compact = groups.joined()
                if (15...34).contains(compact.count), ibanChecksum(compact) { return true }
                if groups.count > 1 { groups.removeLast() } else { break }
            }
        }
        return false
    }

    /// ISO 7064 mod 97-10.
    private static func ibanChecksum(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for c in rearranged {
            guard let v = c.asciiValue else { return false }
            let n: Int
            switch v {
            case 0x30...0x39: n = Int(v) - 0x30
            case 0x41...0x5A: n = Int(v) - 0x41 + 10
            default: return false
            }
            remainder = (n >= 10 ? remainder * 100 + n : remainder * 10 + n) % 97
        }
        return remainder == 1
    }

    /// A 4-8 digit token within four tokens of an OTP word. Plain numbers elsewhere are ignored.
    static func hasOTPCode(_ tokens: [String]) -> Bool {
        for (i, t) in tokens.enumerated() where (4...8).contains(t.count) && t.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let lo = max(0, i - 4), hi = min(tokens.count - 1, i + 4)
            if tokens[lo...hi].contains(where: { otpWords.contains($0) }) { return true }
        }
        return false
    }
}
