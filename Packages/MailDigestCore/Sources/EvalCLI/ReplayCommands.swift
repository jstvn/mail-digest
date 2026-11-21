import Foundation
import MailDigestCore

// Dev-only `systemone replay` and `systemone replay-report`. Reads the user's own Apple Mail files, talks only to
// a localhost Ollama, and writes a JSONL file outside the repository. Nothing here prints message content.

/// Cloud extractor present only so cloud counts as on; the assessment never calls it.
private struct NeverCalledCloud: EmailExtractor {
    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool, today: Date,
                 timeZone: TimeZone) async throws -> ExtractionResult { throw GeminiError.network }
}

private struct ReplayClock: Clock { func now() -> Date { Date(timeIntervalSince1970: 0) } }

/// Parser wired to CoreFoundation charsets on macOS, as the app does.
private func makeReplayParser() -> EmlxParser {
    #if canImport(Darwin)
    return EmlxParser(charsetDecoder: { bytes, charset in
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        guard !name.isEmpty else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
    })
    #else
    return EmlxParser()
    #endif
}

/// Existence only; fails closed (true) on any stat error other than not-found.
private func hasAttachmentsDirectory(messagesDir: URL, rowID: Int64) -> Bool {
    let dir = messagesDir.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
        .appendingPathComponent(String(rowID), isDirectory: true)
    var st = stat()
    return lstat(dir.path, &st) == 0 || (errno != ENOENT && errno != ENOTDIR)
}

private struct Candidate { var url: URL; var rowID: Int64; var isPartial: Bool; var modified: Date; var mailbox: String }

private func scan(_ root: URL, since: Date) -> [Candidate] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return [] }
    var found: [Candidate] = []
    let rootCount = root.standardizedFileURL.pathComponents.count
    for case let url as URL in walker {
        let comps = Array(url.standardizedFileURL.pathComponents.dropFirst(rootCount))
        if ReplayGuard.isExcluded(pathComponents: comps) { walker.skipDescendants(); continue }
        guard let file = ReplayGuard.messageFile(named: url.lastPathComponent),
              let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
              let modified = v.contentModificationDate, modified >= since else { continue }
        let mailbox = comps.first { $0.lowercased().hasSuffix(".mbox") }.map { String($0.dropLast(5)) } ?? ""
        found.append(Candidate(url: url, rowID: file.rowID, isPartial: file.isPartial, modified: modified, mailbox: mailbox))
    }
    // A full file wins over a partial sibling of the same row.
    let full = Set(found.filter { !$0.isPartial }.map { $0.url.deletingLastPathComponent().path + "/\($0.rowID)" })
    found = found.filter { $0.isPartial == false || !full.contains($0.url.deletingLastPathComponent().path + "/\($0.rowID)") }
    return found.sorted { $0.modified > $1.modified }
}

func replayCommand(_ opts: [String: [String]]) async {
    guard let mailDir = opts["mail-dir"]?.first, let model = opts["model"]?.first, let outPath = opts["out"]?.first,
          let tList = opts["thresholds"]?.first else {
        fail("replay needs --mail-dir, --model, --thresholds and --out\n\(usage)")
    }
    let thresholds = tList.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !thresholds.isEmpty, thresholds.count == tList.split(separator: ",").count,
          thresholds.allSatisfy({ SystemOneSpec.thresholdRange.contains($0) }) else {
        fail("--thresholds must be comma-separated values within \(SystemOneSpec.thresholdRange)")
    }
    guard let baseURL = URL(string: opts["base-url"]?.first ?? "http://localhost:11434"), ReplayGuard.isLocalhost(baseURL) else {
        fail("--base-url must be http(s) on localhost, 127.0.0.1 or ::1: mail never leaves this machine")
    }
    if let repo = ReplayGuard.enclosingRepository(of: outPath) {
        fail("--out is inside a git repository (\(repo)); the file holds subjects and sender names, pick a path outside it")
    }
    let sinceDays = opts["since-days"]?.first.flatMap(Int.init) ?? 14
    let limit = opts["limit"]?.first.flatMap(Int.init)
    guard sinceDays > 0, limit.map({ $0 > 0 }) ?? true else { fail("--since-days and --limit must be positive") }

    let client = OllamaSystemOneClient(baseURL: baseURL)
    do {
        if let failure = try await client.preflight(model: model) {
            fail("preflight failed for \(model): \(failure.rawValue)", code: 2)
        }
    } catch { fail("preflight error: \(error)", code: 2) }

    let root = URL(fileURLWithPath: mailDir)
    let candidates = scan(root, since: Date().addingTimeInterval(-Double(sinceDays) * 86_400))
    stderr("candidate files: \(candidates.count)")

    FileManager.default.createFile(atPath: outPath, contents: nil, attributes: [.posixPermissions: 0o600])
    guard let handle = FileHandle(forWritingAtPath: outPath) else { fail("cannot write \(outPath)") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let parser = makeReplayParser()
    let filter = MailFilter()
    let router = DigestRouter(clock: ReplayClock())
    let preFilter = PrivacyPreFilter()
    // The router runs at the lowest threshold: chunks it skips are non-public at every higher one too.
    let routerThreshold = thresholds.min()!
    var seen = Set<String>()
    var records: [ReplayRecord] = []
    var skipped: [String: Int] = [:]

    for c in candidates {
        if let limit, records.count >= limit { break }
        guard let data = try? Data(contentsOf: c.url) else { skipped["unreadable", default: 0] += 1; continue }
        guard case .usable(let parsed) = parser.parse(data) else { skipped["unusable", default: 0] += 1; continue }
        guard let messageID = parsed.messageID else { skipped["noMessageID", default: 0] += 1; continue }
        guard seen.insert(messageID).inserted else { skipped["duplicate", default: 0] += 1; continue }
        var inspection = parsed.inspection, gap = parsed.inspectionGap
        if c.isPartial {
            (inspection, gap) = PartialEmlxPolicy.verdict(
                for: parsed, hasAttachmentsDirectory: hasAttachmentsDirectory(
                    messagesDir: c.url.deletingLastPathComponent(), rowID: c.rowID))
        }
        let email = EmailMessage(
            id: messageID, account: "replay", mailbox: c.mailbox, sender: parsed.sender, subject: parsed.subject,
            receivedAt: parsed.dateHeader ?? c.modified, body: parsed.body, headers: parsed.filterHeaders,
            sourceReference: MailMessageReference(messageID: messageID, storeRowID: c.rowID),
            contentInspection: inspection, inspectionGap: gap,
            bimiIndicator: BIMIIndicator.headerValue(inRawHeaders: parsed.rawHeaderBlock))
        let tier = filter.tier(email)
        if tier == .skip { skipped["skipTier", default: 0] += 1; continue }

        let recorder = ReplayRecordingClient(base: client, clock: WallClock())
        let config = CloudRoutingConfig(cloudExtractor: NeverCalledCloud(), cloudModel: "gemini-replay", offReason: nil,
                                        triage: recorder, triageModel: model, privacyThreshold: routerThreshold)
        let assessment: PrivacyAssessment
        do { assessment = try await router.assess(email, stored: nil, config: config) }
        catch { fail("cancelled") }
        let chunks = await recorder.takeChunks()
        let total = assessment.triageCoverage?.totalChunks ?? 0
        let pre = PreFilterResult(preFilter.classify(PrivacyInput(
            sender: email.sender, subject: email.subject, body: email.body, headers: email.headers,
            inspection: email.contentInspection)))
        var routes: [String: ReplayRoute] = [:]
        for t in thresholds {
            routes[ReplayRouting.key(for: t)] = ReplayRouting.route(
                method: assessment.method, chunks: chunks, totalChunks: total, failure: assessment.triageFailure, threshold: t)
        }
        let record = ReplayRecord(
            hash: ReplayRouting.stableHash(messageID), senderName: ReplayRouting.displayName(from: email.sender),
            senderDomain: ReplayRouting.originalSenderDomain(from: email.sender, headers: email.headers),
            subject: email.subject, tier: tier, inspection: inspection, inspectionGap: gap,
            preFilterKind: pre.kind, preFilterRuleID: pre.ruleID, method: assessment.method,
            trigger: assessment.triageTrigger, riskSignal: assessment.riskSignal, totalChunks: total, chunks: chunks,
            failure: assessment.triageFailure, routes: routes)
        do { try handle.write(contentsOf: encoder.encode(record) + Data("\n".utf8)) } catch { fail("encode failed: \(error)") }
        records.append(record)
        if records.count % 10 == 0 { stderr("replayed \(records.count)") }
    }
    try? handle.close()
    stderr("wrote \(outPath) (\(records.count) emails); not replayed: "
           + (skipped.isEmpty ? "none" : skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
    print(ReplayAggregate.build(records).text())
}

func replayReportCommand(_ opts: [String: [String]]) {
    guard let path = opts["results"]?.first else { fail("replay-report needs --results\n\(usage)") }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read results at \(path)") }
    let decoder = JSONDecoder()
    let records: [ReplayRecord] = text.split(separator: "\n").map { line in
        do { return try decoder.decode(ReplayRecord.self, from: Data(line.utf8)) }
        catch { fail("invalid replay line in \(path): \(error)") }
    }
    print(ReplayAggregate.build(records).text())
}
