import Foundation
import MailDigestCore

/// The bytes of an `.emlx` file and whether it was the full or partial variant.
struct EmlxFile: Sendable {
    var data: Data
    var source: EmlxSource
    /// Whether `Attachments/<ROWID>` exists next to the `Messages` folder (unknown counts as yes).
    /// Only checked for partial files; a hit means Mail keeps parts outside the `.emlx`.
    var hasAttachmentsDirectory = false
}

/// Why a message file could not be read. Never carries paths or content.
enum EmlxReadFailure: Error, Sendable, Equatable {
    case missingFile, ambiguousStore, unsafePath, permissionDenied, readFailed

    var reasonCode: String {
        switch self {
        case .missingFile: return "missingFile"
        case .ambiguousStore: return "ambiguousStore"
        case .unsafePath: return "unsafePath"
        case .permissionDenied: return "permissionDenied"
        case .readFailed: return "readFailed"
        }
    }
}

/// Locates and reads `<root>/<account>/<c>.mbox/…/<store UUID>/Data/<hash dirs>/Messages/<ROWID>.emlx`.
/// Attachment directories are never opened; the canonical path must stay inside the store root.
struct EmlxStoreReader: Sendable {
    let storeRoot: URL

    init(storeRoot: URL) {
        self.storeRoot = storeRoot
    }

    /// Prefers `<ROWID>.emlx` over `<ROWID>.partial.emlx`.
    func read(mailboxURL: MailboxURL, rowID: Int64) throws -> EmlxFile {
        guard rowID >= 0, let components = MailStoreLayout.mailboxDirectoryComponents(for: mailboxURL) else {
            throw EmlxReadFailure.unsafePath
        }
        let fm = FileManager.default
        let root = storeRoot.resolvingSymlinksInPath().standardizedFileURL

        var mailboxDir = root
        for c in components { mailboxDir.appendPathComponent(c, isDirectory: true) }
        try requireInside(mailboxDir, root: root)

        // Exactly one UUID-named store directory per mailbox.
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: mailboxDir.path)
        } catch {
            throw Self.failure(from: error)
        }
        let stores = entries.filter { UUID(uuidString: $0) != nil }
        guard !stores.isEmpty else { throw EmlxReadFailure.missingFile }
        guard stores.count == 1 else { throw EmlxReadFailure.ambiguousStore }

        var messages = mailboxDir.appendingPathComponent(stores[0], isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        for c in MailStoreLayout.hashDirectoryComponents(rowID: rowID) {
            messages.appendPathComponent(c, isDirectory: true)
        }
        messages.appendPathComponent("Messages", isDirectory: true)

        let names = MailStoreLayout.messageFileNames(rowID: rowID)
        for (name, source) in [(names.full, EmlxSource.emlx), (names.partial, .partialEmlx)] {
            let file = messages.appendingPathComponent(name)
            // lstat sees the entry itself, so a missing file is not confused with a denied one.
            var st = stat()
            if lstat(file.path, &st) != 0 {
                switch errno {
                case ENOENT, ENOTDIR: continue
                case EPERM, EACCES: throw EmlxReadFailure.permissionDenied
                default: throw EmlxReadFailure.readFailed
                }
            }
            try requireInside(file, root: root)
            do {
                var result = EmlxFile(data: try Data(contentsOf: file.resolvingSymlinksInPath()), source: source)
                if source == .partialEmlx {
                    // Existence only: the attachments themselves are never opened.
                    let dir = messages.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
                        .appendingPathComponent(String(rowID), isDirectory: true)
                    var ast = stat()
                    result.hasAttachmentsDirectory = lstat(dir.path, &ast) == 0 || (errno != ENOENT && errno != ENOTDIR)
                }
                return result
            } catch {
                throw Self.failure(from: error)
            }
        }
        throw EmlxReadFailure.missingFile
    }

    /// Rejects any path whose symlink-resolved form leaves the store root.
    private func requireInside(_ url: URL, root: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = root.pathComponents
        guard resolved.count >= base.count, Array(resolved.prefix(base.count)) == base else {
            throw EmlxReadFailure.unsafePath
        }
    }

    private static func failure(from error: Error) -> EmlxReadFailure {
        switch MailStoreError.from(error) {
        case .permissionDenied: return .permissionDenied
        case .notFound: return .missingFile
        default: return .readFailed
        }
    }
}
