import Foundation

/// A single HTTPS GET with hard limits, used only for logo fetches. It uses an ephemeral session (no cookies,
/// cache or stored credentials), follows at most `maxRedirects` redirects, and only to URLs `allows` accepts.
/// The body size is enforced while it streams in, so an oversized response is cut off, not buffered.
final class LimitedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let maxRedirects: Int
    private let allows: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var body = Data()
    private var redirects = 0
    private var rejected = false
    private var continuation: CheckedContinuation<Data?, Never>?

    private init(maxBytes: Int, maxRedirects: Int, allows: @escaping @Sendable (URL) -> Bool) {
        self.maxBytes = maxBytes
        self.maxRedirects = maxRedirects
        self.allows = allows
    }

    /// The body of a 200 response, or nil on any failure, redirect to a disallowed URL, or oversize body.
    static func get(_ url: URL, accept: String, maxBytes: Int, maxRedirects: Int = 3, timeout: TimeInterval = 8,
                    allows: @escaping @Sendable (URL) -> Bool) async -> Data? {
        guard allows(url) else { return nil }
        let downloader = LimitedDownloader(maxBytes: maxBytes, maxRedirects: maxRedirects, allows: allows)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = nil
        let session = URLSession(configuration: config, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        // Only what the fetch needs: no referrer, no app name. A generic agent string avoids being served
        // an error page meant for unknown clients.
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { continuation in
            downloader.lock.withLock { downloader.continuation = continuation }
            session.dataTask(with: request).resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let ok: Bool = lock.withLock {
            redirects += 1
            return redirects <= maxRedirects && request.url.map(allows) == true
        }
        if !ok { lock.withLock { rejected = true } }
        completionHandler(ok ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Normal certificate validation only; never answer a password or client-certificate challenge.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(maxBytes) else {
            lock.withLock { rejected = true }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooBig: Bool = lock.withLock {
            body.append(data)
            if body.count > maxBytes { rejected = true }
            return rejected
        }
        if tooBig { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (pending, value): (CheckedContinuation<Data?, Never>?, Data?) = lock.withLock {
            let cont = continuation
            continuation = nil
            return (cont, (error == nil && !rejected && !body.isEmpty) ? body : nil)
        }
        pending?.resume(returning: value)
    }
}
