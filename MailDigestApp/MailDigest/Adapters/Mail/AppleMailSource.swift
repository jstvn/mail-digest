import Foundation
import MailDigestCore
import os

/// Hybrid read adapter: SQLite + `.emlx` fast path with per-operation and per-message JXA fallback.
/// Read-only; it only asks Mail to act through `CheckMail.js`.
struct AppleMailSource: MailSource, MailVolumeSource {
    private let locator: MailStoreLocator
    private let jxa: AppleScriptMailSource
    private let parser: EmlxParser
    private let busyTimeout: TimeInterval

    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "mail")

    /// - Parameters:
    ///   - locator: Finds the Mail store; inject a different base directory for a harness.
    ///   - jxa: The fallback source; inject a runner/script resolver to avoid real Mail.
    ///   - parser: Body parser; defaults to one with the CoreFoundation charset decoder.
    ///   - busyTimeout: SQLite lock wait per operation.
    init(locator: MailStoreLocator = MailStoreLocator(),
         jxa: AppleScriptMailSource = AppleScriptMailSource(),
         parser: EmlxParser = CoreFoundationCharsetDecoder.makeParser(),
         busyTimeout: TimeInterval = 5) {
        self.locator = locator
        self.jxa = jxa
        self.parser = parser
        self.busyTimeout = busyTimeout
    }

    // MARK: MailSource

    func checkForNewMail() async throws {
        try await jxa.checkForNewMail()
    }

    func listMailboxes() async throws -> [MailboxInfo] {
        let rows: [EnvelopeIndexReader.MailboxRow]
        let names: Set<String>
        do {
            // Locating the store opens the database, so it stays off the caller's executor too.
            (rows, names) = try await Self.offload { [self] in
                let store = try openStore()
                let rows = try store.reader.mailboxes()
                let names = Set((try? FileManager.default.contentsOfDirectory(atPath: store.location.root.path)) ?? [])
                return (rows, names)
            }
        } catch let error as MailStoreError {
            Self.log.notice("listMailboxes path=jxa reason=\(error.reasonCode, privacy: .public)")
            return try await jxa.listMailboxes()
        }

        // Automation supplies the active set, names and kinds; if it fails, use the directory heuristic.
        // Ask JXA only when Automation is already granted: listing mailboxes must never be what
        // shows the Automation prompt (that happens only from "Allow Mail Access…").
        var jxaInfos: [MailboxInfo]?
        let automation = await Self.offloadNonThrowing { MailPermissionProbe().automation() }
        if automation == .granted {
            do {
                jxaInfos = try await jxa.listMailboxesForResolver()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.notice("listMailboxes resolver=heuristic reason=\(Self.reason(error), privacy: .public)")
            }
        } else {
            Self.log.notice("listMailboxes resolver=heuristic reason=automation.\(automation.rawValue, privacy: .public)")
        }
        let infos = MailboxResolver(rows: rows, jxaMailboxes: jxaInfos, storeDirectoryNames: names).mailboxInfos()
        Self.log.notice("listMailboxes path=sqlite count=\(infos.count, privacy: .public)")
        return infos
    }

    func listHeaders(in mailbox: MailboxRef, from: Date, to: Date) async throws -> [MessageHeader] {
        do {
            let rows = try await Self.offload { [self] in
                let store = try openStore()
                guard let url = try resolveMailboxURL(for: mailbox, reader: store.reader) else {
                    throw MailStoreError.notFound
                }
                return try store.reader.headers(mailboxURL: url, from: from, to: to)
            }
            var missingIdentity = 0
            var headers: [MessageHeader] = []
            for row in rows {
                guard let id = row.canonicalMessageID else { missingIdentity += 1; continue }
                headers.append(MessageHeader(id: id, account: mailbox.account, mailbox: mailbox.name,
                                             sender: row.sender, subject: row.fullSubject, receivedAt: row.receivedAt,
                                             sourceReference: MailMessageReference(messageID: id, storeRowID: row.rowID)))
            }
            let unique = MailListingDeduplicator.deduplicate(headers).map { Self.stamp($0, mailbox) }
            Self.log.notice("listHeaders path=sqlite rows=\(rows.count, privacy: .public) unique=\(unique.count, privacy: .public) missingIdentity=\(missingIdentity, privacy: .public)")
            return unique
        } catch let error as MailStoreError {
            Self.log.notice("listHeaders path=jxa reason=\(error.reasonCode, privacy: .public)")
        }
        let listing = try await jxa.listHeaderListing(in: mailbox, from: from, to: to)
        Self.log.notice("listHeaders path=jxa unique=\(listing.headers.count, privacy: .public) missingIdentity=\(listing.missingIdentityCount, privacy: .public)")
        return listing.headers.map { Self.stamp($0, mailbox) }
    }

    func fetchMessages(references: [MailMessageReference], in mailbox: MailboxRef) async throws -> [EmailMessage] {
        guard !references.isEmpty else { return [] }
        var found: [String: EmailMessage] = [:]
        var remaining = references

        do {
            let outcome = try await Self.offload { [self] in
                fastFetch(references: references, mailbox: mailbox, store: try openStore())
            }
            for m in outcome.messages { found[m.id] = m }
            remaining = outcome.remaining
            Self.log.notice("fetch path=sqlite served=\(outcome.messages.count, privacy: .public) emlx=\(outcome.emlxCount, privacy: .public) partial=\(outcome.partialCount, privacy: .public) fallback=\(outcome.remaining.count, privacy: .public)")
            for (reason, n) in outcome.reasons.sorted(by: { $0.key < $1.key }) {
                Self.log.notice("fetch fallbackReason=\(reason, privacy: .public) count=\(n, privacy: .public)")
            }
        } catch let error as MailStoreError {
            Self.log.notice("fetch path=jxa reason=\(error.reasonCode, privacy: .public)")
        }

        if !remaining.isEmpty {
            // One batched JXA call; automation errors propagate as OsascriptError.automationDenied.
            let result = try await jxa.fetchResult(references: remaining, in: mailbox)
            for var m in result.messages {
                m.account = mailbox.account
                m.mailbox = mailbox.name
                found[m.id] = m
            }
            Self.log.notice("fetch path=jxa served=\(result.messages.count, privacy: .public) missing=\(result.missingIDs.count, privacy: .public)")
        }

        var seen = Set<String>()
        return references.compactMap { ref in
            guard seen.insert(ref.messageID).inserted else { return nil }
            return found[ref.messageID]
        }
    }

    // MARK: Volume

    /// Per-day message counts for the New Backlog Job chart, from the SQLite index only. Nil without the
    /// store (no Full Disk Access, unsupported schema): the chart is then left out rather than asking Mail
    /// message by message.
    func dailyCounts(in mailboxes: [MailboxRef], from: Date, to: Date) async throws -> [DayCount]? {
        do {
            return try await Self.offload { [self] in
                let store = try openStore()
                let urls = try mailboxes.compactMap { try resolveMailboxURL(for: $0, reader: store.reader) }
                return try store.reader.dailyCounts(mailboxURLs: urls, from: from, to: to)
            }
        } catch is MailStoreError {
            return nil
        }
    }

    // MARK: Fast path

    private struct Store: Sendable {
        var location: MailStoreLocation
        var reader: EnvelopeIndexReader
        var emlx: EmlxStoreReader
    }

    private struct FastOutcome: Sendable {
        var messages: [EmailMessage] = []
        var remaining: [MailMessageReference] = []
        var reasons: [String: Int] = [:]
        var emlxCount = 0
        var partialCount = 0
    }

    private func openStore() throws -> Store {
        let location = try locator.locate()
        return Store(location: location,
                     reader: EnvelopeIndexReader(databaseURL: location.database, busyTimeout: busyTimeout),
                     emlx: EmlxStoreReader(storeRoot: location.root))
    }

    /// The SQLite URL for a ref: its own, else matched by account ID and path from the mailbox rows.
    private func resolveMailboxURL(for ref: MailboxRef, reader: EnvelopeIndexReader) throws -> String? {
        if let url = ref.mailboxURL { return url }
        let rows = try reader.mailboxes()
        return MailboxResolver(rows: rows, jxaMailboxes: nil, storeDirectoryNames: []).sqliteURL(for: ref)
    }

    /// Serves what it can from SQLite + `.emlx`; everything else goes back for JXA with its row hint.
    private func fastFetch(references: [MailMessageReference], mailbox: MailboxRef, store: Store) -> FastOutcome {
        var out = FastOutcome()
        func fallback(_ ref: MailMessageReference, _ reason: String) {
            out.remaining.append(ref)
            out.reasons[reason, default: 0] += 1
        }

        let mailboxURLString: String?
        do {
            mailboxURLString = try resolveMailboxURL(for: mailbox, reader: store.reader)
        } catch {
            for ref in references { fallback(ref, "store.\(MailStoreError.from(error).reasonCode)") }
            return out
        }
        guard let urlString = mailboxURLString, let mailboxURL = MailboxURL(urlString) else {
            for ref in references { fallback(ref, "mailboxUnresolved") }
            return out
        }

        for ref in references {
            do {
                // A stored row ID is only a hint: it must match both the Message-ID and the mailbox.
                var row: EnvelopeIndexReader.StoreRow?
                if let hint = ref.storeRowID, let candidate = try store.reader.row(rowID: hint),
                   candidate.canonicalMessageID == ref.messageID, candidate.mailboxURL == urlString {
                    row = candidate
                }
                if row == nil {
                    // Rows arrive newest first, ties by greater ROWID.
                    row = try store.reader.rows(messageID: ref.messageID, mailboxURL: urlString).first
                }
                guard let row else { fallback(ref, "rowNotFound"); continue }

                let file = try store.emlx.read(mailboxURL: mailboxURL, rowID: row.rowID)
                switch parser.parse(file.data) {
                case .unusable(let reason):
                    fallback(ref, "unusable.\(reason.rawValue)")
                case .usable(let parsed):
                    guard parsed.messageID == ref.messageID else { fallback(ref, "idMismatch"); continue }
                    out.messages.append(EmailMessage(
                        id: ref.messageID, account: mailbox.account, mailbox: mailbox.name,
                        sender: parsed.sender.isEmpty ? row.sender : parsed.sender,
                        subject: parsed.subject.isEmpty ? row.fullSubject : parsed.subject,
                        receivedAt: row.receivedAt, body: parsed.body, headers: parsed.filterHeaders,
                        sourceReference: MailMessageReference(messageID: ref.messageID, storeRowID: row.rowID),
                        // A partial .emlx may be missing parts, so it is never fully inspected (Q66).
                        contentInspection: file.source == .partialEmlx ? .uninspectedParts : parsed.inspection,
                        inspectionGap: file.source == .partialEmlx ? .partialMessage : parsed.inspectionGap,
                        bimiIndicator: BIMIIndicator.headerValue(inRawHeaders: parsed.rawHeaderBlock)))
                    if file.source == .partialEmlx { out.partialCount += 1 } else { out.emlxCount += 1 }
                }
            } catch let error as EmlxReadFailure {
                fallback(ref, "file.\(error.reasonCode)")
            } catch {
                fallback(ref, "store.\(MailStoreError.from(error).reasonCode)")
            }
        }
        return out
    }

    // MARK: Helpers

    /// Every header carries the caller's mailbox exactly, whichever path produced it.
    private static func stamp(_ header: MessageHeader, _ ref: MailboxRef) -> MessageHeader {
        var h = header
        h.account = ref.account
        h.mailbox = ref.name
        h.accountID = ref.accountID
        h.mailboxURL = ref.mailboxURL
        return h
    }

    private static func reason(_ error: Error) -> String {
        switch error as? OsascriptError {
        case .automationDenied: return "automationDenied"
        case .mailNotRunning: return "mailNotRunning"
        case .timedOut: return "timedOut"
        case .scriptFailed, .launchFailed, .scriptMissing: return "scriptFailed"
        case nil: return "other"
        }
    }

    /// Runs blocking SQLite/file work off the cooperative pool; `MailStoreError` is thrown as-is.
    private static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: MailStoreError.from(error)) }
            }
        }
    }

    /// Runs a blocking, non-throwing probe off the cooperative pool.
    private static func offloadNonThrowing<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
