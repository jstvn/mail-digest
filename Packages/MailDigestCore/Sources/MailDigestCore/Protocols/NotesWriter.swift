import Foundation

/// Appends an info summary to the "Mail Digest" note in Notes. Only ever called from an explicit click.
public protocol NotesWriter: Sendable {
    func append(_ entry: NotesEntry) async throws
}
