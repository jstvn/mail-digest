import Foundation

/// Per-model results at production thresholds (all splits) plus the sweep.
public struct ModelSummary: Codable, Sendable, Equatable {
    public var model: String
    public var all: BenchmarkMetrics
    public var sweep: SweepOutcome
    public var medianLatencySeconds: Double?
    public var errorCount: Int
}

/// Everything the `report` command prints, also written as JSON.
public struct BenchmarkSummary: Codable, Sendable, Equatable {
    public var fixtureCount: Int
    public var preFilter: PreFilterEvaluation
    public var models: [ModelSummary]

    /// `recordsByModel` maps a model tag to its records (any order).
    public static func build(fixtures: [BenchmarkFixture], recordsByModel: [(String, [BenchmarkRecord])]) -> BenchmarkSummary {
        let models = recordsByModel.map { tag, recs -> ModelSummary in
            let lat = recs.compactMap(\.latencySeconds).sorted()
            return ModelSummary(model: tag, all: BenchmarkScoring.metrics(recs), sweep: ThresholdSweep.run(recs),
                                medianLatencySeconds: lat.isEmpty ? nil : lat[lat.count / 2],
                                errorCount: recs.filter { $0.error != nil }.count)
        }
        return BenchmarkSummary(fixtureCount: fixtures.count, preFilter: PreFilterEvaluation.evaluate(fixtures), models: models)
    }
}

/// Markdown rendering of a `BenchmarkSummary`.
public enum BenchmarkReport {
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
    static func num(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
    static func th(_ t: RoutingThresholds) -> String { String(format: "t=%.2f floor=%.2f", t.threshold, t.publicFloor) }

    public static func markdown(_ s: BenchmarkSummary) -> String {
        var o = "# System One routing benchmark\n\n"
        o += "Fixtures: \(s.fixtureCount). Production thresholds: \(th(.production)). "
        o += "Inspection-category items are excluded from model metrics.\n\n"
        o += preFilterSection(s.preFilter)
        o += "## Comparison (production thresholds, all splits)\n\n"
        o += "| Metric | " + s.models.map(\.model).joined(separator: " | ") + " |\n"
        o += "|---|" + s.models.map { _ in "---" }.joined(separator: "|") + "|\n"
        let rows: [(String, (ModelSummary) -> String)] = [
            ("Evaluated items", { "\($0.all.evaluated)" }),
            ("Strict accuracy (model-only)", { pct($0.all.strictAccuracy) }),
            ("Routing accuracy", { pct($0.all.routingAccuracy) }),
            ("False-cloud-eligible (route)", { "\($0.all.falseCloudEligible.count)" }),
            ("False-cloud Wilson 95% upper", { pct($0.all.falseCloudRateWilsonUpper) }),
            ("False-local (route)", { "\($0.all.falseLocal.count)" }),
            ("Public eligibility rate", { pct($0.all.publicEligibilityRate) }),
            ("Private items correctly local", { pct($0.all.privateLocalRate) }),
            ("Public precision / recall", { "\(num($0.all.publicPrecision)) / \(num($0.all.publicRecall))" }),
            ("Sensitive precision / recall", { "\(num($0.all.sensitivePrecision)) / \(num($0.all.sensitiveRecall))" }),
            ("False-public (model-only)", { "\($0.all.falsePublic)" }),
            ("False-private (model-only)", { "\($0.all.falsePrivate)" }),
            ("Uncertainty rate (model-only)", { pct($0.all.uncertaintyRate) }),
            ("Inspection items eligible (want 0)", { "\($0.all.inspectionItemsEligible)/\($0.all.inspectionItems)" }),
            ("Errors", { "\($0.errorCount)" }),
            ("Median latency (s, informal)", { num($0.medianLatencySeconds) }),
            ("Sweep choice (calibration)", { $0.sweep.chosen.map(th) ?? "none passes gate" }),
            ("Held-out: production false-cloud / eligibility", {
                "\($0.sweep.heldoutProduction.falseCloudEligible.count) / \(pct($0.sweep.heldoutProduction.publicEligibilityRate))" }),
            ("Held-out: chosen false-cloud / eligibility", {
                $0.sweep.heldoutChosen.map { "\($0.falseCloudEligible.count) / \(pct($0.publicEligibilityRate))" } ?? "n/a" }),
        ]
        for (name, f) in rows { o += "| \(name) | " + s.models.map(f).joined(separator: " | ") + " |\n" }
        o += "\n"
        for m in s.models { o += modelSection(m) }
        return o
    }

    static func preFilterSection(_ p: PreFilterEvaluation) -> String {
        var o = "## Pre-filter only (all fixtures)\n\n| Label | private | public | needsTriage |\n|---|---|---|---|\n"
        for l in BenchmarkLabel.allCases {
            let c = p.counts[l.rawValue] ?? [:]
            o += "| \(l.rawValue) | \(c["private"] ?? 0) | \(c["public"] ?? 0) | \(c["needsTriage"] ?? 0) |\n"
        }
        o += "\nFalse-private hits (label public, pre-filter private): \(p.falsePrivate.count)\n"
        for h in p.falsePrivate { o += "- \(h.fixtureID) (\(h.category)) rule \(h.ruleID ?? "?")\n" }
        o += "\nFalse-public hits (label not public, pre-filter public): \(p.falsePublic.count)\n"
        for h in p.falsePublic { o += "- \(h.fixtureID) (\(h.category)) label \(h.label.rawValue) rule \(h.ruleID ?? "?")\n" }
        return o + "\n"
    }

    static func items(_ items: [BenchmarkItem]) -> String {
        if items.isEmpty { return "none\n" }
        return items.map {
            "- \($0.fixtureID) [\($0.category), label \($0.label.rawValue)] pSens \(num($0.pSensitive)) pPublic \(num($0.pPublic)) "
                + "route \($0.route.verdict.rawValue)/\($0.route.method.rawValue)\($0.route.ruleID.map { "/\($0)" } ?? "")\n"
        }.joined()
    }

    static func modelSection(_ m: ModelSummary) -> String {
        let a = m.all
        var o = "## Model \(m.model)\n\n"
        o += "Confusion (model-only, truth x predicted):\n\n| truth | public | private | uncertain |\n|---|---|---|---|\n"
        for l in BenchmarkLabel.allCases {
            let c = a.confusion[l.rawValue] ?? [:]
            o += "| \(l.rawValue) | \(c["public"] ?? 0) | \(c["private"] ?? 0) | \(c["uncertain"] ?? 0) |\n"
        }
        o += "\nPer-category routing accuracy:\n\n| Category | Correct | Total | Rate |\n|---|---|---|---|\n"
        for c in a.perCategory { o += "| \(c.category) | \(c.routingCorrect) | \(c.total) | \(pct(c.rate)) |\n" }
        o += "\nLocal reasons (non-eligible items):\n"
        for (k, v) in a.localReasons.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            o += "- \(k): \(v)\n"
        }
        o += "\nFalse-cloud-eligible items (\(a.falseCloudEligible.count)):\n" + items(a.falseCloudEligible)
        o += "\nFalse-local items (\(a.falseLocal.count)):\n" + items(a.falseLocal)
        let sw = m.sweep
        o += "\nSweep (chosen on calibration, grid t 0.85-0.98 x floor 0.70-0.95):\n"
        o += "- chosen: \(sw.chosen.map(th) ?? "none passes the zero-false-cloud gate")\n"
        o += "- lowest-threshold config with a false-cloud: \(sw.lowestThresholdWithFalseCloud.map { th($0.thresholds) } ?? "none")\n"
        o += "- highest-threshold config with a false-cloud (safety boundary): \(sw.highestThresholdWithFalseCloud.map { th($0.thresholds) } ?? "none")\n"
        func line(_ label: String, _ x: BenchmarkMetrics?) -> String {
            guard let x else { return "- \(label): n/a\n" }
            return "- \(label) (\(th(x.thresholds))): false-cloud \(x.falseCloudEligible.count), false-local \(x.falseLocal.count), "
                + "eligibility \(pct(x.publicEligibilityRate)), routing accuracy \(pct(x.routingAccuracy))\n"
        }
        o += line("calibration, production", sw.calibrationProduction)
        o += line("held-out, production", sw.heldoutProduction)
        o += line("held-out, chosen", sw.heldoutChosen)
        if let h = sw.heldoutChosen, !h.falseCloudEligible.isEmpty {
            o += "\nHeld-out false-cloud items under the chosen config:\n" + items(h.falseCloudEligible)
        }
        return o + "\n"
    }
}
