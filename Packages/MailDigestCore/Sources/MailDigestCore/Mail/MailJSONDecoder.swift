import Foundation

/// Errors raised while decoding the JSON printed by the JXA mail scripts.
public enum MailDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The output was not valid JSON or did not match the expected shape.
    case malformedJSON(String)
    /// A `receivedAt` value was not an ISO 8601 date.
    case invalidDate(String)

    public var description: String {
        switch self {
        case .malformedJSON(let detail): return "Malformed mail JSON: \(detail)"
        case .invalidDate(let value): return "Invalid date string: \(value)"
        }
    }
}

/// The result of `FetchMail.js`: the messages found and the ids that were not.
public struct FetchResult: Sendable, Equatable {
    public var messages: [EmailMessage]
    public var missingIDs: [String]

    public init(messages: [EmailMessage], missingIDs: [String]) {
        self.messages = messages
        self.missingIDs = missingIDs
    }
}

/// Result of decoding a header listing: usable headers plus how many lacked a usable Message-ID.
public struct HeaderListing: Sendable, Equatable {
    public var headers: [MessageHeader]
    /// Entries dropped because they had no canonical Message-ID (no identity, so never processed).
    public var missingIdentityCount: Int

    public init(headers: [MessageHeader], missingIdentityCount: Int) {
        self.headers = headers
        self.missingIdentityCount = missingIdentityCount
    }
}

/// Turns the JSON printed by `ListMailboxes.js`, `ListMail.js` and `FetchMail.js` into models.
public struct MailJSONDecoder: Sendable {
    public init() {}

    // MARK: Wire formats

    private struct RawMailbox: Decodable {
        var account: String, name: String, kind: String
        var messageCount: Int, unreadCount: Int
        var accountID: String?, mailboxURL: String?
    }

    private struct RawHeader: Decodable {
        var id: String?, account: String, mailbox: String, sender: String, subject: String
        var receivedAt: String
        var storeRowID: Int64?, accountID: String?, mailboxURL: String?
    }

    private struct RawMessage: Decodable {
        var id: String, account: String, mailbox: String, sender: String, subject: String
        var receivedAt: String, body: String
        var rawHeaders: String?
        var storeRowID: Int64?
    }

    private struct RawFetch: Decodable {
        var messages: [RawMessage]
        var missing: [String]?
    }

    // MARK: Public API

    /// Decodes `ListMailboxes.js` output. Unknown `kind` strings become `.custom`.
    public func decodeMailboxes(_ data: Data) throws -> [MailboxInfo] {
        try decode([RawMailbox].self, from: data).map {
            MailboxInfo(ref: MailboxRef(account: $0.account, name: $0.name,
                                   accountID: $0.accountID, mailboxURL: $0.mailboxURL),
                        messageCount: $0.messageCount, unreadCount: $0.unreadCount,
                        kind: MailboxKind(rawValue: $0.kind) ?? .custom)
        }
    }

    /// Decodes `ListMail.js` output. `id` is the raw Message-ID header; entries without a usable
    /// canonical id are counted in `missingIdentityCount` and not returned.
    public func decodeHeaderListing(_ data: Data) throws -> HeaderListing {
        var headers: [MessageHeader] = []
        var missing = 0
        for raw in try decode([RawHeader].self, from: data) {
            guard let id = MessageID.canonical(raw.id ?? "") else { missing += 1; continue }
            headers.append(MessageHeader(id: id, account: raw.account, mailbox: raw.mailbox,
                                         sender: raw.sender, subject: raw.subject,
                                         receivedAt: try Self.parseDate(raw.receivedAt),
                                         sourceReference: MailMessageReference(messageID: id, storeRowID: raw.storeRowID),
                                         accountID: raw.accountID, mailboxURL: raw.mailboxURL))
        }
        return HeaderListing(headers: headers, missingIdentityCount: missing)
    }

    /// Decodes `ListMail.js` output, dropping entries without a usable id.
    public func decodeHeaders(_ data: Data) throws -> [MessageHeader] {
        try decodeHeaderListing(data).headers
    }

    /// Decodes `FetchMail.js` output: `{messages, missing}` or a bare array of messages.
    public func decodeFetchOutput(_ data: Data) throws -> FetchResult {
        let raw: RawFetch
        if let object = try? JSONDecoder().decode(RawFetch.self, from: data) {
            raw = object
        } else if let bare = try? JSONDecoder().decode([RawMessage].self, from: data) {
            raw = RawFetch(messages: bare, missing: nil)
        } else {
            // Neither shape matched; decode the object form again to surface a useful error.
            raw = try decode(RawFetch.self, from: data)
        }
        return FetchResult(messages: try raw.messages.map(Self.convert),
                           missingIDs: (raw.missing ?? []).compactMap(MessageID.canonical))
    }

    /// Decodes a single message object (the fixture file format).
    public func decodeMessage(_ data: Data) throws -> EmailMessage {
        try Self.convert(decode(RawMessage.self, from: data))
    }

    /// Parses a raw RFC 5322 header block and keeps only `List-Unsubscribe`, `Precedence` and
    /// `Auto-Submitted`, under those canonical spellings. The first occurrence wins.
    public static func filterHeaders(_ raw: String) -> [String: String] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        // Long headers are folded onto continuation lines starting with space or tab; join them
        // back with one space (RFC 5322). The first empty line ends the header block.
        var unfolded: [String] = []
        for line in lines {
            // Leading blank lines are tolerated; the first blank line after a header ends the block.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if unfolded.isEmpty { continue } else { break }
            }
            if line.first == " " || line.first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(String(line))
            }
        }

        let keep = ["List-Unsubscribe", "Precedence", "Auto-Submitted"]
        var out: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard let canonical = keep.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  out[canonical] == nil else { continue }
            out[canonical] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw MailDecodingError.malformedJSON(String(describing: error))
        } catch {
            throw MailDecodingError.malformedJSON(error.localizedDescription)
        }
    }

    private static func convert(_ raw: RawMessage) throws -> EmailMessage {
        EmailMessage(id: MessageID.canonical(raw.id) ?? raw.id.trimmingCharacters(in: .whitespacesAndNewlines), account: raw.account, mailbox: raw.mailbox,
                     sender: raw.sender, subject: raw.subject,
                     receivedAt: try parseDate(raw.receivedAt), body: raw.body,
                     headers: filterHeaders(raw.rawHeaders ?? ""),
                     sourceReference: MailMessageReference(
                        messageID: MessageID.canonical(raw.id) ?? raw.id.trimmingCharacters(in: .whitespacesAndNewlines),
                        storeRowID: raw.storeRowID))
    }

    /// JS `toISOString()` emits milliseconds but other sources do not, so accept both forms.
    private static func parseDate(_ string: String) throws -> Date {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: string) ?? plain.date(from: string) { return d }
        throw MailDecodingError.invalidDate(string)
    }
}
