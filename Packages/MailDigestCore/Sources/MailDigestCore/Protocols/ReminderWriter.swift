import Foundation

public protocol ReminderWriter: Sendable {
    /// Finds the app's list by its stored identifier, or creates it with this name. Returns the list id.
    func ensureList(named name: String, storedID: String?) async throws -> String
    /// Renames the app's list in place.
    func renameList(id: String, to name: String) async throws
    /// Writes one approved suggestion to the list and returns the reminder id. `email` supplies the sender and
    /// subject for the notes; it is nil only when the job's email rows are unavailable.
    func write(_ suggestion: Suggestion, category: Category, email: EmailContext?, toList listID: String) async throws -> String
}
