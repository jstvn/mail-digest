import Foundation
import MailDigestCore

/// The script ran but reported that it could not write the note.
enum NotesWriteError: Error, Sendable, Equatable {
    case rejected
}

/// Appends to the "Mail Digest" note by running `SaveToNotes.js` through `osascript`. The entry travels as a
/// JSON argument, never inside the script source. Errors never include the entry's text.
struct AppleScriptNotesWriter: NotesWriter {
    private let runner: any JXARunning
    private let scriptURL: @Sendable () -> URL?

    init(runner: any JXARunning = OsascriptRunner(),
         scriptURL: @escaping @Sendable () -> URL? = { Bundle.main.url(forResource: "SaveToNotes", withExtension: "js") }) {
        self.runner = runner
        self.scriptURL = scriptURL
    }

    func append(_ entry: NotesEntry) async throws {
        guard let url = scriptURL() else { throw OsascriptError.scriptMissing("SaveToNotes") }
        let argument = String(decoding: try JSONEncoder().encode(["html": entry.html]), as: UTF8.self)
        let output = try await runner.run(script: url, argument: argument)
        struct Reply: Decodable { var ok: Bool }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: output), reply.ok else {
            throw NotesWriteError.rejected
        }
    }
}
