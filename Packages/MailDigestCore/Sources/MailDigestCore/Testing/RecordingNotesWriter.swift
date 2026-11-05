import Foundation

/// A `NotesWriter` that records entries instead of touching Notes; can be told to fail.
public actor RecordingNotesWriter: NotesWriter {
    public private(set) var entries: [NotesEntry] = []
    private let failure: (any Error)?

    public init(failure: (any Error)? = nil) { self.failure = failure }

    public func append(_ entry: NotesEntry) async throws {
        if let failure { throw failure }
        entries.append(entry)
    }
}
