import Foundation
import MailDigestCore

/// Builds the per-email `CloudRoutingConfig` from the live settings and the Keychain key. The key and the
/// clients are cached in memory (the Keychain is read once, not per email); the System One client is
/// recreated per job so its preflight runs once per job.
actor CloudRoutingProvider {
    private let credentials: any CredentialStore
    private let snapshot: @Sendable @MainActor () -> DigestSettings
    private var apiKey: String?
    private var keyLoaded = false
    private var gemini: (key: String, model: String, client: GeminiClient)?
    private var systemOne: (url: URL, client: OllamaSystemOneClient)?
    private let claudeDetector: ClaudeCodeDetector
    /// Claude Code readiness, detected once per job (Q93). Cleared when a job starts.
    private var claudeDetection: Task<ClaudeCodeDetection, Never>?

    init(credentials: any CredentialStore, claudeDetector: ClaudeCodeDetector = ClaudeCodeDetector(),
         snapshot: @escaping @Sendable @MainActor () -> DigestSettings) {
        self.credentials = credentials
        self.claudeDetector = claudeDetector
        self.snapshot = snapshot
    }

    /// Call when a job starts or resumes: drops the System One client and re-reads the key.
    func resetForNewJob() {
        systemOne = nil
        claudeDetection?.cancel()
        claudeDetection = nil
        invalidateCredential()
    }

    /// Call after the key is saved or removed.
    func invalidateCredential() {
        keyLoaded = false
        apiKey = nil
        gemini = nil
    }

    func config() async -> CloudRoutingConfig {
        let settings = await snapshot()
        // No provider chosen: stay local without touching the Keychain or probing Claude Code.
        guard let provider = settings.cloudProvider else {
            return .localOnly(reason: settings.cloudDigestEnabled ? .noProvider : .cloudDisabled)
        }
        // Only Gemini needs the key; reading it for Claude Code would just risk a Keychain prompt.
        if provider == .gemini, !keyLoaded {
            // A Keychain failure counts as no credential: fail closed, keep everything local.
            apiKey = (try? credentials.read()) ?? nil
            keyLoaded = true
        }
        let key = provider == .gemini ? apiKey : nil
        // Master switch and acknowledgement first, so Claude Code is never probed while cloud is off.
        if let reason = CloudPrivacyPolicy.offReason(settings: settings, hasGeminiKey: key != nil, claudeCode: .ready) {
            return .localOnly(reason: reason)
        }
        let extractor: any EmailExtractor
        let model: String
        switch provider {
        case .gemini:
            guard let key else { return .localOnly(reason: .noCredential) }
            model = settings.resolvedGeminiModel
            let client: GeminiClient
            if let g = gemini, g.key == key, g.model == model { client = g.client } else {
                client = GeminiClient(apiKey: key, model: model)
                gemini = (key, model, client)
            }
            extractor = client
        case .claudeCode:
            let detection = await detectClaudeCode()
            if let reason = CloudPrivacyPolicy.offReason(settings: settings, hasGeminiKey: false,
                                                         claudeCode: detection.status) {
                return .localOnly(reason: reason)
            }
            guard let executable = detection.executable else { return .localOnly(reason: .providerUnavailable) }
            model = settings.resolvedClaudeCodeModel
            extractor = ClaudeCodeClient(executable: executable, model: model)
        }
        let url = settings.resolvedOllamaURL
        let triage: OllamaSystemOneClient
        if let s = systemOne, s.url == url { triage = s.client } else {
            triage = OllamaSystemOneClient(baseURL: url)
            systemOne = (url, triage)
        }
        return CloudRoutingConfig(cloudExtractor: extractor, cloudModel: model, offReason: nil, triage: triage,
                                  triageModel: settings.resolvedTriageModel,
                                  privacyThreshold: settings.resolvedPrivacyThreshold,
                                  cloudProvider: provider)
    }

    /// One detection per job, shared by every email in it.
    private func detectClaudeCode() async -> ClaudeCodeDetection {
        if let claudeDetection { return await claudeDetection.value }
        let detector = claudeDetector
        let task = Task { await detector.detect() }
        claudeDetection = task
        return await task.value
    }
}
