import Foundation
import MailDigestCore
import Observation
import OSLog

/// Where an info card's "Save to Notes" stands.
enum NotesSaveState: Equatable {
    case idle, saving, saved
    case failed(String)
}

/// "Save to Notes" for info cards, shared by the latest-digest panel and the cross-digest coordinator.
@MainActor @Observable
final class NotesSaver {
    /// Progress per info id.
    private(set) var states: [String: NotesSaveState] = [:]
    @ObservationIgnored var writer: any NotesWriter = AppleScriptNotesWriter()
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

    init() {}

    /// Previews: records instead of talking to Notes.
    init(preview writer: any NotesWriter) { self.writer = writer }

    /// Runs only from a click. Logs success or failure, never the text.
    func save(_ item: InfoItem, email: EmailContext?, date: Date) async {
        guard states[item.id] != .saving else { return }
        let entry = NotesEntry.make(for: item, email: email, date: date)
        states[item.id] = .saving
        do {
            try await writer.append(entry)
            Self.log.notice("save to notes: succeeded")
            states[item.id] = .saved
            try? await Task.sleep(for: .seconds(3))
            if states[item.id] == .saved { states[item.id] = nil }
        } catch {
            Self.log.error("save to notes: failed")
            states[item.id] = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? OsascriptError {
        case .automationDenied:
            return "Notes access is turned off. Allow Mail Digest to control Notes in System Settings > Privacy & Security > Automation."
        case .timedOut:
            return "Notes did not respond. Try again."
        default:
            return "Could not save to Notes."
        }
    }
}
