import Foundation
import MailDigestCore

/// The JXA fallback and control path: wraps the four bundled scripts and `MailJSONDecoder`.
struct AppleScriptMailSource: MailSource {
    private let runner: any JXARunning
    private let scriptURL: @Sendable (String) -> URL?
    private let decoder: MailJSONDecoder

    /// - Parameters:
    ///   - runner: Executes a script; defaults to `/usr/bin/osascript` with a 120 s timeout.
    ///   - scriptURL: Resolves a script name (`"ListMail"`) to a file; defaults to the app bundle.
    init(runner: any JXARunning = OsascriptRunner(),
         scriptURL: @escaping @Sendable (String) -> URL? = { Bundle.main.url(forResource: $0, withExtension: "js") },
         decoder: MailJSONDecoder = MailJSONDecoder()) {
        self.runner = runner
        self.scriptURL = scriptURL
        self.decoder = decoder
    }

    func checkForNewMail() async throws {
        _ = try await run("CheckMail", argument: nil)
    }

    func listMailboxes() async throws -> [MailboxInfo] {
        try await listMailboxesForResolver()
    }

    /// Mailboxes as Mail reports them (account names, kinds, full paths); used by the resolver.
    func listMailboxesForResolver() async throws -> [MailboxInfo] {
        try decoder.decodeMailboxes(try await run("ListMailboxes", argument: nil))
    }

    func listHeaders(in mailbox: MailboxRef, from: Date, to: Date) async throws -> [MessageHeader] {
        try await listHeaderListing(in: mailbox, from: from, to: to).headers
    }

    /// Like `listHeaders` but also reports entries dropped for lacking a Message-ID. The script has
    /// already applied the first-occurrence de-duplication (Q32), so none is applied here.
    func listHeaderListing(in mailbox: MailboxRef, from: Date, to: Date) async throws -> HeaderListing {
        let address = MailboxResolver.jxaAddress(for: mailbox)
        let argument = try Self.json([
            "accountID": address.accountID ?? NSNull(),
            "path": address.path,
            "from": Int64((from.timeIntervalSince1970 * 1000).rounded()),
            "to": Int64((to.timeIntervalSince1970 * 1000).rounded()),
        ])
        return try decoder.decodeHeaderListing(try await run("ListMail", argument: argument))
    }

    func fetchMessages(references: [MailMessageReference], in mailbox: MailboxRef) async throws -> [EmailMessage] {
        try await fetchResult(references: references, in: mailbox).messages
    }

    /// Like `fetchMessages` but also reports the IDs the script could not verify.
    func fetchResult(references: [MailMessageReference], in mailbox: MailboxRef) async throws -> FetchResult {
        guard !references.isEmpty else { return FetchResult(messages: [], missingIDs: []) }
        let address = MailboxResolver.jxaAddress(for: mailbox)
        let argument = try Self.json([
            "accountID": address.accountID ?? NSNull(),
            "path": address.path,
            "references": references.map {
                ["messageID": $0.messageID, "storeRowID": $0.storeRowID.map { $0 as Any } ?? NSNull()] as [String: Any]
            },
        ])
        return try decoder.decodeFetchOutput(try await run("FetchMail", argument: argument))
    }

    private func run(_ name: String, argument: String?) async throws -> Data {
        guard let url = scriptURL(name) else { throw OsascriptError.scriptMissing(name) }
        return try await runner.run(script: url, argument: argument)
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
