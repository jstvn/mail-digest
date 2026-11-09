import Foundation

/// Where a stored logo came from. Network logos obey the Show Sender Logos setting; header logos never need it.
public enum LogoOrigin: String, Codable, Sendable, Equatable {
    case localHeader, network
}

public enum LogoFormat: String, Codable, Sendable, Equatable {
    case svg, png
}

/// Image bytes ready for the app to decode.
public struct SenderLogo: Sendable, Equatable {
    public var format: LogoFormat
    public var data: Data
    public init(format: LogoFormat, data: Data) {
        self.format = format
        self.data = data
    }
}

/// One cached lookup for a folded domain. `logo == nil` records a failure, which is cached like a success.
public struct LogoRecord: Sendable, Equatable {
    public var domain: String
    public var origin: LogoOrigin
    public var fetchedAt: Date
    public var logo: SenderLogo?
    public init(domain: String, origin: LogoOrigin, fetchedAt: Date, logo: SenderLogo?) {
        self.domain = domain
        self.origin = origin
        self.fetchedAt = fetchedAt
        self.logo = logo
    }
}

/// How long a network lookup result, success or failure, is trusted.
public enum LogoCachePolicy {
    public static let timeToLive: TimeInterval = 30 * 24 * 3600

    /// True while `fetchedAt` is less than 30 days old. A timestamp in the future counts as expired.
    public static func isLive(fetchedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < timeToLive
    }
}

/// Persistent logo storage, keyed by folded domain and origin. The app implements it on disk.
public protocol SenderLogoStore: Sendable {
    func record(domain: String, origin: LogoOrigin) async -> LogoRecord?
    func save(_ record: LogoRecord) async
}

/// Fetches a logo for a folded, non-personal domain. Gets the domain only, never a sender or message content.
/// Returns nil on any failure.
public protocol SenderLogoFetching: Sendable {
    func fetchLogo(forDomain domain: String) async -> SenderLogo?
}

/// Receives BIMI headers captured while mail is processed.
public protocol SenderLogoRecording: Sendable {
    func recordBIMIHeader(_ value: String, sender: String) async
}

/// Resolves sender logos: stored header logos first, then (only when allowed) cached or fetched network logos.
/// One fetch per domain at most, even for concurrent callers; failures are cached too.
public actor SenderLogoService: SenderLogoRecording {
    private let store: any SenderLogoStore
    private let fetcher: any SenderLogoFetching
    private let clock: any Clock
    private var inFlight: [String: Task<SenderLogo?, Never>] = [:]

    public init(store: any SenderLogoStore, fetcher: any SenderLogoFetching, clock: any Clock) {
        self.store = store
        self.fetcher = fetcher
        self.clock = clock
    }

    /// Decodes and stores a header logo for the sender's domain. Silently ignores anything unusable.
    /// Personal-mail domains are skipped: a header there could only be a spoof.
    public func recordBIMIHeader(_ value: String, sender: String) async {
        guard let domain = SenderDomain.lookupDomain(fromSender: sender),
              let svg = BIMIIndicator.decodeSVG(headerValue: value) else { return }
        await store.save(LogoRecord(domain: domain, origin: .localHeader, fetchedAt: clock.now(),
                                    logo: SenderLogo(format: .svg, data: svg)))
    }

    /// The stored header logo for the sender's domain. Never touches the network.
    public func localLogo(forSender sender: String) async -> SenderLogo? {
        guard let domain = SenderDomain.foldedDomain(fromSender: sender) else { return nil }
        return await store.record(domain: domain, origin: .localHeader)?.logo
    }

    /// The cached or freshly fetched network logo. Returns nil without any lookup when `enabled` is false,
    /// for a personal-mail domain, or when the sender has no usable domain.
    public func networkLogo(forSender sender: String, enabled: Bool) async -> SenderLogo? {
        guard enabled, let domain = SenderDomain.lookupDomain(fromSender: sender) else { return nil }
        if let running = inFlight[domain] { return await running.value }
        if let cached = await store.record(domain: domain, origin: .network),
           LogoCachePolicy.isLive(fetchedAt: cached.fetchedAt, now: clock.now()) {
            return cached.logo
        }
        // The store read suspended, so another caller may have started this domain meanwhile.
        if let running = inFlight[domain] { return await running.value }
        let task = Task { [store, fetcher, clock] () -> SenderLogo? in
            let logo = await fetcher.fetchLogo(forDomain: domain)
            await store.save(LogoRecord(domain: domain, origin: .network, fetchedAt: clock.now(), logo: logo))
            return logo
        }
        inFlight[domain] = task
        let logo = await task.value
        inFlight[domain] = nil
        return logo
    }

    /// Header logo, then network logo (when enabled), else nil (the caller shows initials).
    public func logo(forSender sender: String, networkEnabled: Bool) async -> SenderLogo? {
        if let local = await localLogo(forSender: sender) { return local }
        return await networkLogo(forSender: sender, enabled: networkEnabled)
    }
}
