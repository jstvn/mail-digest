import Foundation
import MailDigestCore
import OSLog

/// Where Mail Digest last saw a message: the mailbox it was listed in and Mail's own id as a lookup hint.
struct MailLocation: Sendable, Equatable {
    var mailbox: MailboxRef
    var storeRowID: Int64?
}

/// `MailActions` over `MailActions.js`. Messages are only moved (Trash, a folder in the same account,
/// or back again); nothing is deleted permanently.
///
/// Every message is found by its canonical Message-ID inside its own mailbox and verified against its raw
/// header by the script (Q29). An id with no known location is reported as a failed result, never guessed.
/// Failures, including Mail not running or Automation denied, become failed results so that moves which
/// did succeed in an earlier group are still recorded for Undo; only cancellation is thrown.
actor AppleScriptMailActions: MailActions {
    typealias Locator = @Sendable ([String]) async -> [String: MailLocation]

    /// Where a moved message lives now, kept in memory so Undo can find it (Undo lasts until quit).
    private struct Moved {
        var accountID: String?
        var restorePath: [String]
    }

    private let runner: any JXARunning
    private let scriptURL: @Sendable (String) -> URL?
    private let locate: Locator
    private var moved: [String: Moved] = [:]
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "mail-actions")

    /// - Parameters:
    ///   - locate: Looks up the mailbox and row id of each message id (from the owning job's items, Q18).
    init(runner: any JXARunning = OsascriptRunner(),
         scriptURL: @escaping @Sendable (String) -> URL? = { Bundle.main.url(forResource: $0, withExtension: "js") },
         locate: @escaping Locator) {
        self.runner = runner
        self.scriptURL = scriptURL
        self.locate = locate
    }

    func moveToTrash(messageIDs: [String]) async throws -> [MailActionResult] {
        try await perform(action: "trash", messageIDs: messageIDs, targetName: nil, createIfMissing: false)
    }

    func move(messageIDs: [String], toMailboxNamed name: String, createIfMissing: Bool) async throws -> [MailActionResult] {
        try await perform(action: "move", messageIDs: messageIDs, targetName: name, createIfMissing: createIfMissing)
    }

    /// Read-only: resolves and verifies each message without changing anything. For diagnostics and tests.
    func verify(messageIDs: [String]) async throws -> [MailActionResult] {
        try await perform(action: "verify", messageIDs: messageIDs, targetName: nil, createIfMissing: false)
    }

    func restore(_ results: [MailActionResult]) async throws {
        var failures: [RestoreFailure] = []
        // One script call per (account, destination, original mailbox) group.
        var groups: [[String]: (accountID: String?, destination: [String], restore: [String], ids: [String])] = [:]
        var order: [[String]] = []
        for result in results where result.succeeded {
            guard let record = moved[result.messageID], let destination = result.destinationMailbox else {
                failures.append(RestoreFailure(messageID: result.messageID, reason: "no record of where it went"))
                continue
            }
            let dest = destination.split(separator: "/").map(String.init)
            let key = [record.accountID ?? "", dest.joined(separator: "\u{0}"), record.restorePath.joined(separator: "\u{0}")]
            if groups[key] == nil {
                groups[key] = (record.accountID, dest, record.restorePath, [])
                order.append(key)
            }
            groups[key]?.ids.append(result.messageID)
        }
        for key in order {
            guard let group = groups[key] else { continue }
            let argument: [String: Any] = [
                "action": "restore",
                "accountID": group.accountID.map { $0 as Any } ?? NSNull(),
                "destinationPath": group.destination,
                "restorePath": group.restore,
                "references": group.ids.map { ["messageID": $0, "storeRowID": NSNull()] as [String: Any] },
            ]
            let outcome = try await runScript(argument, ids: group.ids)
            for id in group.ids {
                if let r = outcome[id], r.succeeded {
                    moved[id] = nil
                } else {
                    failures.append(RestoreFailure(messageID: id, reason: outcome[id]?.error ?? "Mail error"))
                }
            }
        }
        Self.log.notice("restore: requested=\(results.count, privacy: .public) failed=\(failures.count, privacy: .public)")
        if !failures.isEmpty { throw MailActionError.restoreFailed(failures) }
    }

    // MARK: Trash, move, verify

    private func perform(action: String, messageIDs: [String], targetName: String?,
                         createIfMissing: Bool) async throws -> [MailActionResult] {
        let locations = await locate(messageIDs)
        var outcomes: [String: MailActionResult] = [:]
        var groups: [[String]: (address: JXAMailboxAddress, ids: [String])] = [:]
        var order: [[String]] = []
        for id in messageIDs where outcomes[id] == nil {
            guard let location = locations[id] else {
                outcomes[id] = MailActionResult(messageID: id, account: "", originalMailbox: "",
                                                succeeded: false, error: "its mailbox is unknown")
                continue
            }
            let address = MailboxResolver.jxaAddress(for: location.mailbox)
            let key = [address.accountID ?? ""] + address.path
            if groups[key] == nil { groups[key] = (address, []); order.append(key) }
            if !(groups[key]?.ids.contains(id) ?? false) { groups[key]?.ids.append(id) }
        }

        for key in order {
            guard let group = groups[key] else { continue }
            var argument: [String: Any] = [
                "action": action,
                "accountID": group.address.accountID.map { $0 as Any } ?? NSNull(),
                "path": group.address.path,
                "createIfMissing": createIfMissing,
                "references": group.ids.map { id in
                    ["messageID": id, "storeRowID": locations[id]?.storeRowID.map { $0 as Any } ?? NSNull()] as [String: Any]
                },
            ]
            if let targetName { argument["targetName"] = targetName }
            let results = try await runScript(argument, ids: group.ids)
            for (id, result) in results {
                outcomes[id] = result
                if action != "verify", result.succeeded {
                    moved[id] = Moved(accountID: group.address.accountID, restorePath: group.address.path)
                }
            }
        }
        // Counts only: never subjects, senders or bodies.
        let done = outcomes.values.filter(\.succeeded).count
        Self.log.notice("\(action, privacy: .public): requested=\(messageIDs.count, privacy: .public) succeeded=\(done, privacy: .public)")
        return messageIDs.map { outcomes[$0] ?? MailActionResult(messageID: $0, account: "", originalMailbox: "",
                                                                 succeeded: false, error: "Mail error") }
    }

    /// Runs the script for one group. A script-level failure fails the whole group but is not thrown.
    private func runScript(_ argument: [String: Any], ids: [String]) async throws -> [String: MailActionResult] {
        func failed(_ reason: String) -> [String: MailActionResult] {
            Dictionary(uniqueKeysWithValues: ids.map {
                ($0, MailActionResult(messageID: $0, account: "", originalMailbox: "", succeeded: false, error: reason))
            })
        }
        guard let url = scriptURL("MailActions") else { return failed("Mail error") }
        do {
            let data = try JSONSerialization.data(withJSONObject: argument, options: [.sortedKeys])
            let output = try await runner.run(script: url, argument: String(decoding: data, as: UTF8.self))
            let decoded = try JSONDecoder().decode(ScriptOutput.self, from: output)
            return Dictionary(decoded.results.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OsascriptError {
            // The case name only: a script error's stderr excerpt could quote mail content.
            Self.log.error("mail actions script failed: kind=\(Self.kind(of: error), privacy: .public)")
            switch error {
            case .automationDenied: return failed(MailActionFailure.automationDenied)
            case .mailNotRunning: return failed(MailActionFailure.mailNotRunning)
            case .timedOut: return failed(MailActionFailure.timedOut)
            default: return failed("Mail error")
            }
        } catch {
            Self.log.error("mail actions output unreadable")
            return failed("Mail error")
        }
    }

    private static func kind(of error: OsascriptError) -> String {
        switch error {
        case .automationDenied: return "automationDenied"
        case .mailNotRunning: return "mailNotRunning"
        case .timedOut: return "timedOut"
        case .scriptFailed: return "scriptFailed"
        case .launchFailed: return "launchFailed"
        case .scriptMissing: return "scriptMissing"
        }
    }

    private struct ScriptOutput: Decodable {
        var results: [MailActionResult]
    }
}
