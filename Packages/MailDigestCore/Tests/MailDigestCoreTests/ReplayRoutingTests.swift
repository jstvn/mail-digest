import XCTest
@testable import MailDigestCore

final class ReplayRoutingTests: XCTestCase {
    private func chunk(_ sens: Double?, pub: Double = 0.95) -> ReplayChunk {
        ReplayChunk(pSensitive: sens, categoryProbabilities: [SystemOneSpec.publicCategory: pub],
                    stateLength: 10, latencySeconds: 0.1)
    }

    func testThresholdRederivation() {
        // pNon = 0.88: local at 0.90, cloud at 0.85.
        let c = [chunk(0.12)]
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: c, totalChunks: 1, failure: nil, threshold: 0.90), .local)
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: c, totalChunks: 1, failure: nil, threshold: 0.85), .cloud)
    }

    func testPublicFloorStaysAndFailClosed() {
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: [chunk(0.01, pub: 0.80)], totalChunks: 1,
                                           failure: nil, threshold: 0.85), .local)
        // Missing chunk, failure, missing score.
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: [chunk(0.01)], totalChunks: 2, failure: nil, threshold: 0.85), .local)
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: [chunk(0.01)], totalChunks: 1, failure: .timedOut, threshold: 0.85), .local)
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: [chunk(nil)], totalChunks: 1, failure: nil, threshold: 0.85), .local)
        // Every chunk must pass.
        XCTAssertEqual(ReplayRouting.route(method: .systemOne, chunks: [chunk(0.01), chunk(0.12)], totalChunks: 2,
                                           failure: nil, threshold: 0.90), .local)
    }

    func testNonSystemOneMethods() {
        XCTAssertEqual(ReplayRouting.route(method: .trustedSender, chunks: [], totalChunks: 0, failure: nil, threshold: 0.9), .cloud)
        for m in [AssessmentMethod.rule, .inspection, .cloudOff] {
            XCTAssertEqual(ReplayRouting.route(method: m, chunks: [], totalChunks: 0, failure: nil, threshold: 0.9), .local)
        }
    }

    func testHashAndSenderParsing() {
        XCTAssertEqual(ReplayRouting.stableHash("abc@x"), ReplayRouting.stableHash("abc@x"))
        XCTAssertNotEqual(ReplayRouting.stableHash("a"), ReplayRouting.stableHash("b"))
        XCTAssertEqual(ReplayRouting.stableHash("a").count, 16)
        XCTAssertEqual(ReplayRouting.displayName(from: "\"Ann Lee\" <ann@example.com>"), "Ann Lee")
        XCTAssertEqual(ReplayRouting.displayName(from: "ann@example.com"), "")
        XCTAssertEqual(ReplayRouting.originalSenderDomain(from: "Ann <ann@example.com>", headers: [:]), "example.com")
        XCTAssertEqual(ReplayRouting.originalSenderDomain(
            from: "Shop <shop_at_store_com_abc123@icloud.com>", headers: ["X-ICLOUD-HME": "s=shop@store.com; m=x"]), "store.com")
    }

    func testGuards() {
        XCTAssertTrue(ReplayGuard.isExcluded(pathComponents: ["A", "JUNK.mbox", "x"]))
        XCTAssertFalse(ReplayGuard.isExcluded(pathComponents: ["A", "INBOX.mbox", "x"]))
        XCTAssertEqual(ReplayGuard.messageFile(named: "123.partial.emlx")?.isPartial, true)
        XCTAssertEqual(ReplayGuard.messageFile(named: "123.emlx")?.rowID, 123)
        XCTAssertNil(ReplayGuard.messageFile(named: "x.emlx"))
        XCTAssertTrue(ReplayGuard.isLocalhost(URL(string: "http://localhost:11434")!))
        XCTAssertTrue(ReplayGuard.isLocalhost(URL(string: "http://127.0.0.1:11434")!))
        XCTAssertTrue(ReplayGuard.isLocalhost(URL(string: "http://[::1]:11434")!))
        XCTAssertFalse(ReplayGuard.isLocalhost(URL(string: "http://example.com:11434")!))
        XCTAssertFalse(ReplayGuard.isLocalhost(URL(string: "http://localhost.evil.com")!))
    }

    func testPathInsideRepositoryResolvesSymlinks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo"), outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: outside.appendingPathComponent("link"), withDestinationURL: repo)
        defer { try? fm.removeItem(at: base) }
        XCTAssertNotNil(ReplayGuard.enclosingRepository(of: repo.appendingPathComponent("sub/out.jsonl").path))
        XCTAssertNotNil(ReplayGuard.enclosingRepository(of: outside.appendingPathComponent("link/out.jsonl").path))
        XCTAssertNil(ReplayGuard.enclosingRepository(of: outside.appendingPathComponent("out.jsonl").path))
        XCTAssertTrue(ReplayGuard.isInside(outside.appendingPathComponent("link/x").path, directory: repo.path))
    }

    func testAggregate() {
        func rec(_ h: String, _ r90: ReplayRoute, _ r85: ReplayRoute, rule: String? = nil, lat: [Double] = []) -> ReplayRecord {
            ReplayRecord(hash: h, senderName: "N", senderDomain: "d", subject: "S", tier: .full, inspection: .complete,
                         inspectionGap: nil, preFilterKind: .needsTriage, preFilterRuleID: rule, method: .systemOne,
                         trigger: .ambiguousSender, riskSignal: nil, totalChunks: 1,
                         chunks: lat.map { ReplayChunk(pSensitive: 0.1, categoryProbabilities: [:], stateLength: 1, latencySeconds: $0) },
                         failure: nil, routes: ["0.90": r90, "0.85": r85])
        }
        let agg = ReplayAggregate.build([rec("a", .local, .cloud, lat: [1, 2]), rec("b", .cloud, .cloud, lat: [3, 4]),
                                         rec("c", .local, .local, rule: "kw.otp")])
        XCTAssertEqual(agg.thresholds, ["0.90", "0.85"])
        XCTAssertEqual(agg.routeCounts["0.90"], ["local": 2, "cloud": 1])
        XCTAssertEqual(agg.routeCounts["0.85"], ["local": 1, "cloud": 2])
        XCTAssertEqual(agg.flips, ["a"])
        XCTAssertEqual(agg.systemOneCalls, 4)
        XCTAssertEqual(agg.medianLatency, 2)
        XCTAssertEqual(agg.p95Latency, 4)
        XCTAssertEqual(agg.byRule["kw.otp"], 1)
        XCTAssertFalse(agg.text().contains("S"+"ubject"))
    }
}
