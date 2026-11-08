import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MailDigestCore

// Thin CLI around the benchmark types in MailDigestCore (Eval/). Usage:
//   EvalCLI systemone validate --fixtures <path>
//   EvalCLI systemone run --fixtures <path> --model <tag> --out <path.jsonl> [--base-url URL] [--limit N]
//   EvalCLI systemone report --fixtures <path> --results <a.jsonl> [<b.jsonl> ...] [--json <path>]
//   EvalCLI systemone route --fixtures <A.json> [<B.json>] --model <tag> --out <F.jsonl> [--base-url URL] [--limit N]
//   EvalCLI systemone route-report --fixtures <A.json> [<B.json>] --results <a.jsonl> ... [--baseline <dir>] [--json <path>]

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fail(_ message: String, code: Int32 = 1) -> Never {
    stderr("EvalCLI: \(message)")
    exit(code)
}

let usage = """
usage:
  EvalCLI systemone validate --fixtures <path> [--routing] [--verbose]
  EvalCLI systemone run --fixtures <path> --model <tag> --out <path.jsonl> [--base-url URL] [--limit N]
  EvalCLI systemone report --fixtures <path> --results <a.jsonl> [<b.jsonl> ...] [--json <path>]
  EvalCLI systemone route --fixtures <A.json> [<B.json>] --model <tag> --out <F.jsonl> [--base-url URL] [--limit N]
  EvalCLI systemone route-report --fixtures <A.json> [<B.json>] --results <a.jsonl> ... [--baseline <dir>] [--json <path>]
"""

/// `--key value [value ...]` pairs; a key collects every following non-flag argument.
func parseOptions(_ args: [String]) -> [String: [String]] {
    var out: [String: [String]] = [:]
    var key: String?
    for a in args {
        if a.hasPrefix("--") { key = String(a.dropFirst(2)); out[key!, default: []] = [] }
        else if let k = key { out[k, default: []].append(a) }
    }
    return out
}

func loadFixtures(_ path: String) -> [BenchmarkFixture] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read fixtures at \(path)") }
    do { return try JSONDecoder().decode([BenchmarkFixture].self, from: data) }
    catch { fail("invalid fixtures JSON: \(error)") }
}

func loadRecords(_ path: String) -> [BenchmarkRecord] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read results at \(path)") }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
        do { return try decoder.decode(BenchmarkRecord.self, from: Data(line.utf8)) }
        catch { fail("invalid result line in \(path): \(error)") }
    }
}

func printCounts(_ fixtures: [BenchmarkFixture], verbose: Bool = false) -> Bool {
    print("fixtures: \(fixtures.count), unique ids: \(Set(fixtures.map(\.id)).count)")
    for cat in BenchmarkFixtures.categories + [BenchmarkFixtures.inspectionCategory] {
        let c = fixtures.filter { $0.category == cat }
        let long = c.filter { $0.body.count > 1_500 }.count
        print("  \(cat): calibration \(c.filter { $0.split == "calibration" }.count), heldout \(c.filter { $0.split == "heldout" }.count), "
              + "easy \(c.filter { $0.difficulty == "easy" }.count), hard \(c.filter { $0.difficulty == "hard" }.count), body>1500 \(long)")
    }
    let pre = PreFilterEvaluation.evaluate(fixtures)
    for l in BenchmarkLabel.allCases {
        let c = pre.counts[l.rawValue] ?? [:]
        print("  pre-filter, label \(l.rawValue): private \(c["private"] ?? 0), public \(c["public"] ?? 0), needsTriage \(c["needsTriage"] ?? 0)")
    }
    pre.falsePrivate.forEach { print("  pre-filter false-private: \($0.fixtureID) \($0.ruleID ?? "?")") }
    pre.falsePublic.forEach { print("  pre-filter false-public: \($0.fixtureID) \($0.ruleID ?? "?")") }
    if verbose {
        for f in fixtures {
            let v = PreFilterResult(PrivacyPreFilter().classify(PrivacyInput(sender: f.from, subject: f.subject, body: f.body,
                                                                             headers: f.headers, inspection: f.inspection)))
            print("  \(f.id) [\(f.label.rawValue)] pre-filter \(v.kind.rawValue) \(v.ruleID ?? "")")
        }
    }
    let problems = BenchmarkFixtures.validate(fixtures)
    problems.forEach { print("PROBLEM: \($0)") }
    print(problems.isEmpty ? "OK" : "INVALID")
    return problems.isEmpty
}

/// Prints counts and the pre-filter's decision per scenario for `fixtures-routing.json`.
func printRoutingCounts(_ fixtures: [BenchmarkFixture], verbose: Bool) -> Bool {
    print("fixtures: \(fixtures.count), unique ids: \(Set(fixtures.map(\.id)).count)")
    let filter = PrivacyPreFilter()
    for s in BenchmarkFixtures.routingScenarios {
        let items = fixtures.filter { $0.scenario == s }
        var kinds: [String: Int] = [:]
        for f in items {
            let v = PreFilterResult(filter.classify(PrivacyInput(sender: f.from, subject: f.subject, body: f.body,
                                                                 headers: f.headers, inspection: f.inspection)))
            kinds[v.kind.rawValue, default: 0] += 1
            if verbose { print("  \(f.id) [\(f.label.rawValue)] \(v.kind.rawValue) \(v.ruleID ?? "") len \(f.body.count)") }
        }
        let labels = BenchmarkLabel.allCases.map { l in "\(l.rawValue) \(items.filter { $0.label == l }.count)" }.joined(separator: ", ")
        print("  \(s): \(items.count) (\(labels)); pre-filter \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    }
    let problems = BenchmarkFixtures.validateRouting(fixtures)
    problems.forEach { print("PROBLEM: \($0)") }
    print(problems.isEmpty ? "OK" : "INVALID")
    return problems.isEmpty
}

/// POSTs JSON and returns the body and status code. Completion-handler based so it also builds on Linux.
func post(_ url: URL, body: Data, timeout: TimeInterval) async throws -> (Data, Int) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    request.httpBody = body
    return try await withCheckedThrowingContinuation { cont in
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { cont.resume(throwing: error) }
            else if let data, let http = response as? HTTPURLResponse { cont.resume(returning: (data, http.statusCode)) }
            else { cont.resume(throwing: URLError(.badServerResponse)) }
        }.resume()
    }
}

func runCommand(_ opts: [String: [String]]) async {
    guard let fixturesPath = opts["fixtures"]?.first, let model = opts["model"]?.first, let outPath = opts["out"]?.first else {
        fail("run needs --fixtures, --model and --out\n\(usage)")
    }
    let baseURL = URL(string: opts["base-url"]?.first ?? "http://localhost:11434")!
    var fixtures = loadFixtures(fixturesPath)
    if let l = opts["limit"]?.first, let n = Int(l) { fixtures = Array(fixtures.prefix(n)) }

    let client = OllamaSystemOneClient(baseURL: baseURL)
    do {
        if let failure = try await client.preflight(model: model) {
            fail("preflight failed for \(model): \(failure.rawValue). Install the model first (this tool never pulls or falls back).", code: 2)
        }
    } catch { fail("preflight error: \(error)", code: 2) }

    FileManager.default.createFile(atPath: outPath, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: outPath) else { fail("cannot write \(outPath)") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let url = baseURL.appendingPathComponent("v1/systemone")
    let preFilter = PrivacyPreFilter()

    for (i, f) in fixtures.enumerated() {
        // The raw email goes to the router; TriageInputBuilder cleans the body itself (as in DigestPipeline).
        let email = f.email()
        // Stage 3 replaces this with chunked assessment; until then only the first planned input is sent.
        let input = TriageInputBuilder().plan(email).inputs.first ?? TriageInput(state: "")
        var scores: SystemOneScores?
        var failure: TriageFailure?
        var errorText: String?
        var raw: String?
        let started = Date()
        do {
            let payload = try OllamaSystemOneClient.requestBody(input, model: model).stableData()
            let (data, status) = try await post(url, body: payload, timeout: 90)
            raw = String(data: data, encoding: .utf8)
            if (200..<300).contains(status) {
                do { scores = try OllamaSystemOneClient.decode(data) }
                catch { failure = .malformedResponse; errorText = "malformedResponse" }
            } else {
                failure = status == 404 ? .modelMissing : .httpError
                errorText = "http \(status)"
            }
        } catch let e as URLError where e.code == .timedOut {
            failure = .timedOut; errorText = "timedOut"
        } catch {
            failure = .unreachable; errorText = "\(error)"
        }
        let latency = Date().timeIntervalSince(started)
        let route = await BenchmarkRouting.productionRoute(email: email, model: model, scores: scores, failure: failure)
        let verdict = preFilter.classify(PrivacyInput(sender: f.from, subject: f.subject, body: f.body,
                                                      headers: f.headers, inspection: f.inspection))
        let record = BenchmarkRecord(
            model: model, fixtureID: f.id, label: f.label, category: f.category, split: f.split, inspection: f.inspection,
            preFilter: PreFilterResult(verdict), pSensitive: scores?.noul,
            categoryProbabilities: scores?.categoryProbabilities ?? [:], latencySeconds: latency, error: errorText,
            route: route, stateLength: input.state.count, rawResponse: raw)
        do { handle.write(try encoder.encode(record) + Data("\n".utf8)) } catch { fail("encode failed: \(error)") }
        stderr("[\(i + 1)/\(fixtures.count)] \(f.id) \(route.verdict.rawValue)/\(route.method.rawValue) \(String(format: "%.2fs", latency))\(errorText.map { " ERROR \($0)" } ?? "")")
    }
    try? handle.close()
    stderr("wrote \(outPath)")
}

func reportCommand(_ opts: [String: [String]]) {
    guard let fixturesPath = opts["fixtures"]?.first, let results = opts["results"], !results.isEmpty else {
        fail("report needs --fixtures and --results\n\(usage)")
    }
    let fixtures = loadFixtures(fixturesPath)
    let byModel: [(String, [BenchmarkRecord])] = results.map { path in
        let recs = loadRecords(path)
        guard let model = recs.first?.model else { fail("no records in \(path)") }
        return (model, recs)
    }
    let summary = BenchmarkSummary.build(fixtures: fixtures, recordsByModel: byModel)
    print(BenchmarkReport.markdown(summary))
    if let jsonPath = opts["json"]?.first {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(summary).write(to: URL(fileURLWithPath: jsonPath)) } catch { fail("cannot write JSON: \(error)") }
    }
}

/// Wall-clock time for latency measurement (the eval harness injects the clock; tests use a fake).
struct WallClock: Clock {
    func now() -> Date { Date() }
}

/// GETs a URL; completion-handler based so it also builds on Linux.
func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    return try await withCheckedThrowingContinuation { cont in
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { cont.resume(throwing: error) }
            else if let data, (response as? HTTPURLResponse)?.statusCode == 200 { cont.resume(returning: data) }
            else { cont.resume(throwing: URLError(.badServerResponse)) }
        }.resume()
    }
}

/// The digest of the installed tag, from `/api/tags`; nil when the tag is not listed.
func modelDigest(baseURL: URL, model: String) async throws -> String? {
    struct Tags: Decodable { struct M: Decodable { var name: String; var digest: String? }; var models: [M] }
    let data = try await get(baseURL.appendingPathComponent("api/tags"), timeout: 10)
    let tags = try JSONDecoder().decode(Tags.self, from: data)
    let wanted: Set<String> = model.contains(":") ? [model] : [model, model + ":latest"]
    return tags.models.first { wanted.contains($0.name) }?.digest
}

/// Loads one or more fixture files in order.
func loadAllFixtures(_ paths: [String]) -> [BenchmarkFixture] { paths.flatMap(loadFixtures) }

func routeCommand(_ opts: [String: [String]]) async {
    guard let paths = opts["fixtures"], !paths.isEmpty, let model = opts["model"]?.first, let outPath = opts["out"]?.first else {
        fail("route needs --fixtures, --model and --out\n\(usage)")
    }
    let baseURL = URL(string: opts["base-url"]?.first ?? "http://localhost:11434")!
    var fixtures = loadAllFixtures(paths)
    if let l = opts["limit"]?.first, let n = Int(l) { fixtures = Array(fixtures.prefix(n)) }

    let client = OllamaSystemOneClient(baseURL: baseURL)
    do {
        if let failure = try await client.preflight(model: model) {
            fail("preflight failed for \(model): \(failure.rawValue). Install the model first (this tool never pulls or falls back).", code: 2)
        }
    } catch { fail("preflight error: \(error)", code: 2) }
    var digest: String?
    do { digest = try await modelDigest(baseURL: baseURL, model: model) } catch { fail("cannot read /api/tags: \(error)", code: 2) }
    stderr("model \(model) digest \(digest ?? "unknown")")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let meta = SelectiveRunMeta(model: model, modelDigest: digest, baseURL: baseURL.absoluteString,
                                threshold: RoutingThresholds.production.threshold,
                                publicFloor: RoutingThresholds.production.publicFloor,
                                fixtureFiles: paths.map { ($0 as NSString).lastPathComponent },
                                fixtureCount: fixtures.count, startedAt: Date())
    let metaPath = (outPath as NSString).deletingPathExtension + ".meta.json"
    do { try encoder.encode(meta).write(to: URL(fileURLWithPath: metaPath)) } catch { fail("cannot write \(metaPath): \(error)") }
    FileManager.default.createFile(atPath: outPath, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: outPath) else { fail("cannot write \(outPath)") }

    for (i, f) in fixtures.enumerated() {
        let started = Date()
        do {
            let r = try await SelectiveEvaluator.evaluate(f, model: model, triage: client, clock: WallClock())
            try handle.write(contentsOf: encoder.encode(r) + Data("\n".utf8))
            stderr("[\(i + 1)/\(fixtures.count)] \(f.id) \(r.path.rawValue) \(r.verdict.rawValue)/\(r.method.rawValue) "
                   + "calls \(r.chunks.count) \(String(format: "%.2fs", Date().timeIntervalSince(started)))"
                   + (r.triageFailure.map { " FAILURE \($0.rawValue)" } ?? ""))
        } catch { fail("fixture \(f.id) failed: \(error)") }
    }
    try? handle.close()
    stderr("wrote \(outPath) and \(metaPath)")
}

func loadSelectiveRecords(_ path: String) -> [SelectiveRecord] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read results at \(path)") }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").map { line in
        do { return try decoder.decode(SelectiveRecord.self, from: Data(line.utf8)) }
        catch { fail("invalid route result line in \(path): \(error)") }
    }
}

func routeReportCommand(_ opts: [String: [String]]) {
    guard let paths = opts["fixtures"], !paths.isEmpty, let results = opts["results"], !results.isEmpty else {
        fail("route-report needs --fixtures and --results\n\(usage)")
    }
    let fixtures = loadAllFixtures(paths)
    let byModel: [(String, [SelectiveRecord])] = results.map { path in
        let recs = loadSelectiveRecords(path)
        guard let model = recs.first?.model else { fail("no records in \(path)") }
        return (model, recs)
    }
    var baseline: [String: [BenchmarkRecord]] = [:]
    if let dir = opts["baseline"]?.first {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".jsonl") } ?? []
        for file in files.sorted() {
            let recs = loadRecords((dir as NSString).appendingPathComponent(file))
            if let m = recs.first?.model { baseline[m] = recs }
        }
    }
    let summary = SelectiveReportBuilder.build(fixtures: fixtures, recordsByModel: byModel, baseline: baseline)
    print(SelectiveReport.markdown(summary))
    if let jsonPath = opts["json"]?.first {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(summary).write(to: URL(fileURLWithPath: jsonPath)) } catch { fail("cannot write JSON: \(error)") }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args[0] == "systemone" else { fail(usage) }
let options = parseOptions(Array(args.dropFirst(2)))
switch args[1] {
case "validate":
    guard let p = options["fixtures"]?.first else { fail("validate needs --fixtures") }
    if options["routing"] != nil { exit(printRoutingCounts(loadFixtures(p), verbose: options["verbose"] != nil) ? 0 : 1) }
    exit(printCounts(loadFixtures(p), verbose: options["verbose"] != nil) ? 0 : 1)
case "run": await runCommand(options)
case "report": reportCommand(options)
case "route": await routeCommand(options)
case "route-report": routeReportCommand(options)
default: fail(usage)
}
