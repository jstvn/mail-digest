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

    init(credentials: any CredentialStore, snapshot: @escaping @Sendable @MainActor () -> DigestSettings) {
        self.credentials = credentials
        self.snapshot = snapshot
    }

    /// Call when a job starts or resumes: drops the System One client and re-reads the key.
    func resetForNewJob() {
        systemOne = nil
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
        if !keyLoaded {
            // A Keychain failure counts as no credential: fail closed, keep everything local.
            apiKey = (try? credentials.read()) ?? nil
            keyLoaded = true
        }
        let key = apiKey
        if let reason = CloudPrivacyPolicy.offReason(settings: settings, hasKey: key != nil) {
            return .localOnly(reason: reason)
        }
        guard let key else { return .localOnly(reason: .noCredential) }
        let model = settings.resolvedGeminiModel
        let client: GeminiClient
        if let g = gemini, g.key == key, g.model == model { client = g.client } else {
            client = GeminiClient(apiKey: key, model: model)
            gemini = (key, model, client)
        }
        let url = settings.resolvedOllamaURL
        let triage: OllamaSystemOneClient
        if let s = systemOne, s.url == url { triage = s.client } else {
            triage = OllamaSystemOneClient(baseURL: url)
            systemOne = (url, triage)
        }
        return CloudRoutingConfig(cloudExtractor: client, cloudModel: model, offReason: nil, triage: triage,
                                  triageModel: settings.resolvedTriageModel,
                                  privacyThreshold: settings.resolvedPrivacyThreshold)
    }
}
