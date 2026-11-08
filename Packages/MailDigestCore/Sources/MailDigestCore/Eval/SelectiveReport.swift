import Foundation

// Scoring and Markdown for `systemone route-report`. Pure: reads SelectiveRecords (plus fixtures for the sender
// host) and optionally the original benchmark's records for the old-policy comparison.

/// A listed item (false-cloud, false-local, over-budget, evaluation failure).
public struct SelectiveItem: Codable, Sendable, Equatable {
    public var fixtureID: String
    public var scenario: String?
    public var label: BenchmarkLabel
    public var path: RoutingPath
    /// Risk signal id, else the triage trigger; never text.
    public var signal: String?
    /// Why the item stayed local (empty for eligible items).
    public var localReason: String
}

/// Metrics for one model on one group of fixtures. Definitions are in `SelectiveReportBuilder`.
public struct SelectiveGroupStats: Codable, Sendable, Equatable {
    public var name: String
    public var total: Int
    public var eligible: Int
    public var falseCloud: [SelectiveItem]
    public var falseLocal: [SelectiveItem]
    public var overBudget: [SelectiveItem]
    public var evaluationFailures: [SelectiveItem]
    public var publicEligibility: Double?
    public var privateLocalRate: Double?
    public var needsSystemOneRate: Double
    public var trustedTotal: Int
    public var trustedNeedingSystemOne: Int
    public var callsPerMessage: Double
    /// Number of System One calls (as text) to number of messages.
    public var chunkDistribution: [String: Int]
    public var perCallMedianSeconds: Double?
    public var perCallP95Seconds: Double?
    public var perMessageMedianSeconds: Double?
    public var perMessageP95Seconds: Double?
    public var inspectionExclusionRate: Double
    public var pathCounts: [String: Int]
    public var localReasons: [String: Int]
    public var cloudOffCounts: [String: Int]
    public var geminiFallbackCounts: [String: Int]
    public var callsPer100: Double
    public var measuredSecondsPer100: Double

    public var trustedNeedingRate: Double? {
        trustedTotal == 0 ? nil : Double(trustedNeedingSystemOne) / Double(trustedTotal)
    }
}

/// One row of the per-scenario table.
public struct SelectiveScenarioRow: Codable, Sendable, Equatable {
    public var scenario: String
    public var eligible: Int
    public var total: Int
    public var routes: [String: Int]
    public var falseCloud: Int
    public var falseLocal: Int
}

/// Modelled triage load per 100 emails. A model of triage time on a synthetic mix, not a measured Daily job.
public struct SelectiveDailyImpact: Codable, Sendable, Equatable {
    /// This run's median single-call latency; used for both policies.
    public var medianCallSeconds: Double?
    public var revisedCallsPer100Original: Double?
    public var oldCallsPer100Original: Double?
    public var revisedCallsPer100All: Double
    public var revisedMeasuredSecondsPer100All: Double
}

public struct SelectiveModelSummary: Codable, Sendable, Equatable {
    public var model: String
    /// Original 144 scored items, new scenarios, combined (in that order).
    public var groups: [SelectiveGroupStats]
    public var scenarios: [SelectiveScenarioRow]
    public var daily: SelectiveDailyImpact
}

public struct SelectiveSummary: Codable, Sendable, Equatable {
    public var models: [SelectiveModelSummary]
}

public enum SelectiveReportBuilder {
    public static let original = "original 144 scored items"
    public static let newScenarios = "new scenarios"
    public static let combined = "combined"

    /// - Parameters:
    ///   - fixtures: every fixture used by the runs (for the sender host).
    ///   - baseline: the original benchmark's records per model tag, when available.
    ///
    /// Definitions: cloud-eligible = the record's `cloudEligible`. False-cloud = eligible and label not public
    /// (ambiguous counts as non-public). False-local = not eligible, label public, excluding inspection-only,
    /// over-budget and evaluation-failure items, which are listed on their own. Public eligibility is
    /// eligible / public items with complete inspection, same exclusions. Trusted newsletters = allowlisted
    /// sender with complete inspection; "needing System One" = the path consults System One.
    public static func build(fixtures: [BenchmarkFixture], recordsByModel: [(String, [SelectiveRecord])],
                             baseline: [String: [BenchmarkRecord]] = [:]) -> SelectiveSummary {
        var byID: [String: BenchmarkFixture] = [:]
        for f in fixtures { byID[f.id] = f }
        let models = recordsByModel.map { model, recs -> SelectiveModelSummary in
            let orig = recs.filter { $0.scenario == nil && !$0.isInspectionLocal }
            let new = recs.filter { $0.scenario != nil }
            let groups = [stats(original, orig, byID), stats(newScenarios, new, byID), stats(combined, recs, byID)]
            let median = groups[2].perCallMedianSeconds
            let origStats = groups[0]
            var oldCalls: Double?
            if let old = baseline[model] {
                let scored = old.filter { !$0.isInspectionOnly }
                if !scored.isEmpty {
                    oldCalls = Double(scored.filter { $0.route.method == .systemOne }.count) / Double(scored.count) * 100
                }
            }
            return SelectiveModelSummary(
                model: model, groups: groups, scenarios: scenarioRows(recs),
                daily: SelectiveDailyImpact(
                    medianCallSeconds: median,
                    revisedCallsPer100Original: orig.isEmpty ? nil : origStats.callsPer100,
                    oldCallsPer100Original: oldCalls,
                    revisedCallsPer100All: groups[2].callsPer100,
                    revisedMeasuredSecondsPer100All: groups[2].measuredSecondsPer100))
        }
        return SelectiveSummary(models: models)
    }

    static func localReason(_ r: SelectiveRecord) -> String {
        if r.cloudEligible { return "" }
        if r.path == .inspectionLocal { return "inspection" }
        if r.path == .deterministicPrivate { return "deterministic private" }
        if r.triageFailure == .contentTooLong { return "too long" }
        if r.triageFailure != nil { return "triage failure" }
        if r.verdict == .private { return "sensitive" }
        if r.verdict == .uncertain { return "uncertain/below threshold" }
        return "other"
    }

    static func item(_ r: SelectiveRecord) -> SelectiveItem {
        SelectiveItem(fixtureID: r.fixtureID, scenario: r.scenario, label: r.label, path: r.path,
                      signal: r.riskSignal ?? r.trigger?.rawValue, localReason: localReason(r))
    }

    static func isAllowlisted(_ f: BenchmarkFixture?) -> Bool {
        guard let f, let host = PrivacyPreFilter.host(of: f.from) else { return false }
        return PrivacyPreFilter.publicHosts.contains { $0.host == host }
    }

    static func stats(_ name: String, _ recs: [SelectiveRecord], _ byID: [String: BenchmarkFixture]) -> SelectiveGroupStats {
        func rate(_ a: Int, _ b: Int) -> Double? { b == 0 ? nil : Double(a) / Double(b) }
        let n = recs.count
        let eligible = recs.filter(\.cloudEligible)
        let falseCloud = eligible.filter { $0.label != .public }.map(item)
        let excluded: (SelectiveRecord) -> Bool = { $0.isInspectionLocal || $0.isOverBudget || $0.isEvaluationFailure }
        let falseLocal = recs.filter { !$0.cloudEligible && $0.label == .public && !excluded($0) }.map(item)
        let publicScored = recs.filter { $0.label == .public && !excluded($0) }
        let privateRecs = recs.filter { $0.label == .private }
        let s1 = recs.filter { $0.path.usesSystemOne }
        let trusted = recs.filter { isAllowlisted(byID[$0.fixtureID]) && !$0.isInspectionLocal }
        let calls = recs.reduce(0) { $0 + $1.chunks.count }
        var dist: [String: Int] = [:]
        for r in recs { dist["\(r.chunks.count)", default: 0] += 1 }
        let callLat = recs.flatMap { $0.chunks.map(\.latencySeconds) }.sorted()
        let msgLat = recs.filter { !$0.chunks.isEmpty }.map(\.totalTriageSeconds).sorted()
        var paths: [String: Int] = [:], reasons: [String: Int] = [:], off: [String: Int] = [:], fb: [String: Int] = [:]
        for r in recs {
            paths[r.path.rawValue, default: 0] += 1
            if !r.cloudEligible { reasons[localReason(r), default: 0] += 1 }
            if let o = r.cloudOff { off["\(o.verdict.rawValue)/\(o.method.rawValue)", default: 0] += 1 }
            if let g = r.geminiFallback {
                fb["\(g.provider.rawValue)/\(g.localReason?.rawValue ?? "-")/\(g.cloudFailure ?? "-")", default: 0] += 1
            }
        }
        let per100 = n == 0 ? 0 : 100 / Double(n)
        return SelectiveGroupStats(
            name: name, total: n, eligible: eligible.count, falseCloud: falseCloud, falseLocal: falseLocal,
            overBudget: recs.filter(\.isOverBudget).map(item),
            evaluationFailures: recs.filter(\.isEvaluationFailure).map(item),
            publicEligibility: rate(publicScored.filter(\.cloudEligible).count, publicScored.count),
            privateLocalRate: rate(privateRecs.filter { !$0.cloudEligible }.count, privateRecs.count),
            needsSystemOneRate: rate(s1.count, n) ?? 0,
            trustedTotal: trusted.count, trustedNeedingSystemOne: trusted.filter { $0.path.usesSystemOne }.count,
            callsPerMessage: n == 0 ? 0 : Double(calls) / Double(n),
            chunkDistribution: dist,
            perCallMedianSeconds: percentile(callLat, 0.5), perCallP95Seconds: percentile(callLat, 0.95),
            perMessageMedianSeconds: percentile(msgLat, 0.5), perMessageP95Seconds: percentile(msgLat, 0.95),
            inspectionExclusionRate: rate(recs.filter { $0.path == .inspectionLocal }.count, n) ?? 0,
            pathCounts: paths, localReasons: reasons, cloudOffCounts: off, geminiFallbackCounts: fb,
            callsPer100: Double(calls) * per100,
            measuredSecondsPer100: recs.reduce(0) { $0 + $1.totalTriageSeconds } * per100)
    }

    static func scenarioRows(_ recs: [SelectiveRecord]) -> [SelectiveScenarioRow] {
        var groups: [String: [SelectiveRecord]] = [:]
        // Original fixtures have no scenario; they are grouped by their benchmark category.
        for r in recs { groups[r.scenario ?? "orig:\(r.category)", default: []].append(r) }
        return groups.keys.sorted().map { key in
            let g = groups[key]!
            var routes: [String: Int] = [:]
            for r in g { routes[r.path.rawValue, default: 0] += 1 }
            let excluded: (SelectiveRecord) -> Bool = { $0.isInspectionLocal || $0.isOverBudget || $0.isEvaluationFailure }
            return SelectiveScenarioRow(
                scenario: key, eligible: g.filter(\.cloudEligible).count, total: g.count, routes: routes,
                falseCloud: g.filter { $0.cloudEligible && $0.label != .public }.count,
                falseLocal: g.filter { !$0.cloudEligible && $0.label == .public && !excluded($0) }.count)
        }
    }

    /// Nearest-rank percentile of a sorted array (median uses the middle element, even counts average).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if p == 0.5 {
            let m = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2
        }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

/// Markdown rendering of a `SelectiveSummary`.
public enum SelectiveReport {
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
    static func sec(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
    static func kv(_ d: [String: Int]) -> String {
        d.isEmpty ? "none" : d.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
    static func list(_ items: [SelectiveItem]) -> String {
        items.isEmpty ? "  none\n" : items.map {
            "  - \($0.fixtureID) [\($0.scenario ?? "original"), label \($0.label.rawValue)] path \($0.path.rawValue)"
                + ($0.signal.map { ", signal \($0)" } ?? "") + ($0.localReason.isEmpty ? "" : ", reason \($0.localReason)") + "\n"
        }.joined()
    }

    public static func markdown(_ s: SelectiveSummary) -> String {
        var o = "# Selective-routing evaluation\n\n"
        o += "Real `DigestRouter.assess` (cloud on, threshold 0.90, floor 0.85) over synthetic fixtures. "
        o += "False-cloud counts `ambiguous` as non-public; false-local excludes ambiguous, inspection-only, over-budget "
        o += "and evaluation-failure items (those are reported separately).\n\n"
        for m in s.models {
            o += "## Model \(m.model)\n\n"
            for g in m.groups where g.total > 0 { o += groupSection(g) }
            o += "### Per scenario (combined)\n\n| Scenario | Eligible/total | Routes | False-cloud | False-local |\n|---|---|---|---|---|\n"
            for r in m.scenarios {
                o += "| \(r.scenario) | \(r.eligible)/\(r.total) | \(kv(r.routes)) | \(r.falseCloud) | \(r.falseLocal) |\n"
            }
            let d = m.daily
            o += "\n### Daily impact (a model of triage time on a synthetic mix, not a measured Daily job)\n\n"
            o += "Median single-call latency in this run: \(sec(d.medianCallSeconds)) s, used for both policies.\n\n"
            o += "| Policy | System One calls per 100 emails | Modelled seconds per 100 |\n|---|---|---|\n"
            func modelled(_ calls: Double?) -> String { calls.flatMap { c in d.medianCallSeconds.map { sec($0 * c) } } ?? "n/a" }
            o += "| Revised, original 144 items | \(d.revisedCallsPer100Original.map { String(format: "%.1f", $0) } ?? "n/a") | \(modelled(d.revisedCallsPer100Original)) |\n"
            o += "| Old (always System One), original 144 items | \(d.oldCallsPer100Original.map { String(format: "%.1f", $0) } ?? "n/a (no --baseline)") | \(modelled(d.oldCallsPer100Original)) |\n"
            o += "| Revised, all fixtures (calls) | \(String(format: "%.1f", d.revisedCallsPer100All)) | \(modelled(d.revisedCallsPer100All)) |\n"
            o += "| Revised, all fixtures (measured seconds) | \(String(format: "%.1f", d.revisedCallsPer100All)) | \(sec(d.revisedMeasuredSecondsPer100All)) |\n\n"
        }
        return o
    }

    static func groupSection(_ g: SelectiveGroupStats) -> String {
        var o = "### \(g.name) (\(g.total) items)\n\n"
        o += "- Cloud-eligible: \(g.eligible)/\(g.total)\n"
        o += "- False-cloud: \(g.falseCloud.count)\n" + list(g.falseCloud)
        o += "- False-local: \(g.falseLocal.count)\n" + list(g.falseLocal)
        o += "- Over budget (fail closed, own count): \(g.overBudget.count)\n" + list(g.overBudget)
        o += "- Evaluation failures (triage errors, own count): \(g.evaluationFailures.count)\n" + list(g.evaluationFailures)
        o += "- Public-email Gemini eligibility: \(pct(g.publicEligibility))\n"
        o += "- Private-email local-routing rate: \(pct(g.privateLocalRate))\n"
        o += "- Messages needing System One: \(pct(g.needsSystemOneRate))\n"
        o += "- Trusted newsletters needing System One: \(g.trustedNeedingSystemOne)/\(g.trustedTotal) (\(pct(g.trustedNeedingRate)))\n"
        o += "- System One calls per message: \(String(format: "%.2f", g.callsPerMessage))\n"
        o += "- Calls-per-message distribution (calls: messages): \(kv(g.chunkDistribution))\n"
        o += "- Per-call latency median / p95: \(sec(g.perCallMedianSeconds)) / \(sec(g.perCallP95Seconds)) s\n"
        o += "- Per-message latency median / p95: \(sec(g.perMessageMedianSeconds)) / \(sec(g.perMessageP95Seconds)) s\n"
        o += "- Inspection-exclusion rate: \(pct(g.inspectionExclusionRate))\n"
        o += "- Paths: \(kv(g.pathCounts))\n"
        o += "- Local reasons: \(kv(g.localReasons))\n"
        o += "- Cloud-off outcomes: \(kv(g.cloudOffCounts))\n"
        o += "- Gemini-fallback outcomes (eligible items, Gemini call failing): \(kv(g.geminiFallbackCounts))\n\n"
        return o
    }
}
