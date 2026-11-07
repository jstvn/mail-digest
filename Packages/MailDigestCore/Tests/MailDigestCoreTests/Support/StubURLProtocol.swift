import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Parent of every suite that uses `StubURLProtocol`: its state is global, so they must not run in parallel.
@Suite(.serialized) enum StubNetworkTests {}

/// A request as seen by the stub, with the body already read.
struct StubRequest: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var timeout: TimeInterval
    var body: Data
}

/// What the stub answers with.
struct StubResponse: Sendable {
    var status: Int = 200
    var body: Data = Data()
    /// When set, the request fails with this URL error code instead of answering.
    var failure: URLError.Code?
}

/// Serves canned answers to `URLSession` without any network.
/// State is static, so tests using it must run serialized (`@Suite(.serialized)`).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (StubRequest) -> StubResponse)?
        var requests: [StubRequest] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    /// Installs a handler and clears recorded requests.
    static func install(_ handler: @escaping @Sendable (StubRequest) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        state = State(handler: handler)
    }

    static var requests: [StubRequest] {
        lock.lock(); defer { lock.unlock() }
        return state.requests
    }

    /// A session whose traffic goes only to the stub.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = StubRequest(
            url: request.url!, method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:], timeout: request.timeoutInterval,
            body: Self.readBody(request))
        Self.lock.lock()
        Self.state.requests.append(recorded)
        let handler = Self.state.handler
        Self.lock.unlock()

        let response = handler?(recorded) ?? StubResponse(status: 404)
        if let code = response.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let http = HTTPURLResponse(url: recorded.url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession turns `httpBody` into a stream before it reaches a URLProtocol.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
