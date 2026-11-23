import AppKit
import Foundation
import MailDigestCore

/// Gathers what onboarding needs to judge Ollama (Q92): whether the app exists, whether the server answers,
/// its version and the installed tags. A thin adapter; the decision lives in `OllamaSetupState.evaluate`.
enum OllamaSetupChecker {
    private struct Version: Decodable { var version: String }
    private struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }

    static func check(baseURL: URL, model: String) async -> OllamaSetupState {
        async let versionResult: Version? = fetch("api/version", baseURL: baseURL)
        async let tagsResult: Tags? = fetch("api/tags", baseURL: baseURL)
        let version = await versionResult
        let tags = await tagsResult
        let installed = await MainActor.run { OllamaLauncher.isInstalled }
        return OllamaSetupState.evaluate(isAppInstalled: installed, reachable: version != nil || tags != nil,
                                         version: version?.version, installedTags: tags?.models.map(\.name),
                                         requiredModel: model)
    }

    private static func fetch<T: Decodable>(_ path: String, baseURL: URL) async -> T? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
