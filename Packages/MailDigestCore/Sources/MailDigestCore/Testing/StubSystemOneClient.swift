import Foundation

/// Scriptable `SystemOneClient` for router tests. Records calls (state text included, so use synthetic data).
public actor StubSystemOneClient: SystemOneClient {
    public var preflightResult: TriageFailure?
    /// Results consumed in order; the last one repeats.
    public var results: [Result<SystemOneScores, TriageFailure>]
    public private(set) var preflightCalls: [String] = []
    public private(set) var assessCalls: [(input: TriageInput, model: String)] = []

    public init(preflightResult: TriageFailure? = nil,
                results: [Result<SystemOneScores, TriageFailure>] = []) {
        self.preflightResult = preflightResult
        self.results = results
    }

    public func preflight(model: String) async throws -> TriageFailure? {
        preflightCalls.append(model)
        return preflightResult
    }

    public func assess(_ input: TriageInput, model: String) async throws -> SystemOneScores {
        assessCalls.append((input, model))
        guard !results.isEmpty else { throw TriageFailure.malformedResponse }
        let r = assessCalls.count <= results.count ? results[assessCalls.count - 1] : results[results.count - 1]
        return try r.get()
    }
}
