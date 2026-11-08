import Foundation

// Pure types for the end-to-end selective-routing evaluation (eval/systemone, `systemone route`).
// The real `DigestRouter` runs on every fixture; nothing here touches the network. The EvalCLI supplies the
// live System One client. Records never carry message text or raw model output.

/// Which branch of the revised policy decided an email.
public enum RoutingPath: String, Codable, Sendable, CaseIterable {
    /// Allowlisted sender, valid unsubscribe, no risk signal: public without System One.
    case trustedDirect
    /// Allowlisted sender but a contextual risk signal fired: System One decides.
    case trustedSelective
    /// Unknown sender with no strong rule: System One decides.
    case ambiguousSystemOne
    /// Bank, agency or clinic bulk mail without transactional evidence: System One decides.
    case sensitiveSenderSystemOne
    /// A private rule or sensitive-domain rule decided, no model call.
    case deterministicPrivate
    /// Content not fully inspected: local, no model call.
    case inspectionLocal
    /// Anything else (for example cloud off).
    case other

    /// Derives the path from the router's assessment (method plus triage trigger).
    public static func derive(from a: PrivacyAssessment) -> RoutingPath {
        switch a.method {
        case .trustedSender: return .trustedDirect
        case .rule: return .deterministicPrivate
        case .inspection: return .inspectionLocal
        case .cloudOff: return .other
        case .systemOne:
            switch a.triageTrigger {
            case .trustedSenderRisk: return .trustedSelective
            case .ambiguousSender: return .ambiguousSystemOne
            case .sensitiveSender: return .sensitiveSenderSystemOne
            case nil: return .other
            }
        }
    }

    /// True when System One was (or would have been) consulted.
    public var usesSystemOne: Bool {
        self == .trustedSelective || self == .ambiguousSystemOne || self == .sensitiveSenderSystemOne
    }
}

/// One System One call: scores and timing only.
public struct SelectiveChunk: Codable, Sendable, Equatable {
    public var pSensitive: Double?
    public var pPublic: Double?
    public var stateLength: Int
    public var latencySeconds: Double

    public init(pSensitive: Double?, pPublic: Double?, stateLength: Int, latencySeconds: Double) {
        self.pSensitive = pSensitive; self.pPublic = pPublic
        self.stateLength = stateLength; self.latencySeconds = latencySeconds
    }
}

/// Verdict and method of the same email assessed with cloud off (no System One call).
public struct CloudOffOutcome: Codable, Sendable, Equatable {
    public var verdict: PrivacyVerdict
    public var method: AssessmentMethod
    public init(verdict: PrivacyVerdict, method: AssessmentMethod) { self.verdict = verdict; self.method = method }
}

/// What `DigestRouter.execute` did for a cloud-eligible email when the Gemini call fails.
public struct GeminiFallbackOutcome: Codable, Sendable, Equatable {
    public var provider: ExecutionProvider
    public var cloudAttempted: Bool
    public var localReason: LocalReason?
    public var cloudFailure: String?
    public init(provider: ExecutionProvider, cloudAttempted: Bool, localReason: LocalReason?, cloudFailure: String?) {
        self.provider = provider; self.cloudAttempted = cloudAttempted
        self.localReason = localReason; self.cloudFailure = cloudFailure
    }
}

/// One JSONL line of `systemone route`: one fixture, one model. No raw response and no body text.
public struct SelectiveRecord: Codable, Sendable, Equatable {
    public var model: String
    public var fixtureID: String
    public var label: BenchmarkLabel
    public var category: String
    public var scenario: String?
    public var split: String
    public var inspection: ContentInspection
    public var path: RoutingPath
    public var verdict: PrivacyVerdict
    public var method: AssessmentMethod
    public var ruleID: String?
    public var trigger: TriageTrigger?
    public var riskSignal: String?
    public var triageFailure: TriageFailure?
    public var coverage: TriageCoverage?
    public var chunks: [SelectiveChunk]
    public var totalTriageSeconds: Double
    public var cloudEligible: Bool
    public var cloudOff: CloudOffOutcome?
    public var geminiFallback: GeminiFallbackOutcome?

    public init(model: String, fixtureID: String, label: BenchmarkLabel, category: String, scenario: String?,
                split: String, inspection: ContentInspection, path: RoutingPath, verdict: PrivacyVerdict,
                method: AssessmentMethod, ruleID: String? = nil, trigger: TriageTrigger? = nil,
                riskSignal: String? = nil, triageFailure: TriageFailure? = nil, coverage: TriageCoverage? = nil,
                chunks: [SelectiveChunk] = [], totalTriageSeconds: Double = 0, cloudEligible: Bool,
                cloudOff: CloudOffOutcome? = nil, geminiFallback: GeminiFallbackOutcome? = nil) {
        self.model = model; self.fixtureID = fixtureID; self.label = label; self.category = category
        self.scenario = scenario; self.split = split; self.inspection = inspection; self.path = path
        self.verdict = verdict; self.method = method; self.ruleID = ruleID; self.trigger = trigger
        self.riskSignal = riskSignal; self.triageFailure = triageFailure; self.coverage = coverage
        self.chunks = chunks; self.totalTriageSeconds = totalTriageSeconds; self.cloudEligible = cloudEligible
        self.cloudOff = cloudOff; self.geminiFallback = geminiFallback
    }

    /// Items that can only route locally because content was not fully inspected.
    public var isInspectionLocal: Bool { category == BenchmarkFixtures.inspectionCategory || inspection != .complete }
    /// True when the text needed more chunks than the budget allows (expected to fail closed).
    public var isOverBudget: Bool { triageFailure == .contentTooLong }
    /// A triage error other than "too long": a timeout, bad response or unreachable server.
    public var isEvaluationFailure: Bool { triageFailure != nil && triageFailure != .contentTooLong }
}

/// Written next to a run (`F.meta.json`) so a result can be tied to the exact model build.
public struct SelectiveRunMeta: Codable, Sendable, Equatable {
    public var model: String
    public var modelDigest: String?
    public var baseURL: String
    public var threshold: Double
    public var publicFloor: Double
    public var fixtureFiles: [String]
    public var fixtureCount: Int
    public var startedAt: Date

    public init(model: String, modelDigest: String?, baseURL: String, threshold: Double, publicFloor: Double,
                fixtureFiles: [String], fixtureCount: Int, startedAt: Date) {
        self.model = model; self.modelDigest = modelDigest; self.baseURL = baseURL; self.threshold = threshold
        self.publicFloor = publicFloor; self.fixtureFiles = fixtureFiles; self.fixtureCount = fixtureCount
        self.startedAt = startedAt
    }
}

/// Wraps a System One client and records one chunk entry per `assess` call (also for failed calls).
/// Timing uses the injected clock so tests stay deterministic.
public actor RecordingSystemOneClient: SystemOneClient {
    private let base: any SystemOneClient
    private let clock: any Clock
    public private(set) var chunks: [SelectiveChunk] = []
    public private(set) var preflightCalls = 0

    public init(base: any SystemOneClient, clock: any Clock) { self.base = base; self.clock = clock }

    public func preflight(model: String) async throws -> TriageFailure? {
        preflightCalls += 1
        return try await base.preflight(model: model)
    }

    public func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores {
        let started = clock.now()
        do {
            let scores = try await base.assess(input, model: model)
            chunks.append(SelectiveChunk(pSensitive: scores.noul,
                                         pPublic: scores.categoryProbabilities[SystemOneSpec.publicCategory],
                                         stateLength: input.state.count,
                                         latencySeconds: clock.now().timeIntervalSince(started)))
            return scores
        } catch {
            chunks.append(SelectiveChunk(pSensitive: nil, pPublic: nil, stateLength: input.state.count,
                                         latencySeconds: clock.now().timeIntervalSince(started)))
            throw error
        }
    }

    /// Returns the recorded chunks and clears them for the next fixture.
    public func takeChunks() -> [SelectiveChunk] {
        defer { chunks = [] }
        return chunks
    }
}

/// Runs the real router for one fixture and builds its `SelectiveRecord`.
public enum SelectiveEvaluator {
    /// Cloud extractor that always fails, to observe the real local fallback after a cloud attempt.
    private struct FailingCloud: EmailExtractor {
        func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool, today: Date,
                     timeZone: TimeZone) async throws -> ExtractionResult { throw GeminiError.network }
    }

    /// Cloud extractor that is only present so cloud counts as on; the assessment never calls it.
    private struct PresentCloud: EmailExtractor {
        func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool, today: Date,
                     timeZone: TimeZone) async throws -> ExtractionResult { throw GeminiError.network }
    }

    /// - Parameters:
    ///   - triage: the underlying System One client (live Ollama in the CLI, a fake in tests).
    ///   - clock: used for chunk timing; the router itself gets a fixed clock.
    public static func evaluate(_ fixture: BenchmarkFixture, model: String, triage: any SystemOneClient,
                                clock: any Clock, threshold: Double = RoutingThresholds.production.threshold
    ) async throws -> SelectiveRecord {
        let email = fixture.email()
        let router = DigestRouter(clock: FixedAssessmentClock())
        let recorder = RecordingSystemOneClient(base: triage, clock: clock)
        let config = CloudRoutingConfig(cloudExtractor: PresentCloud(), cloudModel: "gemini-eval", offReason: nil,
                                        triage: recorder, triageModel: model, privacyThreshold: threshold)
        let a = try await router.assess(email, stored: nil, config: config)
        let chunks = await recorder.takeChunks()

        // Same email with cloud off: shows what the trusted-sender rule alone gives without a model call.
        let offConfig = CloudRoutingConfig(cloudExtractor: nil, cloudModel: "", offReason: .cloudDisabled,
                                           triage: nil, triageModel: model, privacyThreshold: threshold)
        let off = try await router.assess(email, stored: nil, config: offConfig)

        let eligible = a.verdict == .public && a.method != .cloudOff && email.contentInspection == .complete
        var fallback: GeminiFallbackOutcome?
        if eligible {
            let local = StubLLMClient()
            let (_, record) = try await router.execute(
                email, tier: .full, trustedNewsletter: false, today: Date(timeIntervalSince1970: 0),
                timeZone: TimeZone(identifier: "UTC") ?? .current, assessment: a,
                config: CloudRoutingConfig(cloudExtractor: FailingCloud(), cloudModel: "gemini-eval", offReason: nil,
                                           triage: nil, triageModel: model, privacyThreshold: threshold),
                local: local, localModel: "local-stub")
            fallback = GeminiFallbackOutcome(provider: record.provider, cloudAttempted: record.cloudAttempted,
                                             localReason: record.localReason, cloudFailure: record.cloudFailure)
        }
        return SelectiveRecord(
            model: model, fixtureID: fixture.id, label: fixture.label, category: fixture.category,
            scenario: fixture.scenario, split: fixture.split, inspection: fixture.inspection,
            path: RoutingPath.derive(from: a), verdict: a.verdict, method: a.method, ruleID: a.ruleID,
            trigger: a.triageTrigger, riskSignal: a.riskSignal, triageFailure: a.triageFailure,
            coverage: a.triageCoverage, chunks: chunks, totalTriageSeconds: chunks.reduce(0) { $0 + $1.latencySeconds },
            cloudEligible: eligible, cloudOff: CloudOffOutcome(verdict: off.verdict, method: off.method),
            geminiFallback: fallback)
    }

    private struct FixedAssessmentClock: Clock {
        func now() -> Date { Date(timeIntervalSince1970: 0) }
    }
}
