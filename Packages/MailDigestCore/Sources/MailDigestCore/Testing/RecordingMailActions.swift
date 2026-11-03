import Foundation

/// One recorded move call.
public struct MailActionCall: Sendable, Equatable {
    public var messageIDs: [String]
    /// Destination name; "Trash" for `moveToTrash`.
    public var destination: String
    public var createIfMissing: Bool
}

/// `MailActions` fake that tracks where each message lives.
public actor RecordingMailActions: MailActions {
    private var locations: [String: MailboxRef]
    private let missingIDs: Set<String>
    public private(set) var calls: [MailActionCall] = []
    public private(set) var restored: [[MailActionResult]] = []

    public init(locations: [String: MailboxRef], missingIDs: Set<String> = []) {
        self.locations = locations
        self.missingIDs = missingIDs
    }

    /// Where the message currently is, if known.
    public func location(of id: String) -> MailboxRef? { locations[id] }

    public func moveToTrash(messageIDs: [String]) async throws -> [MailActionResult] {
        calls.append(MailActionCall(messageIDs: messageIDs, destination: "Trash", createIfMissing: false))
        return apply(messageIDs, to: "Trash")
    }

    public func move(messageIDs: [String], toMailboxNamed name: String, createIfMissing: Bool) async throws -> [MailActionResult] {
        calls.append(MailActionCall(messageIDs: messageIDs, destination: name, createIfMissing: createIfMissing))
        return apply(messageIDs, to: name)
    }

    public func restore(_ results: [MailActionResult]) async throws {
        restored.append(results)
        for r in results where r.succeeded {
            locations[r.messageID] = MailboxRef(account: r.account, name: r.originalMailbox)
        }
    }

    private func apply(_ ids: [String], to name: String) -> [MailActionResult] {
        ids.map { id in
            guard !missingIDs.contains(id), let current = locations[id] else {
                return MailActionResult(messageID: id, account: locations[id]?.account ?? "",
                                        originalMailbox: locations[id]?.name ?? "",
                                        succeeded: false, error: "not found")
            }
            locations[id] = MailboxRef(account: current.account, name: name)
            return MailActionResult(messageID: id, account: current.account,
                                    originalMailbox: current.name, succeeded: true, error: nil)
        }
    }
}
