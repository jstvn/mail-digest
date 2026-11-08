import Foundation
import Testing
@testable import MailDigestCore

struct RoutingBenchmarkTests {
    static let pub = SystemOneSpec.publicCategory

    /// Triage-path record: replays scores, route computed at production thresholds by a direct evaluator call.
    static func rec(_ id: String, label: BenchmarkLabel, pSens: Double, pPublic: Double, category: String = "public_newsletter",
                    split: String = "calibration", inspection: ContentInspection = .complete) -> BenchmarkRecord {
        let cats = [pub: pPublic, "personal_or_work_private": (1 - pPublic) / 2, "sensitive_transactional": (1 - pPublic) / 2]
        let a = TriageEvaluator().evaluate(SystemOneScores(noul: pSens, categoryProbabilities: cats), model: "m",
                                           threshold: 0.90, assessedAt: Date(timeIntervalSince1970: 0))
        return BenchmarkRecord(model: "m", fixtureID: id, label: label, category: category, split: split,
                               inspection: inspection, preFilter: PreFilterResult(kind: .needsTriage), pSensitive: pSens,
                               categoryProbabilities: cats, route: BenchmarkRoute(a))
    }

    @Test func wilsonUpperBound() {
        #expect(abs(BenchmarkRouting.wilsonUpper(0, of: 60) - 0.0602) < 0.001)
        #expect(BenchmarkRouting.wilsonUpper(0, of: 0) == 1)
        #expect(BenchmarkRouting.wilsonUpper(5, of: 10) > 0.5)
    }

    @Test func modelOnlyClassification() {
        #expect(BenchmarkRouting.classifyModelOnly(Self.rec("a", label: .public, pSens: 0.02, pPublic: 0.95)) == .public)
        #expect(BenchmarkRouting.classifyModelOnly(Self.rec("b", label: .private, pSens: 0.6, pPublic: 0.95)) == .private)
        // Low public share and not clearly non-sensitive -> private by argmax.
        #expect(BenchmarkRouting.classifyModelOnly(Self.rec("c", label: .private, pSens: 0.3, pPublic: 0.2)) == .private)
        // Public argmax but below the threshold -> uncertain.
        #expect(BenchmarkRouting.classifyModelOnly(Self.rec("d", label: .ambiguous, pSens: 0.3, pPublic: 0.9)) == .uncertain)
        var failed = Self.rec("e", label: .public, pSens: 0.01, pPublic: 0.99)
        failed.error = "timedOut"
        #expect(BenchmarkRouting.classifyModelOnly(failed) == .uncertain)
    }

    @Test func productionRouteUsesRealRouter() async {
        let good = SystemOneScores(noul: 0.02, categoryProbabilities: [Self.pub: 0.95])
        func email(subject: String, body: String, inspection: ContentInspection = .complete) -> EmailMessage {
            BenchmarkFixture(id: "x", split: "calibration", category: "c", label: .public, subject: subject,
                             from: "News <n@news.example>", body: body, inspection: inspection).email()
        }
        let ok = await BenchmarkRouting.productionRoute(email: email(subject: "Weekly digest", body: "Hello"), model: "m",
                                                        scores: good, failure: nil)
        #expect(ok.verdict == .public && ok.method == .systemOne)
        let rule = await BenchmarkRouting.productionRoute(email: email(subject: "Your invoice number 42", body: "Hello"), model: "m",
                                                          scores: good, failure: nil)
        #expect(rule.verdict == .private && rule.method == .rule && rule.ruleID == "kw.financial.record")
        let insp = await BenchmarkRouting.productionRoute(email: email(subject: "Hi", body: "Hello", inspection: .unknown),
                                                          model: "m", scores: good, failure: nil)
        #expect(insp.method == .inspection && !insp.cloudEligible)
        let bad = await BenchmarkRouting.productionRoute(email: email(subject: "Hi", body: "Hello"), model: "m",
                                                         scores: nil, failure: .timedOut)
        #expect(bad.verdict == .uncertain && bad.triageFailure == .timedOut)
    }

    @Test func metricsCountBothErrorDirections() {
        let records = [
            Self.rec("pub-ok", label: .public, pSens: 0.01, pPublic: 0.97),
            Self.rec("pub-low", label: .public, pSens: 0.2, pPublic: 0.97),        // false local
            Self.rec("priv-leak", label: .private, pSens: 0.05, pPublic: 0.96, category: "medical"), // false cloud
            Self.rec("priv-ok", label: .private, pSens: 0.9, pPublic: 0.1, category: "medical"),
            Self.rec("amb", label: .ambiguous, pSens: 0.4, pPublic: 0.5, category: "ambiguous"),
            // Excluded: inspection category, non-complete inspection, never false-local.
            Self.rec("insp", label: .public, pSens: 0.01, pPublic: 0.99, category: "inspection", inspection: .unknown),
        ]
        let m = BenchmarkScoring.metrics(records)
        #expect(m.evaluated == 5)
        #expect(m.falseCloudEligible.map(\.fixtureID) == ["priv-leak"])
        #expect(m.falseLocal.map(\.fixtureID) == ["pub-low"])
        #expect(m.publicEligibilityRate == 0.5)
        #expect(m.privateLocalRate == 0.5)
        #expect(m.publicPrecision == 0.5 && m.publicRecall == 0.5)
        #expect(m.falsePublic == 1)
        #expect(m.routingCorrect == 3)
        #expect(m.inspectionItems == 1)
        #expect(m.localReasons["System One below thresholds"] == 3)
        #expect(m.confusion["public"]?["public"] == 1)
        #expect(m.falseCloudRateWilsonUpper > 1.0 / 3)
    }

    @Test func triagePathRecomputedForSweepButRuleKept() {
        let loose = Self.rec("t", label: .public, pSens: 0.12, pPublic: 0.95)   // pNon 0.88: local at 0.90
        var rule = Self.rec("r", label: .private, pSens: 0.0, pPublic: 1.0)
        rule.route = BenchmarkRoute(verdict: .private, method: .rule, ruleID: "kw.tax")
        #expect(!loose.route.cloudEligible)
        #expect(BenchmarkRouting.route(for: loose, thresholds: .init(threshold: 0.85, publicFloor: 0.85)).cloudEligible)
        #expect(BenchmarkRouting.route(for: rule, thresholds: .init(threshold: 0.85, publicFloor: 0.70)).ruleID == "kw.tax")
    }

    @Test func sweepGateChoosesSafestMostEligible() {
        let cal = [
            Self.rec("p1", label: .public, pSens: 0.01, pPublic: 0.97),
            Self.rec("p2", label: .public, pSens: 0.12, pPublic: 0.95),
            Self.rec("leak", label: .private, pSens: 0.09, pPublic: 0.9, category: "medical"), // pNon 0.91
            Self.rec("h1", label: .public, pSens: 0.02, pPublic: 0.96, split: "heldout"),
        ]
        let out = ThresholdSweep.run(cal)
        // Leak (pPublic 0.90) is eligible for t <= 0.91 only with floor <= 0.90, so floor 0.95 is the safe way to
        // keep p2 (pNon 0.88): best passing config is the highest threshold that still admits p2.
        let chosen = try! #require(out.chosen)
        let m = BenchmarkScoring.metrics(BenchmarkScoring.records(cal, split: "calibration"), thresholds: chosen)
        #expect(m.falseCloudEligible.isEmpty)
        #expect(m.publicEligibilityRate == 1.0)
        #expect(chosen.threshold == 0.88 && chosen.publicFloor == 0.95)
        #expect(out.highestThresholdWithFalseCloud?.thresholds.threshold == 0.91)
        #expect(out.lowestThresholdWithFalseCloud?.thresholds.threshold == 0.85)
        #expect(out.heldoutChosen?.evaluated == 1)
    }

    @Test func preFilterEvaluationFindsFalseHits() {
        let fixtures = [
            BenchmarkFixture(id: "a", split: "heldout", category: "public_newsletter", label: .public, subject: "Your invoice number 42",
                             from: "N <n@x.example>", body: "Hello"),
            BenchmarkFixture(id: "b", split: "heldout", category: "public_with_sensitive", label: .private, subject: "Post",
                             from: "S <s@substack.com>", headers: ["List-Unsubscribe": "<https://x.example/u>"], body: "Hello"),
            BenchmarkFixture(id: "c", split: "heldout", category: "ambiguous", label: .ambiguous, subject: "Hi", from: "J <j@x.example>", body: "ok"),
        ]
        let e = PreFilterEvaluation.evaluate(fixtures)
        #expect(e.falsePrivate.map(\.fixtureID) == ["a"] && e.falsePrivate.first?.ruleID == "kw.financial.record")
        #expect(e.falsePublic.map(\.fixtureID) == ["b"])
        #expect(e.counts["ambiguous"]?["needsTriage"] == 1)
    }

    @Test func fixtureDecodingDefaultsAndValidation() throws {
        let json = #"[{"id":"n-1","split":"heldout","category":"public_newsletter","label":"public","difficulty":"easy","subject":"s","from":"A <a@b.example>","headers":{},"body":"b","note":"n"}]"#
        let f = try JSONDecoder().decode([BenchmarkFixture].self, from: Data(json.utf8))
        #expect(f[0].inspection == .complete)
        #expect(BenchmarkFixtures.validate(f).contains { $0.contains("expected 150") })
    }

    @Test func reportRendersWithoutCrashing() {
        let recs = [Self.rec("a", label: .public, pSens: 0.01, pPublic: 0.97),
                    Self.rec("b", label: .private, pSens: 0.05, pPublic: 0.96, category: "medical", split: "heldout")]
        let s = BenchmarkSummary.build(fixtures: [], recordsByModel: [("m", recs)])
        let md = BenchmarkReport.markdown(s)
        #expect(md.contains("False-cloud-eligible items (1)") && md.contains("## Model m"))
    }
}
