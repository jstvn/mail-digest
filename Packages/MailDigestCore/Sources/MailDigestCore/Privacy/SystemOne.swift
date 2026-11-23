import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Text sent to System One. Email content only ever appears in `state`, never in instructions.
public struct TriageInput: Sendable, Equatable {
    public var state: String
    public init(state: String) { self.state = state }
}

/// Raw answers from `/v1/systemone`, before validation. Values may be missing or out of range.
public struct SystemOneScores: Sendable, Equatable {
    /// `contains_pii_or_sensitive.noul`: P(sensitive).
    public var noul: Double?
    /// `mail_category.probabilities`; empty when absent.
    public var categoryProbabilities: [String: Double]

    public init(noul: Double?, categoryProbabilities: [String: Double]) {
        self.noul = noul
        self.categoryProbabilities = categoryProbabilities
    }
}

/// Runs System One triage. Implementations throw `TriageFailure` for failures and
/// `CancellationError` on cancellation (never converted to a failure).
public protocol SystemOneClient: Sendable {
    /// Checks Ollama version and model presence. `nil` means ready.
    func preflight(model: String) async throws -> TriageFailure?
    func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores
}

/// Question names and criteria keys, exactly as specified (SPEC "System One triage", Q62).
public enum SystemOneSpec {
    public static let sensitiveQuestion = "contains_pii_or_sensitive"
    public static let categoryQuestion = "mail_category"
    public static let publicCategory = "public_newsletter_or_promo"
    public static let sensitiveInstructions = "Should this email stay on the user's own device because it reveals sensitive personal information in a private, confidential, transactional or apparently unintended way? Answer yes for identifiable medical, financial, legal or identity records; credentials or security codes; account, billing or transaction details; private correspondence; confidential work matters; or a private individual's sensitive details disclosed without clear intent to publish. Answer no for public discussion of medical, financial or tax topics; anonymised case studies; testimonials and reader stories clearly written for publication; and ordinary names, public figures or publicly available contact details. Mentioning a sensitive topic is not the same as containing a private record."
    public static let categoryInstructions = "Classify the primary nature of this email. Text after a reply marker or signature is part of the email."
    /// Ordered for a stable request body.
    public static let categoryCriteria: [(key: String, text: String)] = [
        ("public_newsletter_or_promo", "Public newsletters, articles, marketing promotions, product updates, public announcements or public notifications, including published stories, testimonials and discussion of medical, financial or tax topics."),
        ("personal_or_work_private", "Private correspondence, replies between individuals, internal work communication, or personal scheduling, even when quoted inside another message."),
        ("sensitive_transactional", "Bills, receipts, security alerts, account statements, order or delivery details for a person, or legal or medical documents about a person."),
    ]
    /// Minimum Ollama version for the Kev triage models (Kev model page; System One itself needs 0.35.0).
    public static let minimumOllamaVersion = [0, 40, 4]
    public static let publicFloor = 0.85
    public static let thresholdRange = 0.80...0.99
}

/// The triage states for one email: one per chunk of the prepared text.
public struct TriagePlan: Sendable, Equatable {
    public var inputs: [TriageInput]
    /// The real number of chunks the text needs, even when it is over budget.
    public var totalChunks: Int
    /// False when the text needs more than `TriageInputBuilder.maxChunks` chunks; `inputs` is then empty.
    public var isWithinBudget: Bool

    public init(inputs: [TriageInput], totalChunks: Int, isWithinBudget: Bool) {
        self.inputs = inputs
        self.totalChunks = totalChunks
        self.isWithinBudget = isWithinBudget
    }
}

/// Builds the `state` strings: prepared text (see `PrivacyAssessmentText`) split into overlapping chunks,
/// each state <= 1,500 characters. Nothing is truncated; text that needs too many chunks is reported instead.
public struct TriageInputBuilder: Sendable {
    public static let maxStateCharacters = 1_500
    public static let maxChunks = 6
    static let maxSubject = 200
    static let maxSender = 120
    /// Characters repeated between consecutive chunks so a detail on a boundary is seen whole.
    static let overlap = 80
    static let trackingParams: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "mc_cid", "mc_eid",
        "_hsenc", "_hsmi", "mkt_tok", "igshid", "vero_id", "oly_enc_id", "oly_anon_id", "ref_src",
    ]
    public init() {}

    public func plan(_ email: EmailMessage) -> TriagePlan {
        let prefix = "Subject: \(String(Self.collapse(email.subject).prefix(Self.maxSubject)))\n"
            + "From: \(String(Self.collapse(RelaySender.displaySender(from: email.sender, headers: email.headers)).prefix(Self.maxSender)))\nBody: "
        let room = Self.maxStateCharacters - prefix.count
        let chunks = Self.chunks(Array(PrivacyAssessmentText.prepare(body: email.body)), room: room)
        guard chunks.count <= Self.maxChunks else {
            return TriagePlan(inputs: [], totalChunks: chunks.count, isWithinBudget: false)
        }
        return TriagePlan(inputs: chunks.map { TriageInput(state: prefix + $0) },
                          totalChunks: chunks.count, isWithinBudget: true)
    }

    /// Splits on spaces where possible; a run without spaces is hard-split. Always returns at least one chunk.
    private static func chunks(_ text: [Character], room: Int) -> [String] {
        guard text.count > room else { return [String(text)] }
        var out: [String] = []
        var start = 0
        while true {
            let hardEnd = min(start + room, text.count)
            var end = hardEnd
            if hardEnd < text.count {
                // Prefer the last space in the second half of the window, so progress is guaranteed.
                var k = hardEnd - 1
                while k > start + room / 2, text[k] != " " { k -= 1 }
                if text[k] == " ", k > start + room / 2 { end = k }
            }
            out.append(String(text[start..<end]).trimmingCharacters(in: .whitespaces))
            if end >= text.count { return out }
            // Step back by the overlap, then to a word start so words are not cut in the overlap.
            var next = end - overlap
            var back = next
            while back > next - 40, back > start, text[back - 1] != " " { back -= 1 }
            if back > start, text[back - 1] == " " { next = back }
            start = next
        }
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)

    static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || trackingParams.contains(n)
    }

    /// Removes tracking query parameters from URLs, keeping the rest of each URL.
    static func stripTracking(_ text: String) -> String {
        guard let regex = urlRegex else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += stripURL(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func stripURL(_ url: String) -> String {
        guard let q = url.firstIndex(of: "?") else { return url }
        let base = url[..<q]
        var rest = url[url.index(after: q)...]
        var fragment = ""
        if let h = rest.firstIndex(of: "#") { fragment = String(rest[h...]); rest = rest[..<h] }
        let kept = rest.split(separator: "&", omittingEmptySubsequences: true).filter { pair in
            !isTracking(String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""))
        }
        return String(base) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment
    }
}

/// Pure threshold logic (SPEC "System One triage"). Fails closed on any missing or invalid score.
public struct TriageEvaluator: Sendable {
    public init() {}

    /// Absorbs floating-point error in `1 - noul` so boundary values stay inclusive.
    private static let epsilon = 1e-9

    public func evaluate(_ scores: SystemOneScores, model: String, threshold: Double,
                         publicFloor: Double = SystemOneSpec.publicFloor, waivePublicFloor: Bool = false,
                         assessedAt: Date) -> PrivacyAssessment {
        let t = threshold.isFinite
            ? min(max(threshold, SystemOneSpec.thresholdRange.lowerBound), SystemOneSpec.thresholdRange.upperBound)
            : SystemOneSpec.thresholdRange.upperBound
        func valid(_ v: Double) -> Bool { v.isFinite && (0...1).contains(v) }

        var failed = false
        var pSensitive: Double?
        if let n = scores.noul, valid(n) { pSensitive = n } else { failed = true }
        var cats: [String: Double] = [:]
        for (k, v) in scores.categoryProbabilities {
            if valid(v) { cats[k] = v } else { failed = true }
        }
        let pPublic = cats[SystemOneSpec.publicCategory]
        if pPublic == nil { failed = true }
        let pNon = pSensitive.map { 1 - $0 }
        let triage = TriageScores(model: model, pSensitive: pSensitive, pNonSensitive: pNon,
                                  categoryProbabilities: cats, threshold: t, publicFloor: publicFloor,
                                  publicFloorWaived: waivePublicFloor)
        if failed {
            return PrivacyAssessment(verdict: .uncertain, method: .systemOne, triage: triage,
                                     triageFailure: .malformedResponse, assessedAt: assessedAt)
        }
        // Q95: a bulk message (List-Unsubscribe, no risk signal) needs only the non-sensitive score.
        let eligible = pNon! + Self.epsilon >= t && (waivePublicFloor || pPublic! + Self.epsilon >= publicFloor)
        // Confidently sensitive is a decision of its own, distinct from merely not confident enough.
        let verdict: PrivacyVerdict = eligible ? .public : (pSensitive! >= 0.5 ? .private : .uncertain)
        return PrivacyAssessment(verdict: verdict, method: .systemOne, triage: triage, assessedAt: assessedAt)
    }
}

/// `SystemOneClient` backed by a local Ollama server. Create one per job: the preflight is cached.
public actor OllamaSystemOneClient: SystemOneClient {
    public let baseURL: URL
    public let timeout: TimeInterval
    private let session: URLSession
    private var versionResult: TriageFailure??   // nil = not checked yet
    private var tagsResult: [String: TriageFailure?] = [:]

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared,
                timeout: TimeInterval = 90) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func preflight(model: String) async throws -> TriageFailure? {
        let version: TriageFailure?
        if let cached = versionResult { version = cached } else {
            version = try await checkVersion()
            versionResult = .some(version)
        }
        if let failure = version { return failure }
        if let cached = tagsResult[model] { return cached }
        let result = try await checkModel(model)
        // Only a found model is cached: a missing one may be installed (`ollama pull`) before the next check.
        if result == nil { tagsResult[model] = .some(nil) }
        return result
    }

    public func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores {
        let body = Self.requestBody(input, model: model)
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try body.stableData()
        let data = try await send(request)
        return try Self.decode(data)
    }

    // MARK: Request / response

    /// The exact JSON body POSTed to `/v1/systemone`; public so the eval harness sends the production request.
    public static func requestBody(_ input: TriageInput, model: String) -> JSONValue {
        var criteria: [String: JSONValue] = [:]
        for c in SystemOneSpec.categoryCriteria { criteria[c.key] = .string(c.text) }
        return .object([
            "model": .string(model),
            "state": .string(input.state),
            "questions": .object([
                SystemOneSpec.sensitiveQuestion: .object([
                    "type": .string("noul"),
                    "instructions": .string(SystemOneSpec.sensitiveInstructions),
                ]),
                SystemOneSpec.categoryQuestion: .object([
                    "type": .string("choice"),
                    "instructions": .string(SystemOneSpec.categoryInstructions),
                    "criteria": .object(criteria),
                ]),
            ]),
        ])
    }

    private struct Answer: Decodable { var noul: Double?; var probabilities: [String: Double]? }
    private struct Envelope: Decodable { var answers: [String: Answer] }

    /// Parses a `/v1/systemone` response body into scores; throws `TriageFailure.malformedResponse`.
    public static func decode(_ data: Data) throws -> SystemOneScores {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw TriageFailure.malformedResponse
        }
        return SystemOneScores(noul: env.answers[SystemOneSpec.sensitiveQuestion]?.noul,
                               categoryProbabilities: env.answers[SystemOneSpec.categoryQuestion]?.probabilities ?? [:])
    }

    // MARK: Preflight

    private func checkVersion() async throws -> TriageFailure? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 10
        let data: Data
        do { data = try await send(request) } catch let f as TriageFailure { return f }
        struct V: Decodable { var version: String }
        guard let v = try? JSONDecoder().decode(V.self, from: data), let parts = Self.parseVersion(v.version) else {
            return .versionUnknown
        }
        return parts.lexicographicallyPrecedes(SystemOneSpec.minimumOllamaVersion) ? .versionTooOld : nil
    }

    /// "0.40.14" or "0.41.0-rc1" -> [0, 40, 14]; nil when not semver-like.
    static func parseVersion(_ s: String) -> [Int]? {
        var core = s.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") { core.removeFirst() }
        if let i = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<i]) }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    private func checkModel(_ model: String) async throws -> TriageFailure? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 10
        let data: Data
        do { data = try await send(request) } catch let f as TriageFailure { return f }
        struct Tags: Decodable { struct M: Decodable { var name: String }; var models: [M] }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return .malformedResponse }
        let wanted: Set<String> = model.contains(":") ? [model] : [model, model + ":latest"]
        return tags.models.contains(where: { wanted.contains($0.name) }) ? nil : .modelMissing
    }

    // MARK: Transport

    /// Returns the body of a 2xx answer; maps everything else to `TriageFailure`.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OllamaClient.perform(request, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw TriageFailure.timedOut
        } catch {
            throw TriageFailure.unreachable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TriageFailure.malformedResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 404: throw TriageFailure.modelMissing
        case 400:
            // Only the error class is used; the text may echo the request.
            struct E: Decodable { var error: String }
            let text = (try? JSONDecoder().decode(E.self, from: data))?.error.lowercased() ?? ""
            throw (text.contains("model") || text.contains("runner")) ? TriageFailure.unsupportedModel
                                                                      : TriageFailure.httpError
        default: throw TriageFailure.httpError
        }
    }
}
