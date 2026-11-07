import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of Test Connection.
public enum GeminiConnectionResult: Sendable, Equatable {
    case connected
    case invalidKey
    case modelUnavailable
    case generateContentUnsupported
    case rateLimited
    case network
    case server(Int)
    case unexpectedResponse
}

/// Checks a key and model with `models.get`. Sends no prompt or email content.
public enum GeminiConnectionTester {
    public static func test(apiKey: String, model: String = GeminiDefaults.model,
                            session: URLSession = .shared) async -> GeminiConnectionResult {
        let request = GeminiTransport.request(url: GeminiTransport.modelURL(model), method: "GET",
                                              apiKey: apiKey, timeout: 15, body: nil)
        let status: Int
        let data: Data
        do { (status, data) = try await GeminiTransport.send(request, session: session) }
        catch { return .network }
        switch status {
        case 200: break
        case 400: return GeminiTransport.isInvalidKey(data) ? .invalidKey : .unexpectedResponse
        case 401, 403: return .invalidKey
        case 404: return .modelUnavailable
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .unexpectedResponse
        }
        struct Meta: Decodable { var name: String?; var supportedGenerationMethods: [String]? }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data), meta.name == "models/\(model)" else {
            return .unexpectedResponse
        }
        return (meta.supportedGenerationMethods ?? []).contains("generateContent")
            ? .connected : .generateContentUnsupported
    }
}
