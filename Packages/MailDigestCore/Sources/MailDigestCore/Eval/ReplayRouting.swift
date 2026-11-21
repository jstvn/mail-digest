import Foundation

// Pure helpers for the dev-only `systemone replay` command (EvalCLI): replays the privacy routing on the
// user's own mail, locally. Records carry sender name/domain and subject for the user's own spot-check, so
// the output file must stay outside the repository (see `ReplayGuard`). They never carry body or evidence text.

/// Where an email would be processed under one threshold.
public enum ReplayRoute: String, Codable, Sendable, Equatable {
    case cloud, local
}

/// One System One call: the raw scores and the latency. No text.
public struct ReplayChunk: Codable, Sendable, Equatable {
    public var pSensitive: Double?
    public var categoryProbabilities: [String: Double]
    public var stateLength: Int
    public var latencySeconds: Double

    public init(pSensitive: Double?, categoryProbabilities: [String: Double], stateLength: Int, latencySeconds: Double) {
        self.pSensitive = pSensitive; self.categoryProbabilities = categoryProbabilities
        self.stateLength = stateLength; self.latencySeconds = latencySeconds
    }

    var scores: SystemOneScores { SystemOneScores(noul: pSensitive, categoryProbabilities: categoryProbabilities) }
}

/// One JSONL line of `systemone replay`. Contains the subject and sender name: keep the file private.
public struct ReplayRecord: Codable, Sendable, Equatable {
    public var hash: String
    public var senderName: String
    public var senderDomain: String
    public var subject: String
    public var tier: MailTier
    public var inspection: ContentInspection
    public var inspectionGap: InspectionGap?
    public var preFilterKind: PreFilterResult.Kind
    public var preFilterRuleID: String?
    public var method: AssessmentMethod
    public var trigger: TriageTrigger?
    public var riskSignal: String?
    public var totalChunks: Int
    public var chunks: [ReplayChunk]
    public var failure: TriageFailure?
    /// Keyed by `ReplayRouting.key(for:)`, for example "0.90".
    public var routes: [String: ReplayRoute]

    public init(hash: String, senderName: String, senderDomain: String, subject: String, tier: MailTier,
                inspection: ContentInspection, inspectionGap: InspectionGap?, preFilterKind: PreFilterResult.Kind,
                preFilterRuleID: String?, method: AssessmentMethod, trigger: TriageTrigger?, riskSignal: String?,
                totalChunks: Int, chunks: [ReplayChunk], failure: TriageFailure?, routes: [String: ReplayRoute]) {
        self.hash = hash; self.senderName = senderName; self.senderDomain = senderDomain; self.subject = subject
        self.tier = tier; self.inspection = inspection; self.inspectionGap = inspectionGap
        self.preFilterKind = preFilterKind; self.preFilterRuleID = preFilterRuleID; self.method = method
        self.trigger = trigger; self.riskSignal = riskSignal; self.totalChunks = totalChunks; self.chunks = chunks
        self.failure = failure; self.routes = routes
    }
}

public enum ReplayRouting {
    /// Stable dictionary key for a threshold, for example 0.9 -> "0.90".
    public static func key(for threshold: Double) -> String { String(format: "%.2f", threshold) }

    /// Re-derives the route under `threshold` from recorded scores, so System One is called once per chunk.
    /// The router is run at the lowest threshold; a chunk that is not public there is not public at a higher
    /// one, so the recorded chunks always suffice. Fails closed on any missing chunk or failure.
    public static func route(method: AssessmentMethod, chunks: [ReplayChunk], totalChunks: Int,
                             failure: TriageFailure?, threshold: Double,
                             publicFloor: Double = SystemOneSpec.publicFloor) -> ReplayRoute {
        switch method {
        case .trustedSender: return .cloud
        case .rule, .inspection, .cloudOff: return .local
        case .systemOne:
            guard failure == nil, totalChunks > 0, chunks.count == totalChunks else { return .local }
            let evaluator = TriageEvaluator()
            for c in chunks {
                let a = evaluator.evaluate(c.scores, model: "replay", threshold: threshold, publicFloor: publicFloor,
                                           assessedAt: Date(timeIntervalSince1970: 0))
                if a.verdict != .public { return .local }
            }
            return .cloud
        }
    }

    /// FNV-1a 64-bit of the Message-ID as 16 hex digits. Stable across runs and platforms; not reversible in practice.
    public static func stableHash(_ messageID: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in messageID.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    /// Display name of `from` ("Name <addr>"), without quotes; empty for a bare address.
    public static func displayName(from sender: String) -> String {
        guard let open = sender.lastIndex(of: "<") else { return "" }
        return sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
    }

    /// Domain of the original sender: the verified Hide My Email address when relayed, else the From domain.
    public static func originalSenderDomain(from sender: String, headers: [String: String]) -> String {
        let address = RelaySender.originalSender(from: sender, headers: headers) ?? MailFilter.address(from: sender)
        return address.split(separator: "@", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
    }
}

/// Safety checks for where the replay reads from and writes to.
public enum ReplayGuard {
    /// Mailboxes that are never replayed, matched case-insensitively on a path component.
    public static let excludedMailboxes: Set<String> = [
        "junk.mbox", "deleted messages.mbox", "sent messages.mbox", "drafts.mbox", "trash.mbox",
    ]

    public static func isExcluded(pathComponents: [String]) -> Bool {
        pathComponents.contains { excludedMailboxes.contains($0.lowercased()) }
    }

    /// `<rowid>.emlx` or `<rowid>.partial.emlx`; nil for any other name.
    public static func messageFile(named name: String) -> (rowID: Int64, isPartial: Bool)? {
        for (suffix, partial) in [(".partial.emlx", true), (".emlx", false)] where name.hasSuffix(suffix) {
            guard let id = Int64(name.dropLast(suffix.count)), id >= 0 else { return nil }
            return (id, partial)
        }
        return nil
    }

    /// Only the local machine is allowed: mail content must never leave it.
    public static func isLocalhost(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// True when `path` is, or lies inside, `directory` after resolving symlinks. A file that does not exist yet
    /// is resolved through its nearest existing ancestor.
    public static func isInside(_ path: String, directory: String) -> Bool {
        let p = resolve(path).pathComponents, d = resolve(directory).pathComponents
        return p.count >= d.count && Array(p.prefix(d.count)) == d
    }

    /// The nearest ancestor directory (of the resolved path) that holds a `.git` entry, or nil.
    public static func enclosingRepository(of path: String) -> String? {
        var url = resolve(path)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
        }
        return nil
    }

    static func resolve(_ path: String) -> URL {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        // Walk up to an existing ancestor so symlinks in it are resolved.
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for t in tail { resolved.appendPathComponent(t) }
        return resolved.standardizedFileURL
    }
}

/// Wraps a System One client and records the full scores and latency of every call (also failed ones).
public actor ReplayRecordingClient: SystemOneClient {
    private let base: any SystemOneClient
    private let clock: any Clock
    public private(set) var chunks: [ReplayChunk] = []

    public init(base: any SystemOneClient, clock: any Clock) { self.base = base; self.clock = clock }

    public func preflight(model: String) async throws -> TriageFailure? { try await base.preflight(model: model) }

    public func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores {
        let started = clock.now()
        do {
            let s = try await base.assess(input, model: model)
            chunks.append(ReplayChunk(pSensitive: s.noul, categoryProbabilities: s.categoryProbabilities,
                                      stateLength: input.state.count,
                                      latencySeconds: clock.now().timeIntervalSince(started)))
            return s
        } catch {
            chunks.append(ReplayChunk(pSensitive: nil, categoryProbabilities: [:], stateLength: input.state.count,
                                      latencySeconds: clock.now().timeIntervalSince(started)))
            throw error
        }
    }

    /// Returns the recorded chunks and clears them for the next email.
    public func takeChunks() -> [ReplayChunk] {
        defer { chunks = [] }
        return chunks
    }
}

/// Aggregate-only view of replay records: no subjects, names or domains.
public struct ReplayAggregate: Sendable, Equatable {
    public var total: Int
    /// Thresholds in descending order, as keys.
    public var thresholds: [String]
    public var routeCounts: [String: [String: Int]]
    public var byRule: [String: Int]
    public var byGap: [String: Int]
    public var byTrigger: [String: Int]
    public var byFailure: [String: Int]
    public var systemOneCalls: Int
    public var medianLatency: Double?
    public var p95Latency: Double?
    /// Hashes local at the highest threshold and cloud at the lowest.
    public var flips: [String]

    public static func build(_ records: [ReplayRecord]) -> ReplayAggregate {
        let keys = Set(records.flatMap { $0.routes.keys }).sorted(by: >)
        var routeCounts: [String: [String: Int]] = [:]
        for k in keys {
            for r in records { if let route = r.routes[k] { routeCounts[k, default: [:]][route.rawValue, default: 0] += 1 } }
        }
        func tally(_ f: (ReplayRecord) -> String?) -> [String: Int] {
            var out: [String: Int] = [:]
            for r in records { if let v = f(r) { out[v, default: 0] += 1 } }
            return out
        }
        let latencies = records.flatMap { $0.chunks.map(\.latencySeconds) }.sorted()
        var flips: [String] = []
        if let hi = keys.first, let lo = keys.last, hi != lo {
            flips = records.filter { $0.routes[hi] == .local && $0.routes[lo] == .cloud }.map(\.hash).sorted()
        }
        return ReplayAggregate(
            total: records.count, thresholds: keys, routeCounts: routeCounts,
            byRule: tally { $0.preFilterRuleID ?? "(none: \($0.preFilterKind.rawValue))" },
            byGap: tally { $0.inspectionGap?.rawValue ?? "(none)" },
            byTrigger: tally { $0.trigger?.rawValue ?? "(none)" },
            byFailure: tally { $0.failure?.rawValue },
            systemOneCalls: latencies.count,
            medianLatency: percentile(latencies, 0.5), p95Latency: percentile(latencies, 0.95), flips: flips)
    }

    /// Nearest-rank percentile of an ascending array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    /// Plain-text report; contains counts and hashes only.
    public func text() -> String {
        func block(_ title: String, _ d: [String: Int]) -> [String] {
            ["", title + ":"] + (d.isEmpty ? ["  (none)"] : d.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .map { "  \($0.key): \($0.value)" })
        }
        var lines = ["emails replayed: \(total)", "", "route by threshold:"]
        for k in thresholds {
            let c = routeCounts[k] ?? [:]
            lines.append("  \(k): cloud \(c["cloud"] ?? 0), local \(c["local"] ?? 0)")
        }
        lines += block("by pre-filter rule id", byRule)
        lines += block("by inspection gap", byGap)
        lines += block("by triage trigger", byTrigger)
        lines += block("by triage failure", byFailure)
        let f = { (v: Double?) in v.map { String(format: "%.2fs", $0) } ?? "n/a" }
        lines += ["", "System One calls: \(systemOneCalls), median \(f(medianLatency)), p95 \(f(p95Latency))"]
        if let hi = thresholds.first, let lo = thresholds.last, hi != lo {
            lines += ["", "flips local -> cloud (\(hi) -> \(lo)): \(flips.count)"] + flips.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
