import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared request plumbing for the Gemini client and connection tester.
enum GeminiTransport {
    static func modelURL(_ model: String, suffix: String = "") -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:")
        let escaped = model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model
        // Built from a string so the ':generateContent' suffix is not escaped.
        return URL(string: GeminiDefaults.baseURL.absoluteString + "/models/" + escaped + suffix)
            ?? GeminiDefaults.baseURL
    }

    static func request(url: URL, method: String, apiKey: String, timeout: TimeInterval, body: Data?) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue(apiKey, forHTTPHeaderField: GeminiDefaults.apiKeyHeader)
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        return r
    }

    /// Outcome of the transport layer: HTTP status and body, or a mapped failure.
    enum Failure: Error { case cancelled, timedOut, network }

    static func send(_ request: URLRequest, session: URLSession) async throws -> (Int, Data) {
        do {
            let (data, response) = try await OllamaClient.perform(request, session: session)
            guard let http = response as? HTTPURLResponse else { throw Failure.network }
            return (http.statusCode, data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw Failure.timedOut
        } catch {
            throw Failure.network
        }
    }

    /// True when the error body names `API_KEY_INVALID` as a reason or the status.
    static func isInvalidKey(_ data: Data) -> Bool {
        struct Body: Decodable {
            struct Err: Decodable {
                struct Detail: Decodable { var reason: String? }
                var status: String?
                var details: [Detail]?
            }
            var error: Err?
        }
        guard let e = (try? JSONDecoder().decode(Body.self, from: data))?.error else { return false }
        return e.status == "API_KEY_INVALID" || (e.details ?? []).contains { $0.reason == "API_KEY_INVALID" }
    }
}
