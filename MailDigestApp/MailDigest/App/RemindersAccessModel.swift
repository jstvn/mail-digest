import Foundation
import MailDigestCore
import Observation
import OSLog

/// Tracks Reminders permission, hands the EventKit writer to the review window only when full access is
/// granted, and remembers which Reminders list new reminders go to.
@MainActor @Observable
final class RemindersAccessModel {
    private(set) var status: RemindersAuthorization
    /// The user's Reminders lists, for the Review Queue inspector's List picker. Empty until access is granted.
    private(set) var lists: [ReminderListOption] = []
    /// The id of the list new reminders go to, or nil until one has been chosen or created. Kept in step with
    /// the `remindersListID` default, which the cross-digest coordinator also writes after creating a list.
    private(set) var storedListID: String?

    @ObservationIgnored private let writer: EventKitReminderWriter?
    @ObservationIgnored private weak var coordinator: ReviewCoordinator?
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "reminders")

    init(writer: EventKitReminderWriter = EventKitReminderWriter()) {
        self.writer = writer
        self.status = EventKitReminderWriter.authorization()
        self.storedListID = UserDefaults.standard.string(forKey: ReviewViewModel.listIDKey)
    }

    /// Previews: a fixed status and no EventKit.
    init(preview status: RemindersAuthorization, lists: [ReminderListOption] = []) {
        self.writer = nil
        self.status = status
        self.lists = lists
    }

    /// Connects the cross-digest coordinator, which writes approvals, and applies the current status to it.
    func attach(coordinator: ReviewCoordinator) {
        self.coordinator = coordinator
        apply()
    }

    /// Re-reads the system status, so granting access in System Settings works without a relaunch.
    func refresh() {
        guard writer != nil else { return }
        storedListID = UserDefaults.standard.string(forKey: ReviewViewModel.listIDKey)
        status = EventKitReminderWriter.authorization()
        apply()
    }

    /// Shows the system permission prompt (only meaningful while `.notDetermined`).
    func request() async {
        guard let writer else { return }
        _ = await writer.requestAccess()
        refresh()
    }

    /// Makes new reminders go to an existing list. Only the stored id and the fallback name change; the list in
    /// Reminders is never renamed or modified. The name is only used if the list is deleted and has to be recreated.
    func chooseList(_ option: ReminderListOption, settings: SettingsStore) {
        UserDefaults.standard.set(option.id, forKey: ReviewViewModel.listIDKey)
        storedListID = option.id
        settings.settings.remindersListName = option.title
    }

    private func apply() {
        let granted: (any ReminderWriter)? = status == .granted ? writer : nil
        coordinator?.setReminderWriter(granted)
        loadLists()
    }

    /// Re-reads the lists whenever the status is applied (launch, window focus, a permission change).
    private func loadLists() {
        guard let writer, status == .granted else { lists = []; return }
        Task { lists = await writer.availableLists() }
    }
}
