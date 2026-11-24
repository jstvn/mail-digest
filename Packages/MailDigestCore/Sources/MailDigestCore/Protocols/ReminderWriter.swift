import Foundation

public protocol ReminderWriter: Sendable {
    /// Finds the app's list by its stored identifier, or creates it with this name. Returns the list id.
    func ensureList(named name: String, storedID: String?) async throws -> String
    /// Renames the app's list in place.
    func renameList(id: String, to name: String) async throws
    /// Whether a list with this id still exists and accepts new reminders.
    func listExists(id: String) async -> Bool
    /// Writes one approved suggestion to the list and returns the reminder id. `email` supplies the sender and
    /// subject for the notes; it is nil only when the job's email rows are unavailable. `datePolicy` and `now` pick
    /// the written due date and alarm (Q101).
    func write(_ suggestion: Suggestion, category: Category, email: EmailContext?, toList listID: String,
               datePolicy: ReminderDatePolicy, now: Date) async throws -> String
}

extension ReminderWriter {
    /// Writers that can't check a list report it as present, so a missing list surfaces as a write failure.
    public func listExists(id: String) async -> Bool { true }
}
