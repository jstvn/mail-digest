import Foundation

/// Whether Apple's on-device Foundation Models can run on this Mac (Q100).
public enum FoundationModelsAvailability: Sendable, Equatable {
    case available
    case unavailable(FoundationModelsUnavailableReason)
}

/// Why Foundation Models can't run. The first two are things the user can fix.
public enum FoundationModelsUnavailableReason: Sendable, Equatable {
    /// The Mac's hardware can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is switched off in System Settings.
    case appleIntelligenceNotEnabled
    /// The on-device model is still downloading or preparing.
    case modelNotReady
    /// macOS is older than 26 (or the framework is missing), as on Intel Macs and macOS 15.
    case unsupportedOS
    /// Any other reason the system reports.
    case other
}

/// What this Mac can do, supplied by an app adapter. Pure data so Core can decide what to offer (Q100).
public struct HostPlatform: Sendable, Equatable {
    public var isAppleSilicon: Bool
    public var foundationModels: FoundationModelsAvailability

    public init(isAppleSilicon: Bool, foundationModels: FoundationModelsAvailability) {
        self.isAppleSilicon = isAppleSilicon
        self.foundationModels = foundationModels
    }

    /// An Intel Mac: no MLX models, no Foundation Models.
    public static let intel = HostPlatform(isAppleSilicon: false, foundationModels: .unavailable(.unsupportedOS))
    /// Apple silicon with Foundation Models ready.
    public static let appleSiliconReady = HostPlatform(isAppleSilicon: true, foundationModels: .available)

    /// True when Foundation Models can run right now.
    public var canUseFoundationModels: Bool { foundationModels == .available }

    /// Whether Settings shows the Foundation Models choice: on Apple silicon, when it works or the user can
    /// fix it. Hidden on Intel, older macOS and ineligible devices.
    public var showsFoundationModelsChoice: Bool {
        guard isAppleSilicon else { return false }
        switch foundationModels {
        case .available: return true
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled, .modelNotReady, .other: return true
            case .deviceNotEligible, .unsupportedOS: return false
            }
        }
    }

    /// Short reason the choice is unavailable, or nil when it is available.
    public var unavailableExplanation: String? {
        guard case .unavailable(let reason) = foundationModels else { return nil }
        switch reason {
        case .deviceNotEligible: return "This Mac doesn\u{2019}t support Apple Intelligence."
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use this option."
        case .modelNotReady: return "The Apple Intelligence model is still downloading. Try again later."
        case .unsupportedOS: return "Apple Intelligence needs macOS 26 or later."
        case .other: return "Apple Intelligence isn\u{2019}t available right now."
        }
    }
}

/// Which engine runs the local digest model (Q100).
public enum LocalProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case ollama
    case appleFoundationModels

    /// Unknown stored values fall back to Ollama.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LocalProvider(rawValue: raw) ?? .ollama
    }
}

/// Body size limit for Foundation Models, whose context is 4,096 tokens shared by instructions, the
/// email and the answer (Q100). Only this provider truncates; Ollama keeps Q35's no-truncation rule.
public struct FoundationModelsBudget: Sendable, Equatable {
    /// The body budget. The extraction instructions take roughly 600 tokens and the answer up to about
    /// 500, leaving roughly 2,500 for the body; at 3 to 4 characters per token (less for non-English text)
    /// 4,000 characters is a conservative fit.
    public static let defaultBodyCharacters = 4_000
    /// Never shrink below this on retry.
    public static let minimumBodyCharacters = 500
    /// Marker EmailCleaner also appends.
    public static let truncationMarker = EmailCleaner.truncationMarker

    public var bodyCharacters: Int

    public init(bodyCharacters: Int = FoundationModelsBudget.defaultBodyCharacters) {
        self.bodyCharacters = max(Self.minimumBodyCharacters, bodyCharacters)
    }

    /// Half the budget, for the one retry after a context overflow.
    public func halved() -> FoundationModelsBudget {
        FoundationModelsBudget(bodyCharacters: bodyCharacters / 2)
    }

    /// Cuts an already cleaned body to the budget at a line or word boundary and appends the marker.
    /// A body within the budget is returned unchanged.
    public func truncate(_ body: String) -> String {
        guard body.count > bodyCharacters else { return body }
        let head = String(body.prefix(bodyCharacters))
        var cut = head
        // Prefer a line break, then a space, as long as that keeps at least half the budget.
        if let i = head.lastIndex(where: { $0 == "\n" }), head.distance(from: head.startIndex, to: i) >= bodyCharacters / 2 {
            cut = String(head[..<i])
        } else if let i = head.lastIndex(where: { $0 == " " }),
                  head.distance(from: head.startIndex, to: i) >= bodyCharacters / 2 {
            cut = String(head[..<i])
        }
        let trimmed = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + "\n" + Self.truncationMarker
    }
}

/// Platform-aware model suggestions (Q100).
extension DigestSettings {
    /// Digest models the picker suggests: the default, plus the MLX build on Apple silicon (Q100).
    public static func suggestedDigestModels(for platform: HostPlatform) -> [String] {
        platform.isAppleSilicon ? [defaultModel, mlxDigestModel] : [defaultModel]
    }

    /// Qwen3.5 4B as an MLX build; only suggested on Apple silicon.
    public static let mlxDigestModel = "qwen3.5:4b-mlx"

    /// The id recorded as the local model when Apple Intelligence runs the digest (no Ollama tag exists).
    public static let appleFoundationModelID = "apple-foundation-model"

    /// The local model to record and show: the Ollama tag, or Apple's model for that provider.
    public var resolvedLocalModel: String {
        localProvider == .appleFoundationModels ? Self.appleFoundationModelID : resolvedModel
    }
}

/// Instructions and user message for one model call, shared by every provider.
public struct PromptPair: Sendable, Equatable {
    public var system: String
    public var user: String
}

extension ExtractionResult {
    /// Applies the rules every provider shares after decoding: an info-only email never has tasks.
    public func applyingTierRules(tier: MailTier) -> ExtractionResult {
        var r = self
        if tier == .infoOnly { r.tasks = [] }
        return r
    }
}

/// How ready Ollama is for the digest model (Q92). Evaluated in the order the user would fix things.
public enum OllamaSetupState: Sendable, Equatable {
    case notInstalled
    case notRunning
    case versionTooOld(installed: String)
    case modelMissing(String)
    case ready

    /// - Parameters:
    ///   - isAppInstalled: whether the Ollama app exists on this Mac (supplied by the app).
    ///   - reachable: whether the server answered.
    ///   - version: the server version, if known.
    ///   - installedTags: the tags from `/api/tags`, if known.
    public static func evaluate(isAppInstalled: Bool, reachable: Bool, version: String?, installedTags: [String]?,
                                requiredModel: String,
                                minimumVersion: [Int] = SystemOneSpec.minimumOllamaVersion) -> OllamaSetupState {
        guard reachable else { return isAppInstalled ? .notRunning : .notInstalled }
        if let version, let parts = OllamaSystemOneClient.parseVersion(version),
           parts.lexicographicallyPrecedes(minimumVersion) {
            return .versionTooOld(installed: version)
        }
        guard let installedTags, OllamaClient.isInstalled(requiredModel, in: installedTags) else {
            return .modelMissing(requiredModel)
        }
        return .ready
    }
}
