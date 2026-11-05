import Foundation
import MailDigestCore

/// Why Apple Mail's local store could not be used. Carries no mailbox or message content.
enum MailStoreError: Error, Sendable, Equatable {
    /// No `V<n>/MailData/Envelope Index` exists.
    case notFound
    /// EPERM/EACCES: Full Disk Access is most likely not granted.
    case permissionDenied
    /// A required table or column is missing, or the file is not a Mail database.
    case unsupportedSchema
    /// SQLITE_BUSY/LOCKED; Mail is writing. Recoverable: retry or fall back.
    case busy
    /// Any other failure, with the SQLite or POSIX code.
    case other(Int32)

    /// Maps a Foundation or POSIX error (including its underlying errors) to a store error.
    static func from(_ error: Error) -> MailStoreError {
        if let e = error as? MailStoreError { return e }
        let outer = error as NSError
        var current: NSError? = outer
        while let c = current {
            if c.domain == NSPOSIXErrorDomain {
                switch Int32(truncatingIfNeeded: c.code) {
                case EPERM, EACCES: return .permissionDenied
                case ENOENT: return .notFound
                default: break
                }
            }
            if c.domain == NSCocoaErrorDomain {
                switch c.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied
                case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
                default: break
                }
            }
            current = c.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .other(Int32(truncatingIfNeeded: outer.code))
    }

    /// Short stable code for logs.
    var reasonCode: String {
        switch self {
        case .notFound: return "notFound"
        case .permissionDenied: return "permissionDenied"
        case .unsupportedSchema: return "unsupportedSchema"
        case .busy: return "busy"
        case .other(let code): return "other(\(code))"
        }
    }

    /// Higher is more informative when several candidate stores fail differently.
    fileprivate var priority: Int {
        switch self {
        case .permissionDenied: return 5
        case .busy: return 4
        case .unsupportedSchema: return 3
        case .other: return 2
        case .notFound: return 1
        }
    }
}

/// A validated Mail store: the versioned root (`~/Library/Mail/V10`) and its Envelope Index file.
struct MailStoreLocation: Sendable, Equatable {
    var root: URL
    var database: URL
}

/// Finds the active `~/Library/Mail/V<n>` store. Never hard-codes the version.
struct MailStoreLocator: Sendable {
    let baseDirectory: URL
    private let validate: @Sendable (URL) throws -> Void

    /// - Parameters:
    ///   - baseDirectory: Directory containing the `V<n>` folders; injectable for tests.
    ///   - validate: Opens the database read-only and checks the schema; throws `MailStoreError`.
    init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail", isDirectory: true),
         validate: @escaping @Sendable (URL) throws -> Void = { try EnvelopeIndexReader(databaseURL: $0).validateSchema() }) {
        self.baseDirectory = baseDirectory
        self.validate = validate
    }

    /// Returns the highest-numbered store whose database opens read-only with a supported schema.
    func locate() throws -> MailStoreLocation {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)
        } catch {
            throw MailStoreError.from(error)
        }
        let versions = names.compactMap { name -> (Int, String)? in
            let digits = name.dropFirst()
            guard name.hasPrefix("V"), !digits.isEmpty,
                  digits.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(digits) else { return nil }
            return (n, name)
        }.sorted { $0.0 > $1.0 }

        var worst: MailStoreError?
        func remember(_ e: MailStoreError) { if worst == nil || e.priority > worst!.priority { worst = e } }

        for (_, name) in versions {
            let root = baseDirectory.appendingPathComponent(name, isDirectory: true)
            let database = root.appendingPathComponent("MailData/Envelope Index")
            if access(database.path, R_OK) != 0 {
                // fileExists would hide EPERM, so use errno to tell "no Full Disk Access" from "absent".
                let code = errno
                if code == EPERM || code == EACCES { remember(.permissionDenied) }
                continue
            }
            do {
                try validate(database)
                return MailStoreLocation(root: root, database: database)
            } catch {
                remember(MailStoreError.from(error))
            }
        }
        throw worst ?? MailStoreError.notFound
    }
}
