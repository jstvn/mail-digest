import EventKit
import Foundation
import MailDigestCore
import os

/// What Reminders access allows, reduced to what the app acts on.
enum RemindersAuthorization: Sendable, Equatable {
    case notDetermined
    /// Full access: the only level that lets the app find, create and write its list.
    case granted
    /// Denied, restricted, or write-only (which can't read back the list).
    case unavailable
}

/// Failures the app reacts to specially.
enum RemindersError: Error, Equatable {
    case accessNotGranted
    /// No iCloud, CalDAV or local source can hold a new list.
    case noUsableSource
    /// The stored list id no longer exists (the user deleted the list).
    case listMissing
}

/// Writes approved suggestions to Apple Reminders through EventKit. An actor keeps the non-Sendable
/// `EKEventStore` confined to one isolation domain. It never logs notes or evidence.
actor EventKitReminderWriter: ReminderWriter {
    private let store = EKEventStore()
    private let timeZone: TimeZone
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "reminders")

    init(timeZone: TimeZone = ReminderDraft.defaultTimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Access

    nonisolated static func authorization() -> RemindersAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .unavailable // .denied, .restricted, .writeOnly
        }
    }

    /// Shows the system prompt when status is `.notDetermined`; returns whether full access is now granted.
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToReminders()
            Self.log.info("reminders access granted: \(granted, privacy: .public)")
            return granted
        } catch {
            Self.log.error("reminders access request failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: ReminderWriter

    func ensureList(named name: String, storedID: String?) async throws -> String {
        try requireAccess()
        if let storedID, let existing = store.calendar(withIdentifier: storedID), existing.allowsContentModifications,
           existing.allowedEntityTypes.contains(.reminder) {
            return existing.calendarIdentifier
        }
        // Missing: never created, or the user deleted it.
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        guard let source = newListSource() else { throw RemindersError.noUsableSource }
        list.source = source
        try store.saveCalendar(list, commit: true)
        Self.log.info("created reminders list \(list.calendarIdentifier, privacy: .public)")
        return list.calendarIdentifier
    }

    func renameList(id: String, to name: String) async throws {
        try requireAccess()
        guard let list = store.calendar(withIdentifier: id) else { throw RemindersError.listMissing }
        guard list.title != name else { return }
        list.title = name
        try store.saveCalendar(list, commit: true)
        Self.log.info("renamed reminders list \(id, privacy: .public)")
    }

    func write(_ suggestion: Suggestion, category: Category, email: EmailContext?,
               toList listID: String) async throws -> String {
        try requireAccess()
        guard let list = store.calendar(withIdentifier: listID) else { throw RemindersError.listMissing }
        let draft = ReminderDraft(suggestion, category: category, email: email, timeZone: timeZone)

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.url = draft.url
        reminder.priority = draft.priority
        if var due = draft.dueComponents {
            due.calendar = Calendar(identifier: .gregorian)
            // A timed due date is an absolute moment; a date-only one floats with the user's zone.
            if due.hour != nil { due.timeZone = timeZone }
            reminder.dueDateComponents = due
        }
        if let alarm = draft.alarmDate {
            reminder.addAlarm(EKAlarm(absoluteDate: alarm))
        }
        try store.save(reminder, commit: true)
        Self.log.info("wrote reminder \(reminder.calendarItemIdentifier, privacy: .public)")
        return reminder.calendarItemIdentifier
    }

    // MARK: Helpers

    private func requireAccess() throws {
        guard Self.authorization() == .granted else { throw RemindersError.accessNotGranted }
    }

    /// iCloud (the default list's source) first, then any CalDAV account, then the local store.
    private func newListSource() -> EKSource? {
        if let source = store.defaultCalendarForNewReminders()?.source { return source }
        return store.sources.first { $0.sourceType == .calDAV } ?? store.sources.first { $0.sourceType == .local }
    }
}
