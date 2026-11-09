import CryptoKit
import Foundation
import MailDigestCore
import OSLog

/// Logos on disk under `~/Library/Application Support/MailDigest/SenderLogos`. File names are a hash of the
/// origin and folded domain plus a fixed extension, so no input ever becomes part of a path. A small JSON
/// index holds timestamps and failures. Header logos (`localHeader`) and website logos (`network`) are kept
/// under different names, so the two can be told apart and shown independently.
actor DiskSenderLogoStore: SenderLogoStore {
    private struct Entry: Codable {
        var fetchedAt: Date
        var format: LogoFormat?
        var file: String?
    }

    private static let log = Logger(subsystem: "MailDigest", category: "SenderLogos")
    private let directory: URL
    private var index: [String: Entry]?

    init(directory: URL = DiskSenderLogoStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailDigest/SenderLogos", isDirectory: true)
    }

    func record(domain: String, origin: LogoOrigin) async -> LogoRecord? {
        let key = Self.key(domain, origin)
        guard let entry = loadIndex()[key] else { return nil }
        guard let format = entry.format, let file = entry.file else {
            return LogoRecord(domain: domain, origin: origin, fetchedAt: entry.fetchedAt, logo: nil)
        }
        let maxBytes = format == .svg ? SVGSafety.maxBytes : 1_048_576
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)), data.count <= maxBytes else {
            return nil // File gone or too big: behave as if never stored.
        }
        return LogoRecord(domain: domain, origin: origin, fetchedAt: entry.fetchedAt,
                          logo: SenderLogo(format: format, data: data))
    }

    func save(_ record: LogoRecord) async {
        var index = loadIndex()
        let key = Self.key(record.domain, record.origin)
        var entry = Entry(fetchedAt: record.fetchedAt, format: nil, file: nil)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let logo = record.logo {
                let file = Self.fileName(record.domain, record.origin, logo.format)
                try logo.data.write(to: directory.appendingPathComponent(file), options: .atomic)
                entry.format = logo.format
                entry.file = file
            }
            // A different format for the same key leaves an orphan file; remove it.
            if let old = index[key]?.file, old != entry.file {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
            }
            index[key] = entry
            self.index = index
            try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            Self.log.error("could not save a sender logo: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    private func loadIndex() -> [String: Entry] {
        if let index { return index }
        let loaded = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        index = loaded
        return loaded
    }

    private static func key(_ domain: String, _ origin: LogoOrigin) -> String { "\(origin.rawValue)/\(domain)" }

    /// `<64 hex chars>.svg|png`, derived from the key, never from raw input.
    private static func fileName(_ domain: String, _ origin: LogoOrigin, _ format: LogoFormat) -> String {
        let digest = SHA256.hash(data: Data(key(domain, origin).utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest).\(format.rawValue)"
    }
}
