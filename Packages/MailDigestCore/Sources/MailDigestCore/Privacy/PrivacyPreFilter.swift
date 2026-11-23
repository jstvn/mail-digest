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

/// Why a message goes to System One instead of being decided by rules.
public enum TriageTrigger: String, Codable, Sendable, Equatable {
    /// Unknown sender with no strong rule.
    case ambiguousSender
    /// Allowlisted sender, but a contextual risk signal fired.
    case trustedSenderRisk
    /// Sensitive sender domain with bulk-mail headers and no transactional evidence.
    case sensitiveSender
}

public enum PreFilterVerdict: Sendable, Equatable {
    /// Stays local; carries the stable rule id.
    case `private`(String)
    /// Trusted newsletter sender with no risk signal; eligible for the cloud.
    case `public`(String)
    /// System One decides. `signal` is the first contextual risk signal id, if any (never matched text).
    case needsTriage(TriageTrigger, signal: String?)
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

    /// Public senders (Q61, Q95): exact hosts or exact full addresses (lowercase), no wildcard and no
    /// subdomain matching. Plain `linkedin.com` is deliberately absent: only the bulk senders below match.
    static let publicHosts: [(host: String, ruleID: String)] = [
        ("substack.com", "allowlist.substack"), ("medium.com", "allowlist.medium"),
        ("glassdoor.com", "allowlist.glassdoor"), ("letterboxd.com", "allowlist.letterboxd"),
        ("em.linkedin.com", "allowlist.linkedin.em"), ("email.seek.com.au", "allowlist.seek"),
        ("jora.com", "allowlist.jora"),
        ("jobs-noreply@linkedin.com", "allowlist.linkedin.jobs"),
        ("jobalerts-noreply@linkedin.com", "allowlist.linkedin.jobalerts"),
        ("newsletters-noreply@linkedin.com", "allowlist.linkedin.newsletters"),
    ]

    /// Unconditional private rules: word-boundary token sequences (lowercase).
    static let phrases: [(ruleID: String, phrases: [[String]])] = [
        ("kw.otp", [["otp"], ["verification", "code"], ["verification", "codes"], ["one", "time", "code"],
                    ["one", "time", "password"], ["sign", "in", "code"], ["signin", "code"],
                    ["security", "code"], ["login", "code"], ["passcode"]]),
        ("kw.credentials", [["password", "reset"], ["reset", "your", "password"], ["credentials"],
                            ["login", "link"], ["magic", "link"]]),
    ]

    /// Strong record phrases. `plain` matches alone; `gated` matches only when a token containing a digit
    /// follows within `valueWindow` tokens ("Amount due: $120.50" yes, "track amount due" no).
    static let recordRules: [(ruleID: String, plain: [[String]], gated: [[String]])] = [
        ("kw.financial.record",
         plain: [
            ["your", "statement", "is", "ready"], ["your", "statement", "is", "available"],
            ["your", "bank", "statement"], ["account", "statement"], ["payment", "confirmation"],
            ["payment", "failed"], ["payment", "declined"], ["statement", "balance"], ["closing", "balance"],
            ["available", "balance"]],
         gated: [
            ["amount", "due"], ["balance", "due"], ["payment", "due"], ["payment", "received"],
            ["tax", "invoice"], ["invoice", "number"], ["invoice", "no"], ["your", "invoice"],
            ["your", "receipt"], ["order", "receipt"], ["payment", "receipt"], ["your", "payment"],
            ["transaction", "id"], ["transaction", "reference"], ["receipt", "number"], ["card", "ending"],
            ["account", "number"], ["direct", "debit"]]),
        ("kw.medical.record",
         plain: [
            ["your", "appointment", "with", "dr"], ["your", "appointment", "with", "doctor"],
            ["your", "medical", "record"], ["your", "medical", "records"], ["your", "lab", "results"],
            ["your", "blood", "test"], ["your", "pathology", "results"], ["your", "scan", "results"],
            ["your", "biopsy"], ["your", "prescription", "is", "ready"], ["your", "referral", "letter"]],
         gated: []),
        ("kw.tax.record",
         plain: [["notice", "of", "assessment"], ["your", "tfn"]],
         gated: [["your", "tax", "return"], ["your", "tax", "refund"], ["tax", "file", "number"],
                 ["tax", "owing"], ["tax", "payable"]]),
    ]
    static let valueWindow = 6

    /// Weaker personal-context phrases (token sequences). A hit is a risk signal, not a private match.
    static let personalSignals: [(ruleID: String, phrases: [[String]])] = [
        ("risk.financial.personal", [
            ["your", "invoice"], ["your", "payment"], ["your", "receipt"], ["order", "receipt"],
            ["your", "statement"], ["your", "transaction"], ["your", "account", "balance"], ["overdue"],
            ["your", "tax", "return"], ["your", "tax", "refund"], ["tax", "file", "number"]]),
        ("risk.medical.personal", [
            ["prescription"], ["prescriptions"], ["appointment", "with", "a", "doctor"],
            ["appointment", "with", "your", "doctor"], ["appointment", "with", "doctor"],
            ["doctor", "appointment"]]),
    ]

    /// Distance in characters within which a diagnosis or sensitive-topic term and an identifier combine.
    static let proximity = 300

    private static let diagnosisPattern = #"\b(?:diagnosis|diagnosed|cancer|chemotherapy|hiv|leukemia|leukaemia|lymphoma|diabetes|schizophrenia|bipolar|depression|miscarriage|dementia|alzheimer['’]s|parkinson['’]s|epilepsy|biopsy|tumor|tumour|ptsd|psychiatric|treatment for|mental illness)\b"#
    private static let sensitiveTopicPattern = #"\b(?:divorce|custody|bankruptcy|eviction|arrested|criminal record|immigration status|visa application|domestic violence|salary|debt)\b"#

    private static let diagnosisRegex = try? NSRegularExpression(pattern: diagnosisPattern, options: [.caseInsensitive])
    private static let sensitiveTopicRegex = try? NSRegularExpression(pattern: sensitiveTopicPattern, options: [.caseInsensitive])
    private static let addressRegex = try? NSRegularExpression(
        pattern: #"\b\d{1,5}[A-Za-z]?[ \t]+(?:[A-Z][A-Za-z]+[ \t]+){1,3}(?:St|Street|Rd|Road|Ave|Avenue|Way|Lane|Ln|Dr|Drive|Ct|Court|Pl|Place|Cres|Crescent|Blvd|Boulevard|Tce|Terrace)\b"#)
    private static let phoneRegex = try? NSRegularExpression(
        pattern: #"(?<!\d)(?:\+\d{1,3}[ -]?)?(?:\(\d{1,4}\)[ -]?)?\d{2,4}(?:[ -]\d{2,4}){1,4}(?!\d)"#)
    private static let dobRegex = try? NSRegularExpression(
        pattern: #"\b(?:date of birth|dob|born on)\b[^\d\n]{0,8}\d"#, options: [.caseInsensitive])
    private static let selfAddressRegex = try? NSRegularExpression(
        pattern: #"\b(?:my address|my home address|lives at)\b"#, options: [.caseInsensitive])
    // Case-sensitive on purpose: "Firstname Lastname". The first word must not be a title or stopword.
    private static let namedDiagnosedRegex = try? NSRegularExpression(
        pattern: #"(?<!Dr )(?<!Dr\. )(?<!Prof )(?<!Prof\. )(?<!Professor )\b(?!(?:Dr|Prof|Professor|The|A|An|This|That|Dear|Our|New)\b)[A-Z][a-z]+ [A-Z][a-z]+(?:, \d{1,3},)? (?:was|has been|is being) (?:diagnosed|treated)\b"#)
    private static let namedPossessiveRegex = try? NSRegularExpression(
        pattern: #"(?<!Dr )(?<!Dr\. )(?<!Prof )(?<!Prof\. )(?<!Professor )\b(?!(?:Dr|Prof|Professor|The|A|An|This|That|Dear|Our|New)\b)[A-Z][a-z]+ [A-Z][a-z]+['’]s (?i:diagnosis|diagnosed|cancer|chemotherapy|hiv|leukemia|leukaemia|lymphoma|diabetes|schizophrenia|bipolar|depression|miscarriage|dementia|alzheimer['’]s|parkinson['’]s|epilepsy|biopsy|tumor|tumour|ptsd|psychiatric|treatment for|mental illness)\b"#)

    private static let otpWords: Set<String> = ["code", "codes", "otp", "pin", "passcode", "verification", "verify"]

    public func classify(_ input: PrivacyInput) -> PreFilterVerdict {
        // A verified Hide My Email relay is judged by its original sender, not by icloud.com.
        let relayOriginal = RelaySender.originalSender(from: input.sender, headers: input.headers)
        let fromHost = Self.host(of: input.sender)
        let host = relayOriginal.flatMap(Self.host(of:)) ?? fromHost
        let address = relayOriginal.flatMap(Self.address(of:)) ?? Self.address(of: input.sender)
        // Fail closed: the sensitive-domain check also looks at every host that could name the sender,
        // including an unverified `s=` claim (it can only make mail more local).
        let sensitiveHosts = [fromHost, host, RelaySender.claimedSender(headers: input.headers).flatMap(Self.host(of:))]
        let sensitiveRule = sensitiveHosts.compactMap { $0 }.lazy.compactMap(Self.sensitiveDomainRule(host:)).first
        let hasUnsub = Self.hasValidUnsubscribe(input.headers)
        let strong = strongRule(for: input)
        if let domain = sensitiveRule {
            // One-to-one mail from a bank, agency or clinic stays private; so does anything with transactional
            // evidence. A bulk announcement without it goes to System One, never straight to the cloud.
            if strong != nil || !hasUnsub { return .private(domain) }
            return .needsTriage(.sensitiveSender, signal: riskSignal(for: input))
        }
        if let strong { return .private(strong) }
        let signal = riskSignal(for: input)
        if input.inspection == .complete, hasUnsub, let host,
           let entry = Self.publicHosts.first(where: { $0.host == host || $0.host == address }) {
            if let signal { return .needsTriage(.trustedSenderRisk, signal: signal) }
            return .public(entry.ruleID)
        }
        return .needsTriage(.ambiguousSender, signal: signal)
    }

    // MARK: Strong rules

    private func strongRule(for input: PrivacyInput) -> String? {
        let text = input.subject + "\n" + input.body
        let tokens = Self.tokens(text)
        for rule in Self.phrases {
            for phrase in rule.phrases where Self.contains(tokens, phrase) { return rule.ruleID }
        }
        for rule in Self.recordRules {
            for phrase in rule.plain where Self.contains(tokens, phrase) { return rule.ruleID }
            for phrase in rule.gated where Self.contains(tokens, phrase, valueWithin: Self.valueWindow) {
                return rule.ruleID
            }
        }
        // Digits inside URLs (tracking ids, timestamps) are never account data.
        let numeric = Self.maskingURLs(text)
        if Self.hasCardNumber(numeric) { return "pattern.card" }
        if Self.hasIBAN(numeric) { return "pattern.iban" }
        if Self.hasBSBAccount(numeric) { return "pattern.bsb" }
        if Self.hasTFN(numeric) { return "pattern.tfn" }
        if Self.hasOTPCode(tokens) { return "pattern.otp" }
        return nil
    }

    private static func sensitiveDomainRule(host: String) -> String? {
        sensitiveDomains.first { host == $0.suffix || host.hasSuffix("." + $0.suffix) }?.ruleID
    }

    /// A usable `List-Unsubscribe` target (https or mailto).
    static func hasValidUnsubscribe(_ headers: [String: String]) -> Bool {
        let unsub = headers.first { $0.key.lowercased() == "list-unsubscribe" }?.value.lowercased() ?? ""
        return unsub.contains("<https:") || unsub.contains("<mailto:")
    }

    // MARK: Risk signals

    /// First contextual risk signal id, or nil. Names, addresses and diagnosis words alone never fire.
    func riskSignal(for input: PrivacyInput) -> String? {
        if Self.hasEmbeddedConversation(input.body) { return "risk.embedded.conversation" }
        let text = input.subject + "\n" + input.body
        if Self.hasMedicalIdentifiable(text) { return "risk.medical.identifiable" }
        if Self.hasIdentifiableSensitive(text) { return "risk.identifiable.sensitive" }
        let tokens = Self.tokens(text)
        for rule in Self.personalSignals {
            for phrase in rule.phrases where Self.contains(tokens, phrase) { return rule.ruleID }
        }
        return nil
    }

    /// Reply or forward structure: an "On ... wrote:" line (also wrapped over two lines), an original-message
    /// banner, or at least two quoted lines.
    static func hasEmbeddedConversation(_ body: String) -> Bool {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var quoted = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix(">") { quoted += 1; if quoted >= 2 { return true } }
            let lower = line.lowercased()
            if lower.contains("-----original message-----") || lower.contains("forwarded message") { return true }
            if line.hasPrefix("On ") {
                if line.hasSuffix("wrote:") { return true }
                if i + 1 < lines.count, lines[i + 1].hasSuffix("wrote:") { return true }
            }
        }
        return false
    }

    static func hasMedicalIdentifiable(_ text: String) -> Bool {
        if matches(namedDiagnosedRegex, in: text) || matches(namedPossessiveRegex, in: text) { return true }
        let ids = identifierRanges(text, includeSelfReference: true)
        return anyWithinProximity(termRanges(diagnosisRegex, in: text), ids)
    }

    static func hasIdentifiableSensitive(_ text: String) -> Bool {
        anyWithinProximity(termRanges(sensitiveTopicRegex, in: text), identifierRanges(text, includeSelfReference: false))
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func termRanges(_ regex: NSRegularExpression?, in text: String) -> [NSRange] {
        regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range) ?? []
    }

    private static func anyWithinProximity(_ a: [NSRange], _ b: [NSRange]) -> Bool {
        a.contains { x in b.contains { y in abs(x.location - y.location) <= proximity } }
    }

    /// Street addresses, phone numbers and labelled dates of birth (plus "my address" style phrases).
    private static func identifierRanges(_ text: String, includeSelfReference: Bool) -> [NSRange] {
        let ns = text as NSString
        var out = termRanges(addressRegex, in: text) + termRanges(dobRegex, in: text)
        for r in termRanges(phoneRegex, in: text) where isPhone(ns.substring(with: r)) { out.append(r) }
        if includeSelfReference { out += termRanges(selfAddressRegex, in: text) }
        return out
    }

    /// 8 to 15 digits, and not a date or a run of years.
    private static func isPhone(_ s: String) -> Bool {
        let digits = s.filter { $0.isASCII && $0.isNumber }.count
        guard (8...15).contains(digits) else { return false }
        let groups = s.split(whereSeparator: { !$0.isNumber }).map(String.init)
        let sizes = groups.map(\.count)
        if sizes == [4, 2, 2] || (sizes.count == 3 && sizes[2] == 4 && sizes[0] <= 2 && sizes[1] <= 2) { return false }
        if groups.count >= 2, groups.allSatisfy({ $0.count == 4 && ($0.hasPrefix("19") || $0.hasPrefix("20")) }) {
            return false
        }
        return true
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

    /// Lowercased address of "Name <a@b>" or "a@b".
    static func address(of sender: String) -> String? {
        var addr = Substring(sender)
        if let open = sender.lastIndex(of: "<"), let close = sender[open...].firstIndex(of: ">") {
            addr = sender[sender.index(after: open)..<close]
        }
        let a = addr.trimmingCharacters(in: .whitespaces).lowercased()
        return a.contains("@") ? a : nil
    }

    /// Lowercase alphanumeric runs; punctuation and HTML tags just act as separators.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// True when `phrase` occurs; with `valueWithin`, also needs a digit-bearing token in the next N tokens.
    private static func contains(_ tokens: [String], _ phrase: [String], valueWithin: Int? = nil) -> Bool {
        guard let first = phrase.first, tokens.count >= phrase.count else { return false }
        var i = 0
        while i <= tokens.count - phrase.count {
            if tokens[i] == first, Array(tokens[i..<(i + phrase.count)]) == phrase {
                guard let n = valueWithin else { return true }
                let end = min(tokens.count, i + phrase.count + n)
                if tokens[(i + phrase.count)..<end].contains(where: { $0.contains(where: \.isNumber) }) { return true }
            }
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

    private static let urlRegex = try? NSRegularExpression(pattern: #"\S*://\S*|\bwww\.\S+"#, options: [.caseInsensitive])

    /// Replaces URL spans with a line break so digits inside them never join a number outside.
    static func maskingURLs(_ text: String) -> String {
        guard let urlRegex else { return text }
        return urlRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: "\n")
    }

    /// A checksum-valid TFN (9 digits, or three groups of 3) with "TFN" or "tax file number" within
    /// `valueWindow` tokens before or after it. Unlabelled numbers are too often just other numbers.
    static func hasTFN(_ text: String) -> Bool {
        let toks = tokens(text)
        var labels: [(start: Int, end: Int)] = []
        for (i, t) in toks.enumerated() {
            if t == "tfn" { labels.append((i, i)) }
            else if t == "tax", i + 2 < toks.count, toks[i + 1] == "file", toks[i + 2] == "number" { labels.append((i, i + 2)) }
        }
        guard !labels.isEmpty else { return false }
        func labelled(_ first: Int, _ last: Int) -> Bool {
            labels.contains { ($0.end < first && first - $0.end <= valueWindow) || ($0.start > last && $0.start - last <= valueWindow) }
        }
        let digits = { (s: String) in s.allSatisfy { $0.isASCII && $0.isNumber } }
        for i in toks.indices where digits(toks[i]) {
            if toks[i].count == 9, tfnValid(toks[i]), labelled(i, i) { return true }
            if i + 2 < toks.count, toks[i...(i + 2)].allSatisfy({ $0.count == 3 && digits($0) }),
               tfnValid(toks[i...(i + 2)].joined()), labelled(i, i + 2) { return true }
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
