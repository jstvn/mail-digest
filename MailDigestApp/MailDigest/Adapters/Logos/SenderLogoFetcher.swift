import Foundation
import MailDigestCore

/// Fetches a sender's logo from the sender's own website, by domain only: BIMI DNS record, the SVG it points
/// to, then `https://<domain>/apple-touch-icon.png`. No third-party icon service, no message data. Any failure
/// returns nil. Callers guarantee the setting is on and the domain is a folded, non-personal one.
struct SenderLogoFetcher: SenderLogoFetching {
    private let resolver = DNSTXTResolver()
    private let limiter = ConcurrencyLimiter(limit: 4)
    private static let pngLimit = 1_048_576

    func fetchLogo(forDomain domain: String) async -> SenderLogo? {
        // Defence in depth: the service already filtered, but this is the one place a request is made.
        guard SenderDomain.lookupDomain(fromSender: domain) == domain else { return nil }
        await limiter.acquire()
        defer { Task { await limiter.release() } }

        for txt in await resolver.txtRecords(for: "default._bimi.\(domain)") {
            guard let url = BIMIRecord.logoURL(fromTXT: txt) else { continue }
            if let data = await LimitedDownloader.get(url, accept: "image/svg+xml", maxBytes: SVGSafety.maxBytes,
                                                      allows: LogoURLPolicy.isAllowed),
               case let logo = SenderLogo(format: .svg, data: data), LogoImageDecoder.isValid(logo) {
                return logo
            }
            break // One BIMI record is enough; fall through to the touch icon.
        }
        guard let icon = URL(string: "https://\(domain)/apple-touch-icon.png"),
              let data = await LimitedDownloader.get(icon, accept: "image/png", maxBytes: Self.pngLimit,
                                                     allows: LogoURLPolicy.isAllowed),
              case let logo = SenderLogo(format: .png, data: data), LogoImageDecoder.isValid(logo) else { return nil }
        return logo
    }
}

/// Lets at most `limit` fetches run at once, so enabling the setting on a long sender list doesn't open
/// dozens of connections together.
private actor ConcurrencyLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}
