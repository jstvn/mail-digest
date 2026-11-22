import Foundation

// Pure data and metrics for the System One routing-accuracy benchmark (eval/systemone).
// Nothing here touches the network; the EvalCLI executable records raw model output and this file scores it.

/// Hand-written ground truth for one synthetic fixture. Never derived from any model.
public enum BenchmarkLabel: String, Codable, Sendable, CaseIterable {
    case `public`, `private`, ambiguous
}

/// What the model-only classifier says about a fixture.
public enum BenchmarkPrediction: String, Codable, Sendable, CaseIterable {
    case `public`, `private`, uncertain
}

/// One synthetic email with its label. `inspection` defaults to `complete` when absent in JSON.
public struct BenchmarkFixture: Codable, Sendable, Equatable {
    public var id: String
    public var split: String
    public var category: String
    public var label: BenchmarkLabel
    public var difficulty: String
    public var subject: String
    public var from: String
    public var headers: [String: String]
    public var body: String
    public var inspection: ContentInspection
    public var note: String
    /// Routing-evaluation scenario (`fixtures-routing.json`); nil in the original fixture set.
    public var scenario: String?

    public init(id: String, split: String, category: String, label: BenchmarkLabel, difficulty: String = "easy",
                subject: String, from: String, headers: [String: String] = [:], body: String,
                inspection: ContentInspection = .complete, note: String = "", scenario: String? = nil) {
        self.scenario = scenario
        self.id = id; self.split = split; self.category = category; self.label = label
        self.difficulty = difficulty; self.subject = subject; self.from = from; self.headers = headers
        self.body = body; self.inspection = inspection; self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), split: try c.decode(String.self, forKey: .split),
                  category: try c.decode(String.self, forKey: .category),
                  label: try c.decode(BenchmarkLabel.self, forKey: .label),
                  difficulty: try c.decode(String.self, forKey: .difficulty),
                  subject: try c.decode(String.self, forKey: .subject), from: try c.decode(String.self, forKey: .from),
                  headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                  body: try c.decode(String.self, forKey: .body),
                  inspection: try c.decodeIfPresent(ContentInspection.self, forKey: .inspection) ?? .complete,
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  scenario: try c.decodeIfPresent(String.self, forKey: .scenario))
    }

    private enum CodingKeys: String, CodingKey {
        case id, split, category, label, difficulty, subject, from, headers, body, inspection, note, scenario
    }

    /// The message as production sees it before `DigestRouter.assess` (the body is NOT pre-cleaned:
    /// `DigestPipeline` assesses the raw email and `TriageInputBuilder` cleans internally).
    public func email() -> EmailMessage {
        EmailMessage(id: id, account: "eval", mailbox: "INBOX", sender: from, subject: subject,
                     receivedAt: Date(timeIntervalSince1970: 0), body: body, headers: headers,
                     contentInspection: inspection)
    }

    /// True for the `inspection` category, which only demonstrates routing reasons and is excluded from metrics.
    public var isInspectionOnly: Bool { category == BenchmarkFixtures.inspectionCategory }

    /// True when the message was never fully inspected, so it can only ever route locally.
    public var isInspectionLocal: Bool { isInspectionOnly || inspection != .complete }
}

/// Fixture set constants and validation.
public enum BenchmarkFixtures {
    public static let inspectionCategory = "inspection"
    public static let categories = [
        "public_newsletter", "public_marketing", "public_notification", "private_personal", "personal_scheduling",
        "confidential_work", "financial_transactional", "personal_identifiers", "medical", "ambiguous",
        "public_with_sensitive", "prompt_injection",
    ]

    /// Problems with the dataset shape (empty when valid): 150 items, unique ids, 6+6 per category, 6 inspection items.
    public static func validate(_ fixtures: [BenchmarkFixture]) -> [String] {
        var problems: [String] = []
        if fixtures.count != 150 { problems.append("expected 150 fixtures, found \(fixtures.count)") }
        let ids = fixtures.map(\.id)
        if Set(ids).count != ids.count { problems.append("duplicate ids") }
        for cat in categories {
            for split in ["calibration", "heldout"] {
                let n = fixtures.filter { $0.category == cat && $0.split == split }.count
                if n != 6 { problems.append("\(cat)/\(split): expected 6, found \(n)") }
            }
        }
        let insp = fixtures.filter(\.isInspectionOnly)
        if insp.count != 6 || insp.contains(where: { $0.split != "heldout" || $0.inspection == .complete || $0.label != .public }) {
            problems.append("inspection category must be 6 heldout public items with non-complete inspection")
        }
        for f in fixtures where !(300...2_500).contains(f.body.count) {
            problems.append("\(f.id): body length \(f.body.count) outside 300-2500")
        }
        return problems
    }

    /// Scenarios of `fixtures-routing.json`. `long_over_budget` is the single item expected to fail closed.
    public static let routingScenarios = [
        "trusted_ordinary", "trusted_medical_research", "trusted_tax_policy", "trusted_invoice_software",
        "anonymised_case_study", "voluntary_reader_story", "identifiable_sensitive_newsletter",
        "public_figure_contact", "trusted_embedded_private", "private_medical_financial", "ambiguous_sender",
        "pii_in_quoted_reply", "pii_in_signature", "long_message", "long_over_budget", "bulk_sensitive_domain",
        "uninspected_parts",
    ]

    /// Problems with the routing fixture set (empty when valid): unique ids, a known `scenario` and split
    /// `selective` on every item, at least 5 items per scenario (1 for `long_over_budget`) and sane body sizes.
    public static func validateRouting(_ fixtures: [BenchmarkFixture]) -> [String] {
        var problems: [String] = []
        let ids = fixtures.map(\.id)
        if Set(ids).count != ids.count { problems.append("duplicate ids") }
        for f in fixtures {
            guard let s = f.scenario, routingScenarios.contains(s) else {
                problems.append("\(f.id): missing or unknown scenario"); continue
            }
            if f.split != "selective" { problems.append("\(f.id): split must be selective") }
            let range = s == "long_message" ? 2_500...9_000 : (s == "long_over_budget" ? 9_000...40_000 : 150...2_500)
            if !range.contains(f.body.count) { problems.append("\(f.id): body length \(f.body.count) outside \(range)") }
            if s == "uninspected_parts" && f.inspection == .complete { problems.append("\(f.id): needs non-complete inspection") }
            if s != "uninspected_parts" && f.inspection != .complete { problems.append("\(f.id): inspection must be complete") }
        }
        for s in routingScenarios {
            let n = fixtures.filter { $0.scenario == s }.count
            let need = s == "long_over_budget" ? 1 : 5
            if n < need { problems.append("\(s): expected at least \(need), found \(n)") }
        }
        return problems
    }
}

/// Pre-filter outcome in a flat, codable form.
public struct PreFilterResult: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case `private`, `public`, needsTriage }
    public var kind: Kind
    public var ruleID: String?

    public init(kind: Kind, ruleID: String? = nil) { self.kind = kind; self.ruleID = ruleID }

    public init(_ verdict: PreFilterVerdict) {
        switch verdict {
        case .private(let id): self.init(kind: .private, ruleID: id)
        case .public(let id): self.init(kind: .public, ruleID: id)
        // The trigger and signal are recorded in the rule id so reports can group by them.
        case .needsTriage(let trigger, let signal):
            self.init(kind: .needsTriage, ruleID: [trigger.rawValue, signal].compactMap { $0 }.joined(separator: ":"))
        }
    }
}

/// A routing decision: the verdict, what produced it and (for rules) the rule id.
public struct BenchmarkRoute: Codable, Sendable, Equatable {
    public var verdict: PrivacyVerdict
    public var method: AssessmentMethod
    public var ruleID: String?
    public var triageFailure: TriageFailure?

    public init(verdict: PrivacyVerdict, method: AssessmentMethod, ruleID: String? = nil,
                triageFailure: TriageFailure? = nil) {
        self.verdict = verdict; self.method = method; self.ruleID = ruleID; self.triageFailure = triageFailure
    }

    init(_ a: PrivacyAssessment) {
        self.init(verdict: a.verdict, method: a.method, ruleID: a.ruleID, triageFailure: a.triageFailure)
    }

    /// Cloud-eligible means the router would send this email to Gemini: verdict `.public`.
    public var cloudEligible: Bool { verdict == .public }
}

/// Privacy threshold and public-category floor for one evaluation.
public struct RoutingThresholds: Codable, Sendable, Equatable, Hashable {
    public var threshold: Double
    public var publicFloor: Double
    public init(threshold: Double, publicFloor: Double) { self.threshold = threshold; self.publicFloor = publicFloor }
    /// Defaults shipped in production: threshold 0.85, floor 0.85.
    public static let production = RoutingThresholds(threshold: DigestSettings.defaultPrivacyThreshold, publicFloor: SystemOneSpec.publicFloor)
}

/// One (fixture, model) result. `route` is the production route at the production thresholds.
public struct BenchmarkRecord: Codable, Sendable, Equatable {
    public var model: String
    public var fixtureID: String
    public var label: BenchmarkLabel
    public var category: String
    public var split: String
    public var inspection: ContentInspection
    public var preFilter: PreFilterResult
    /// `contains_pii_or_sensitive.noul`: P(sensitive).
    public var pSensitive: Double?
    public var categoryProbabilities: [String: Double]
    public var latencySeconds: Double?
    public var error: String?
    public var route: BenchmarkRoute
    public var stateLength: Int?
    public var rawResponse: String?

    public init(model: String, fixtureID: String, label: BenchmarkLabel, category: String, split: String,
                inspection: ContentInspection = .complete, preFilter: PreFilterResult, pSensitive: Double?,
                categoryProbabilities: [String: Double], latencySeconds: Double? = nil, error: String? = nil,
                route: BenchmarkRoute, stateLength: Int? = nil, rawResponse: String? = nil) {
        self.model = model; self.fixtureID = fixtureID; self.label = label; self.category = category
        self.split = split; self.inspection = inspection; self.preFilter = preFilter
        self.pSensitive = pSensitive; self.categoryProbabilities = categoryProbabilities
        self.latencySeconds = latencySeconds; self.error = error; self.route = route
        self.stateLength = stateLength; self.rawResponse = rawResponse
    }

    var pPublic: Double? { categoryProbabilities[SystemOneSpec.publicCategory] }
    var scores: SystemOneScores { SystemOneScores(noul: pSensitive, categoryProbabilities: categoryProbabilities) }
    var isInspectionOnly: Bool { category == BenchmarkFixtures.inspectionCategory }
}

// MARK: - Routing and classification

/// Production route replay and model-only classification.
public enum BenchmarkRouting {
    /// Replays recorded scores (or a recorded failure) as a System One client.
    private struct ReplayClient: SystemOneClient {
        var scores: SystemOneScores?
        var failure: TriageFailure?
        func preflight(model: String) async throws -> TriageFailure? { nil }
        func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores {
            if let failure { throw failure }
            return scores ?? SystemOneScores(noul: nil, categoryProbabilities: [:])
        }
    }

    private struct StubExtractor: EmailExtractor {
        func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool, today: Date,
                     timeZone: TimeZone) async throws -> ExtractionResult { throw CancellationError() }
    }

    private struct FixedClock: Clock {
        func now() -> Date { Date(timeIntervalSince1970: 0) }
    }

    /// The route `DigestRouter.assess` decides with cloud ON, a valid config, threshold 0.85 and floor 0.85.
    /// Runs the real router, so the pre-filter, inspection check and evaluator are production code.
    /// Pass `failure` when the triage call failed; `scores` when it succeeded.
    public static func productionRoute(email: EmailMessage, model: String, scores: SystemOneScores?,
                                       failure: TriageFailure?) async -> BenchmarkRoute {
        let config = CloudRoutingConfig(
            cloudExtractor: StubExtractor(), cloudModel: "gemini", offReason: nil,
            triage: ReplayClient(scores: scores, failure: failure), triageModel: model,
            privacyThreshold: RoutingThresholds.production.threshold)
        do {
            let a = try await DigestRouter(clock: FixedClock()).assess(email, stored: nil, config: config)
            return BenchmarkRoute(a)
        } catch {
            return BenchmarkRoute(verdict: .uncertain, method: .systemOne, triageFailure: .unreachable)
        }
    }

    /// The route at `thresholds`. `nil` returns the recorded production route. Otherwise only
    /// triage-path records (method `systemOne`, no error) are re-evaluated with `TriageEvaluator`;
    /// pre-filter and inspection decisions are deterministic and kept.
    public static func route(for record: BenchmarkRecord, thresholds: RoutingThresholds?) -> BenchmarkRoute {
        guard let t = thresholds, record.route.method == .systemOne, record.error == nil else { return record.route }
        let a = TriageEvaluator().evaluate(record.scores, model: record.model, threshold: t.threshold,
                                           publicFloor: t.publicFloor, assessedAt: Date(timeIntervalSince1970: 0))
        return BenchmarkRoute(a)
    }

    /// Model-only classification (System One on every fixture, ignoring the pre-filter), with
    /// `t` = privacy threshold, `floor` = public floor, pNon = 1 - pSensitive:
    /// - `public` if pNon >= t and pPublic >= floor
    /// - `private` if pSensitive >= 0.5, or (argmax category is not public_newsletter_or_promo and pNon < t)
    /// - otherwise `uncertain` (also when scores are missing or the call failed).
    public static func classifyModelOnly(_ r: BenchmarkRecord,
                                         thresholds: RoutingThresholds = .production) -> BenchmarkPrediction {
        guard r.error == nil, let ps = r.pSensitive, let pp = r.pPublic else { return .uncertain }
        let pNon = 1 - ps
        let eps = 1e-9
        if pNon + eps >= thresholds.threshold && pp + eps >= thresholds.publicFloor { return .public }
        let argmax = r.categoryProbabilities.max { $0.value < $1.value }?.key
        if ps >= 0.5 || (argmax != SystemOneSpec.publicCategory && pNon < thresholds.threshold) { return .private }
        return .uncertain
    }

    /// Wilson 95% upper bound for `x` events in `n` trials; 1 when `n` is 0.
    public static func wilsonUpper(_ x: Int, of n: Int, z: Double = 1.96) -> Double {
        guard n > 0 else { return 1 }
        let nn = Double(n), p = Double(x) / nn
        let centre = p + z * z / (2 * nn)
        let spread = z * (p * (1 - p) / nn + z * z / (4 * nn * nn)).squareRoot()
        return min(1, (centre + spread) / (1 + z * z / nn))
    }
}

// MARK: - Metrics

/// A listed item: false-cloud-eligible or false-local.
public struct BenchmarkItem: Codable, Sendable, Equatable {
    public var fixtureID: String
    public var category: String
    public var label: BenchmarkLabel
    public var pSensitive: Double?
    public var pPublic: Double?
    public var route: BenchmarkRoute
}

public struct CategoryAccuracy: Codable, Sendable, Equatable {
    public var category: String
    public var total: Int
    public var routingCorrect: Int
    public var rate: Double { total == 0 ? 0 : Double(routingCorrect) / Double(total) }
}

/// Metrics for one model on a set of records under one threshold pair.
///
/// Definitions (inspection-category items are excluded from everything except `inspectionItems*`):
/// - cloud-eligible: route verdict `.public`. Expected cloud: label `public` and inspection `complete`.
/// - falseCloudEligible: cloud-eligible and label is not public. falseLocal: label public, not cloud-eligible.
/// - routingCorrect: cloud-eligible exactly when label is public. strictCorrect: model-only prediction equals
///   truth (public, private, or ambiguous with uncertain). A private item predicted uncertain is wrong strictly
///   but right for routing ("correctly local").
/// - publicPrecision/Recall: positive = cloud-eligible (production route); truth positive = label public.
/// - sensitivePrecision/Recall: positive = model-only predicted private; truth positive = label private.
/// - falsePublic: model-only public, label not public. falsePrivate: model-only private, label public.
/// - privateLocalRate: share of label-private items not cloud-eligible. uncertaintyRate: model-only uncertain share.
/// - falseCloudRateWilsonUpper: Wilson 95% upper bound of falseCloudEligible / non-public items.
public struct BenchmarkMetrics: Codable, Sendable, Equatable {
    public var model: String
    public var thresholds: RoutingThresholds
    public var evaluated: Int
    public var publicCount: Int
    public var nonPublicCount: Int
    public var strictCorrect: Int
    public var routingCorrect: Int
    public var perCategory: [CategoryAccuracy]
    /// truth rawValue -> predicted rawValue -> count (model-only).
    public var confusion: [String: [String: Int]]
    public var publicPrecision: Double?
    public var publicRecall: Double?
    public var sensitivePrecision: Double?
    public var sensitiveRecall: Double?
    public var falsePublic: Int
    public var falsePrivate: Int
    public var falseCloudEligible: [BenchmarkItem]
    public var falseLocal: [BenchmarkItem]
    public var publicEligibilityRate: Double
    public var privateLocalRate: Double
    public var uncertaintyRate: Double
    public var localReasons: [String: Int]
    public var falseCloudRateWilsonUpper: Double
    public var inspectionItems: Int
    public var inspectionItemsEligible: Int

    public var strictAccuracy: Double { evaluated == 0 ? 0 : Double(strictCorrect) / Double(evaluated) }
    public var routingAccuracy: Double { evaluated == 0 ? 0 : Double(routingCorrect) / Double(evaluated) }
}

public enum BenchmarkScoring {
    /// Scores one model's records. `thresholds == nil` uses the recorded production route and the
    /// production thresholds for the model-only classifier.
    public static func metrics(_ records: [BenchmarkRecord], thresholds: RoutingThresholds? = nil) -> BenchmarkMetrics {
        let th = thresholds ?? .production
        let scored = records.filter { !$0.isInspectionOnly }
        let inspection = records.filter(\.isInspectionOnly)
        var strict = 0, routingOK = 0, falsePublic = 0, falsePrivate = 0, uncertain = 0
        var confusion: [String: [String: Int]] = [:]
        var cats: [String: (Int, Int)] = [:]
        var fc: [BenchmarkItem] = [], fl: [BenchmarkItem] = []
        var reasons: [String: Int] = [:]
        var eligibleTotal = 0, eligiblePublic = 0
        var predPrivate = 0, predPrivateTruePrivate = 0, truePrivate = 0, privateLocal = 0
        var publicCount = 0, nonPublic = 0

        for r in scored {
            let route = BenchmarkRouting.route(for: r, thresholds: thresholds)
            let pred = BenchmarkRouting.classifyModelOnly(r, thresholds: th)
            let eligible = route.cloudEligible
            let item = BenchmarkItem(fixtureID: r.fixtureID, category: r.category, label: r.label,
                                     pSensitive: r.pSensitive, pPublic: r.pPublic, route: route)
            confusion[r.label.rawValue, default: [:]][pred.rawValue, default: 0] += 1
            switch (r.label, pred) {
            case (.public, .public), (.private, .private), (.ambiguous, .uncertain): strict += 1
            default: break
            }
            if r.label == .public { publicCount += 1 } else { nonPublic += 1 }
            let ok = eligible == (r.label == .public && r.inspection == .complete)
            if ok { routingOK += 1 }
            var c = cats[r.category] ?? (0, 0)
            c.0 += 1; if ok { c.1 += 1 }
            cats[r.category] = c
            if pred == .public && r.label != .public { falsePublic += 1 }
            if pred == .private && r.label == .public { falsePrivate += 1 }
            if pred == .uncertain { uncertain += 1 }
            if eligible { eligibleTotal += 1 }
            if eligible && r.label != .public { fc.append(item) }
            if eligible && r.label == .public { eligiblePublic += 1 }
            if r.label == .public && r.inspection == .complete && !eligible { fl.append(item) }
            if pred == .private { predPrivate += 1; if r.label == .private { predPrivateTruePrivate += 1 } }
            if r.label == .private { truePrivate += 1; if !eligible { privateLocal += 1 } }
            if !eligible { reasons[localReason(route), default: 0] += 1 }
        }
        func ratio(_ a: Int, _ b: Int) -> Double? { b == 0 ? nil : Double(a) / Double(b) }
        let completePublic = scored.filter { $0.label == .public && $0.inspection == .complete }.count
        return BenchmarkMetrics(
            model: records.first?.model ?? "", thresholds: th, evaluated: scored.count,
            publicCount: publicCount, nonPublicCount: nonPublic, strictCorrect: strict, routingCorrect: routingOK,
            perCategory: cats.keys.sorted().map { CategoryAccuracy(category: $0, total: cats[$0]!.0, routingCorrect: cats[$0]!.1) },
            confusion: confusion,
            publicPrecision: ratio(eligiblePublic, eligibleTotal), publicRecall: ratio(eligiblePublic, completePublic),
            sensitivePrecision: ratio(predPrivateTruePrivate, predPrivate), sensitiveRecall: ratio(predPrivateTruePrivate, truePrivate),
            falsePublic: falsePublic, falsePrivate: falsePrivate, falseCloudEligible: fc, falseLocal: fl,
            publicEligibilityRate: ratio(eligiblePublic, completePublic) ?? 0,
            privateLocalRate: ratio(privateLocal, truePrivate) ?? 0,
            uncertaintyRate: ratio(uncertain, scored.count) ?? 0,
            localReasons: reasons,
            falseCloudRateWilsonUpper: BenchmarkRouting.wilsonUpper(fc.count, of: nonPublic),
            inspectionItems: inspection.count,
            inspectionItemsEligible: inspection.filter { BenchmarkRouting.route(for: $0, thresholds: thresholds).cloudEligible }.count)
    }

    /// Why a non-eligible route stayed local.
    public static func localReason(_ route: BenchmarkRoute) -> String {
        if route.triageFailure != nil { return "triage error" }
        switch route.method {
        case .rule: return "pre-filter private: \(route.ruleID ?? "?")"
        case .inspection: return "content not inspected"
        case .systemOne: return "System One below thresholds"
        default: return "other (\(route.method.rawValue))"
        }
    }

    /// Records of one split (`calibration` / `heldout`).
    public static func records(_ records: [BenchmarkRecord], split: String) -> [BenchmarkRecord] {
        records.filter { $0.split == split }
    }
}

// MARK: - Pre-filter evaluation

/// The deterministic pre-filter judged on its own over all fixtures.
public struct PreFilterEvaluation: Codable, Sendable, Equatable {
    public struct Hit: Codable, Sendable, Equatable {
        public var fixtureID: String
        public var category: String
        public var label: BenchmarkLabel
        public var ruleID: String?
    }
    /// label rawValue -> kind rawValue -> count.
    public var counts: [String: [String: Int]]
    /// Label public but the pre-filter said private (a lost cloud opportunity).
    public var falsePrivate: [Hit]
    /// Label not public but the pre-filter said public (safety failure).
    public var falsePublic: [Hit]

    public static func evaluate(_ fixtures: [BenchmarkFixture]) -> PreFilterEvaluation {
        let filter = PrivacyPreFilter()
        var counts: [String: [String: Int]] = [:]
        var fp: [Hit] = [], fpub: [Hit] = []
        for f in fixtures {
            let v = PreFilterResult(filter.classify(PrivacyInput(sender: f.from, subject: f.subject, body: f.body,
                                                                 headers: f.headers, inspection: f.inspection)))
            counts[f.label.rawValue, default: [:]][v.kind.rawValue, default: 0] += 1
            let hit = Hit(fixtureID: f.id, category: f.category, label: f.label, ruleID: v.ruleID)
            if f.label == .public && v.kind == .private { fp.append(hit) }
            if f.label != .public && v.kind == .public { fpub.append(hit) }
        }
        return PreFilterEvaluation(counts: counts, falsePrivate: fp, falsePublic: fpub)
    }
}

// MARK: - Threshold sweep

/// One swept configuration scored on the calibration split.
public struct SweepEntry: Codable, Sendable, Equatable {
    public var thresholds: RoutingThresholds
    public var falseCloudEligible: Int
    public var publicEligibilityRate: Double
}

/// Sweep outcome for one model. Chosen on calibration, evaluated on held-out.
///
/// Grid: privacy threshold 0.85...0.98 step 0.01 x public floor 0.70...0.95 step 0.05.
/// Gate: zero false-cloud-eligible on calibration. Choice: max public eligibility among passing configs,
/// ties to the higher threshold, then the higher floor.
public struct SweepOutcome: Codable, Sendable, Equatable {
    public var model: String
    public var entries: [SweepEntry]
    public var chosen: RoutingThresholds?
    /// Lowest-threshold config (ties: lowest floor) with at least one false-cloud on calibration.
    public var lowestThresholdWithFalseCloud: SweepEntry?
    /// Highest-threshold config (ties: highest floor) with at least one false-cloud: the safety boundary.
    public var highestThresholdWithFalseCloud: SweepEntry?
    public var calibrationProduction: BenchmarkMetrics
    public var heldoutProduction: BenchmarkMetrics
    public var heldoutChosen: BenchmarkMetrics?
}

public enum ThresholdSweep {
    public static let thresholds: [Double] = (85...98).map { Double($0) / 100 }
    public static let floors: [Double] = (14...19).map { Double($0) / 20 }

    public static func run(_ records: [BenchmarkRecord]) -> SweepOutcome {
        let cal = BenchmarkScoring.records(records, split: "calibration")
        let held = BenchmarkScoring.records(records, split: "heldout")
        var entries: [SweepEntry] = []
        for t in thresholds {
            for f in floors {
                let th = RoutingThresholds(threshold: t, publicFloor: f)
                let m = BenchmarkScoring.metrics(cal, thresholds: th)
                entries.append(SweepEntry(thresholds: th, falseCloudEligible: m.falseCloudEligible.count,
                                          publicEligibilityRate: m.publicEligibilityRate))
            }
        }
        let passing = entries.filter { $0.falseCloudEligible == 0 }
        let best = passing.max { a, b in
            if a.publicEligibilityRate != b.publicEligibilityRate { return a.publicEligibilityRate < b.publicEligibilityRate }
            if a.thresholds.threshold != b.thresholds.threshold { return a.thresholds.threshold < b.thresholds.threshold }
            return a.thresholds.publicFloor < b.thresholds.publicFloor
        }
        let failing = entries.filter { $0.falseCloudEligible > 0 }
        let lowest = failing.min { a, b in
            (a.thresholds.threshold, a.thresholds.publicFloor) < (b.thresholds.threshold, b.thresholds.publicFloor)
        }
        let highest = failing.max { a, b in
            (a.thresholds.threshold, a.thresholds.publicFloor) < (b.thresholds.threshold, b.thresholds.publicFloor)
        }
        return SweepOutcome(
            model: records.first?.model ?? "", entries: entries, chosen: best?.thresholds,
            lowestThresholdWithFalseCloud: lowest, highestThresholdWithFalseCloud: highest,
            calibrationProduction: BenchmarkScoring.metrics(cal),
            heldoutProduction: BenchmarkScoring.metrics(held),
            heldoutChosen: best.map { BenchmarkScoring.metrics(held, thresholds: $0.thresholds) })
    }
}
