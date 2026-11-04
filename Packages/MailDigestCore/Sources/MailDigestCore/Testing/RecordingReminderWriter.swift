import Foundation

/// Errors thrown by `RecordingReminderWriter`.
public enum RecordingReminderError: Error, Sendable, Equatable {
    case unknownList(String)
    case writeFailed
}

/// One recorded `write` call.
public struct WrittenReminder: Sendable, Equatable {
    public var suggestion: Suggestion
    public var category: Category
    public var listID: String
}

/// `ReminderWriter` fake that records lists, renames and writes.
public actor RecordingReminderWriter: ReminderWriter {
    public private(set) var lists: [String: String]
    public private(set) var createdLists: [String] = []
    public private(set) var renames: [(id: String, name: String)] = []
    public private(set) var written: [WrittenReminder] = []
    public var failingSuggestionIDs: Set<UUID>
    private var listCounter = 0
    private var reminderCounter = 0

    public init(lists: [String: String] = [:], failingSuggestionIDs: Set<UUID> = []) {
        self.lists = lists
        self.failingSuggestionIDs = failingSuggestionIDs
    }

    public func setFailingSuggestionIDs(_ ids: Set<UUID>) { failingSuggestionIDs = ids }

    /// Simulates the user deleting the list in Reminders.
    public func deleteList(id: String) { lists[id] = nil }

    public func ensureList(named name: String, storedID: String?) async throws -> String {
        if let storedID, lists[storedID] != nil { return storedID }
        listCounter += 1
        let id = "list-\(listCounter)"
        lists[id] = name
        createdLists.append(id)
        return id
    }

    public func renameList(id: String, to name: String) async throws {
        guard lists[id] != nil else { throw RecordingReminderError.unknownList(id) }
        lists[id] = name
        renames.append((id: id, name: name))
    }

    public func write(_ suggestion: Suggestion, category: Category, toList listID: String) async throws -> String {
        if failingSuggestionIDs.contains(suggestion.id) { throw RecordingReminderError.writeFailed }
        reminderCounter += 1
        written.append(WrittenReminder(suggestion: suggestion, category: category, listID: listID))
        return "rem-\(reminderCounter)"
    }
}
