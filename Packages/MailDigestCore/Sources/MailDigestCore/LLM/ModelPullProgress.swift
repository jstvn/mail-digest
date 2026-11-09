import Foundation

/// One decoded line of Ollama's `POST /api/pull` NDJSON stream.
public struct ModelPullEvent: Sendable, Equatable {
    public var status: String
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?
    /// Ollama's own message when the pull failed.
    public var error: String?

    public init(status: String = "", digest: String? = nil, total: Int64? = nil, completed: Int64? = nil, error: String? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
        self.error = error
    }

    /// Decodes one line; returns nil for blank, truncated or unrecognised lines so the caller can skip them.
    public static func decode(line: String) -> ModelPullEvent? {
        struct Wire: Decodable {
            var status: String?
            var digest: String?
            var total: Int64?
            var completed: Int64?
            var error: String?
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        // A line with none of the known fields is not a pull event.
        guard wire.status != nil || wire.error != nil else { return nil }
        return ModelPullEvent(status: wire.status ?? "", digest: wire.digest, total: wire.total,
                              completed: wire.completed, error: wire.error)
    }

    public var isSuccess: Bool { error == nil && status == "success" }
}

/// Sums layer progress by digest so the overall figure never moves backwards when a new layer starts.
public struct ModelPullProgress: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case inProgress
        case succeeded
        case failed(String)
    }

    private var totals: [String: Int64] = [:]
    private var completions: [String: Int64] = [:]
    public private(set) var outcome: Outcome = .inProgress
    /// Ollama's latest status text, such as "pulling manifest".
    public private(set) var status = ""

    public init() {}

    /// Total bytes across the layers seen so far; 0 until a layer reports a size.
    public var totalBytes: Int64 { totals.values.reduce(0, +) }
    public var completedBytes: Int64 { completions.values.reduce(0, +) }

    /// 0...1, or nil before any total is known.
    public var fraction: Double? {
        let total = totalBytes
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(total)))
    }

    public mutating func apply(_ event: ModelPullEvent) {
        if let error = event.error {
            outcome = .failed(error)
            return
        }
        status = event.status
        if event.isSuccess { outcome = .succeeded }
        guard let digest = event.digest, let total = event.total, total > 0 else { return }
        totals[digest] = max(totals[digest] ?? 0, total)
        let done = min(event.completed ?? 0, total)
        completions[digest] = max(completions[digest] ?? 0, done)
    }

    /// "1.2 GB of 2.5 GB · 48%", or "Preparing…" before a total is known.
    public var text: String {
        guard let fraction else { return "Preparing…" }
        let percent = Int((fraction * 100).rounded(.down))
        return "\(Self.bytes(completedBytes)) of \(Self.bytes(totalBytes)) · \(percent)%"
    }

    /// Decimal units, as Finder and Ollama show them. Pure arithmetic so it reads the same on Linux.
    static func bytes(_ count: Int64) -> String {
        let units: [(Double, String)] = [(1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        let value = Double(count)
        for (size, name) in units where value >= size {
            let scaled = value / size
            return String(format: scaled >= 100 || name == "KB" ? "%.0f %@" : "%.1f %@", scaled, name)
        }
        return "\(count) bytes"
    }
}
