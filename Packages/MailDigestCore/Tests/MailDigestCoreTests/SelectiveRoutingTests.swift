import Foundation
import Testing
@testable import MailDigestCore

/// A clock that advances 0.5 s on every read, so each recorded call takes exactly 0.5 s.
private final class TickClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        t += 0.5
        return Date(timeIntervalSince1970: t)
    }
}

private let pub = SystemOneSpec.publicCategory
private let goodScores = SystemOneScores(noul: 0.02, categoryProbabilities: [pub: 0.97, "personal_or_work_private": 0.02, "sensitive_transactional": 0.01])

private func loadRouting() throws -> [BenchmarkFixture] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("eval/systemone/fixtures-routing.json")
    return try JSONDecoder().decode([BenchmarkFixture].self, from: Data(contentsOf: url))
}

private func evaluate(_ f: BenchmarkFixture, client: StubSystemOneClient) async throws -> SelectiveRecord {
    try await SelectiveEvaluator.evaluate(f, model: "m", triage: client, clock: TickClock())
}

struct SelectiveRoutingTests {
    // MARK: Path derivation

    @Test func pathDerivationCoversEveryPath() {
        let at = Date(timeIntervalSince1970: 0)
        func a(_ m: AssessmentMethod, _ v: PrivacyVerdict, _ t: TriageTrigger? = nil) -> PrivacyAssessment {
            PrivacyAssessment(verdict: v, method: m, assessedAt: at, triageTrigger: t)
        }
        #expect(RoutingPath.derive(from: a(.trustedSender, .public)) == .trustedDirect)
        #expect(RoutingPath.derive(from: a(.systemOne, .public, .trustedSenderRisk)) == .trustedSelective)
        #expect(RoutingPath.derive(from: a(.systemOne, .uncertain, .ambiguousSender)) == .ambiguousSystemOne)
        #expect(RoutingPath.derive(from: a(.systemOne, .private, .sensitiveSender)) == .sensitiveSenderSystemOne)
        #expect(RoutingPath.derive(from: a(.rule, .private)) == .deterministicPrivate)
        #expect(RoutingPath.derive(from: a(.inspection, .notAssessed)) == .inspectionLocal)
        #expect(RoutingPath.derive(from: a(.cloudOff, .notAssessed)) == .other)
        #expect(RoutingPath.derive(from: a(.systemOne, .uncertain)) == .other)
        #expect(Set(RoutingPath.allCases.filter(\.usesSystemOne)) == [.trustedSelective, .ambiguousSystemOne, .sensitiveSenderSystemOne])
    }

    // MARK: Live-evaluation record shape (fake client)

    @Test func trustedDirectFixtureMakesNoCalls() async throws {
        let f = try #require(try loadRouting().first { $0.id == "rt-ord-01" })
        let client = StubSystemOneClient(results: [.success(goodScores)])
        let r = try await evaluate(f, client: client)
        #expect(r.path == .trustedDirect && r.cloudEligible && r.chunks.isEmpty && r.totalTriageSeconds == 0)
        #expect(await client.assessCalls.isEmpty)
        #expect(await client.preflightCalls.isEmpty)
        #expect(r.cloudOff == CloudOffOutcome(verdict: .public, method: .trustedSender))
        // The real router falls back to local after a failed Gemini call.
        #expect(r.geminiFallback == GeminiFallbackOutcome(provider: .local, cloudAttempted: true,
                                                          localReason: .cloudFailed, cloudFailure: "network"))
    }

    @Test func chunkedRecordHasOneEntryPerCall() async throws {
        let f = try #require(try loadRouting().first { $0.id == "rt-long-04" })
        let plan = TriageInputBuilder().plan(f.email())
        #expect(plan.isWithinBudget && plan.totalChunks > 1)
        let client = StubSystemOneClient(results: [.success(goodScores)])
        let r = try await evaluate(f, client: client)
        #expect(r.path == .ambiguousSystemOne && r.cloudEligible)
        #expect(r.chunks.count == plan.totalChunks)
        #expect(await client.assessCalls.count == plan.totalChunks)
        #expect(r.coverage == TriageCoverage(assessedChunks: plan.totalChunks, totalChunks: plan.totalChunks))
        #expect(r.chunks.allSatisfy { $0.latencySeconds == 0.5 && $0.pPublic == 0.97 && $0.pSensitive == 0.02 })
        #expect(r.totalTriageSeconds == 0.5 * Double(plan.totalChunks))
        #expect(r.geminiFallback?.cloudAttempted == true)
    }

    @Test func failedCallIsRecordedAsAChunkAndFailsClosed() async throws {
        let f = try #require(try loadRouting().first { $0.id == "rt-amb-01" })
        let client = StubSystemOneClient(results: [.failure(.timedOut)])
        let r = try await evaluate(f, client: client)
        #expect(r.chunks.count == 1 && r.chunks[0].pSensitive == nil)
        #expect(r.triageFailure == .timedOut && !r.cloudEligible && r.geminiFallback == nil)
        #expect(r.isEvaluationFailure && !r.isOverBudget)
        #expect(r.cloudOff == CloudOffOutcome(verdict: .notAssessed, method: .cloudOff))
    }

    @Test func recordRoundTripsWithoutTextFields() throws {
        let r = SelectiveRecord(model: "m", fixtureID: "x", label: .public, category: "c", scenario: "s", split: "selective",
                                inspection: .complete, path: .trustedSelective, verdict: .public, method: .systemOne,
                                trigger: .trustedSenderRisk, riskSignal: "risk.embedded.conversation",
                                coverage: TriageCoverage(assessedChunks: 1, totalChunks: 1),
                                chunks: [SelectiveChunk(pSensitive: 0.1, pPublic: 0.9, stateLength: 400, latencySeconds: 1.5)],
                                totalTriageSeconds: 1.5, cloudEligible: true)
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(SelectiveRecord.self, from: data) == r)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("rawResponse") && !keys.contains("body") && !keys.contains("subject"))
    }

    // MARK: Fixtures

    @Test func routingFixturesValidate() throws {
        let fixtures = try loadRouting()
        #expect(BenchmarkFixtures.validateRouting(fixtures) == [])
        #expect(Set(fixtures.map(\.id)).count == fixtures.count)
        for s in BenchmarkFixtures.routingScenarios {
            let n = fixtures.filter { $0.scenario == s }.count
            #expect(n >= (s == "long_over_budget" ? 1 : 5), "\(s) has \(n)")
        }
        #expect(fixtures.allSatisfy { $0.split == "selective" })
    }

    @Test func originalFixturesDecodeUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("eval/systemone/fixtures.json")
        let old = try JSONDecoder().decode([BenchmarkFixture].self, from: Data(contentsOf: url))
        #expect(old.count == 150 && old.allSatisfy { $0.scenario == nil })
        #expect(BenchmarkFixtures.validate(old) == [])
        #expect(!BenchmarkFixtures.validateRouting(old).isEmpty)
    }

    @Test func validateRoutingRejectsBadShapes() {
        let f = BenchmarkFixture(id: "a", split: "selective", category: "c", label: .public, subject: "s", from: "A <a@b.example>",
                                 body: String(repeating: "x", count: 200), scenario: "trusted_ordinary")
        let problems = BenchmarkFixtures.validateRouting([f, f])
        #expect(problems.contains("duplicate ids"))
        #expect(problems.contains { $0.hasPrefix("trusted_ordinary: expected at least 5") })
        var noScenario = f; noScenario.id = "b"; noScenario.scenario = nil
        #expect(BenchmarkFixtures.validateRouting([noScenario]).contains("b: missing or unknown scenario"))
    }

    // MARK: Real pre-filter over the fixtures

    @Test func realPreFilterPathsPerScenario() async throws {
        let fixtures = try loadRouting()
        let client = StubSystemOneClient(results: [.success(goodScores)])
        func paths(_ scenario: String) async throws -> [(String, RoutingPath)] {
            var out: [(String, RoutingPath)] = []
            for f in fixtures where f.scenario == scenario {
                out.append((f.id, try await evaluate(f, client: client).path))
            }
            return out
        }
        for s in ["trusted_ordinary", "trusted_tax_policy", "trusted_invoice_software"] {
            for (id, p) in try await paths(s) { #expect(p == .trustedDirect, "\(id) went \(p)") }
        }
        for s in ["identifiable_sensitive_newsletter", "trusted_embedded_private"] {
            for (id, p) in try await paths(s) { #expect(p == .trustedSelective || p == .deterministicPrivate, "\(id) went \(p)") }
        }
        for (id, p) in try await paths("uninspected_parts") { #expect(p == .inspectionLocal, "\(id) went \(p)") }
        let bulk = try await paths("bulk_sensitive_domain")
        #expect(bulk.filter { $0.1 == .sensitiveSenderSystemOne }.count == 3)
        #expect(bulk.filter { $0.1 == .deterministicPrivate }.count == 2)
    }

    @Test func overBudgetFixtureFailsClosed() async throws {
        let f = try #require(try loadRouting().first { $0.scenario == "long_over_budget" })
        let plan = TriageInputBuilder().plan(f.email())
        #expect(!plan.isWithinBudget && plan.totalChunks > TriageInputBuilder.maxChunks)
        let client = StubSystemOneClient(results: [.success(goodScores)])
        let r = try await evaluate(f, client: client)
        #expect(!r.cloudEligible && r.isOverBudget && r.chunks.isEmpty)
        #expect(await client.assessCalls.isEmpty)
        // Every long_message fixture must fit the budget, or its result would say nothing about the text.
        for lm in try loadRouting() where lm.scenario == "long_message" {
            #expect(TriageInputBuilder().plan(lm.email()).isWithinBudget, "\(lm.id)")
        }
    }

    @Test func sensitiveDetailInLongMessagesIsBeyondFirstWindow() throws {
        let fixtures = try loadRouting().filter { $0.scenario == "long_message" && $0.label == .private }
        #expect(fixtures.count == 3)
        for f in fixtures {
            let prepared = PrivacyAssessmentText.prepare(body: f.body)
            let markers = ["motor neurone", "lymphoma", "antidepressants"]
            let i = markers.compactMap { prepared.range(of: $0)?.lowerBound }.first
            #expect(i != nil && prepared.distance(from: prepared.startIndex, to: i!) > 1_500, "\(f.id)")
        }
    }
}

// MARK: - Report maths

struct SelectiveReportTests {
    private func fixture(_ id: String, from: String) -> BenchmarkFixture {
        BenchmarkFixture(id: id, split: "selective", category: "c", label: .public, subject: "s", from: from, body: "b")
    }

    private func rec(_ id: String, _ label: BenchmarkLabel, _ path: RoutingPath, eligible: Bool, scenario: String? = nil,
                     inspection: ContentInspection = .complete, failure: TriageFailure? = nil,
                     lat: [Double] = [], verdict: PrivacyVerdict? = nil) -> SelectiveRecord {
        SelectiveRecord(model: "m", fixtureID: id, label: label, category: "c", scenario: scenario, split: "selective",
                        inspection: inspection, path: path, verdict: verdict ?? (eligible ? .public : .uncertain),
                        method: path == .trustedDirect ? .trustedSender : .systemOne, triageFailure: failure,
                        chunks: lat.map { SelectiveChunk(pSensitive: 0.1, pPublic: 0.9, stateLength: 10, latencySeconds: $0) },
                        totalTriageSeconds: lat.reduce(0, +), cloudEligible: eligible)
    }

    private var records: [SelectiveRecord] {
        [
            rec("a", .public, .trustedDirect, eligible: true),                                   // original, allowlisted
            rec("b", .public, .trustedSelective, eligible: true, scenario: "s1", lat: [2, 4]),   // new, allowlisted, 2 calls
            rec("c", .private, .ambiguousSystemOne, eligible: true, lat: [1]),                   // false cloud
            rec("d", .public, .ambiguousSystemOne, eligible: false, lat: [3]),                   // false local
            rec("e", .public, .inspectionLocal, eligible: false, scenario: "s2", inspection: .unknown, verdict: .notAssessed),
            rec("f", .public, .ambiguousSystemOne, eligible: false, scenario: "s3", failure: .contentTooLong),
            rec("g", .public, .ambiguousSystemOne, eligible: false, scenario: "s3", failure: .timedOut, lat: [5]),
            rec("h", .private, .deterministicPrivate, eligible: false, verdict: .private),
        ]
    }

    private var summary: SelectiveModelSummary {
        let fixtures = [fixture("a", from: "A <a@substack.com>"), fixture("b", from: "B <b@medium.com>"),
                        fixture("c", from: "C <c@c.example>")]
        var base = [RoutingBenchmarkTests.rec("o1", label: .public, pSens: 0.01, pPublic: 0.97),
                    RoutingBenchmarkTests.rec("o2", label: .public, pSens: 0.01, pPublic: 0.97),
                    RoutingBenchmarkTests.rec("o3", label: .private, pSens: 0.9, pPublic: 0.1),
                    RoutingBenchmarkTests.rec("o4", label: .private, pSens: 0.9, pPublic: 0.1)]
        base[3].route = BenchmarkRoute(verdict: .private, method: .rule, ruleID: "kw.otp")
        return SelectiveReportBuilder.build(fixtures: fixtures, recordsByModel: [("m", records)], baseline: ["m": base]).models[0]
    }

    @Test func combinedMathSeparatesErrorKinds() {
        let g = summary.groups[2]
        #expect(g.name == "combined" && g.total == 8 && g.eligible == 3)
        #expect(g.falseCloud.map(\.fixtureID) == ["c"])
        #expect(g.falseLocal.map(\.fixtureID) == ["d"])
        #expect(g.overBudget.map(\.fixtureID) == ["f"])
        #expect(g.evaluationFailures.map(\.fixtureID) == ["g"])
        // a, b, d are the scored public items; two are eligible.
        #expect(abs((g.publicEligibility ?? 0) - 2.0 / 3.0) < 1e-9)
        #expect(g.privateLocalRate == 0.5)
        #expect(g.inspectionExclusionRate == 1.0 / 8.0)
        #expect(g.trustedTotal == 2 && g.trustedNeedingSystemOne == 1 && g.trustedNeedingRate == 0.5)
        #expect(abs(g.needsSystemOneRate - 5.0 / 8.0) < 1e-9)   // b, c, d, f, g
        #expect(g.callsPerMessage == 5.0 / 8.0)
        #expect(g.chunkDistribution == ["0": 4, "1": 3, "2": 1])
        #expect(g.perCallMedianSeconds == 3 && g.perCallP95Seconds == 5)
        #expect(g.perMessageMedianSeconds == 4)   // messages with calls: 1, 3, 5, 6 -> (3 + 5) / 2
        #expect(g.localReasons["inspection"] == 1 && g.localReasons["too long"] == 1 && g.localReasons["triage failure"] == 1)
        #expect(g.localReasons["uncertain/below threshold"] == 1 && g.localReasons["deterministic private"] == 1)
    }

    @Test func groupsSplitOriginalFromNewScenarios() {
        let s = summary
        #expect(s.groups[0].name == "original 144 scored items" && s.groups[0].total == 4)
        #expect(s.groups[0].falseCloud.map(\.fixtureID) == ["c"] && s.groups[0].falseLocal.map(\.fixtureID) == ["d"])
        #expect(s.groups[1].name == "new scenarios" && s.groups[1].total == 4)
        #expect(s.groups[1].falseCloud.isEmpty && s.groups[1].falseLocal.isEmpty)
        #expect(s.groups[1].inspectionExclusionRate == 0.25)
        #expect(s.scenarios.contains { $0.scenario == "s3" && $0.total == 2 && $0.eligible == 0 && $0.falseLocal == 0 })
    }

    @Test func dailyImpactModelsBothPolicies() {
        let d = summary.daily
        #expect(d.medianCallSeconds == 3)
        #expect(d.revisedCallsPer100Original == 50)    // c and d make one call each over 4 original items
        #expect(d.oldCallsPer100Original == 75)         // 3 of 4 baseline records used System One
        #expect(d.revisedCallsPer100All == 62.5)
        #expect(d.revisedMeasuredSecondsPer100All == 15.0 / 8.0 * 100)
        let md = SelectiveReport.markdown(SelectiveSummary(models: [summary]))
        #expect(md.contains("not a measured Daily job") && md.contains("Evaluation failures") && md.contains("original 144 scored items"))
    }

    @Test func percentilesAreNearestRank() {
        #expect(SelectiveReportBuilder.percentile([], 0.5) == nil)
        #expect(SelectiveReportBuilder.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(SelectiveReportBuilder.percentile(Array(1...20).map(Double.init), 0.95) == 19)
    }
}
