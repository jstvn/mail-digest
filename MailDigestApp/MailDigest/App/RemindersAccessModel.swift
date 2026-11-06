import Foundation
import MailDigestCore
import Observation
import OSLog

/// Tracks Reminders permission, hands the EventKit writer to the review panel only when full access is
/// granted, and renames the app's list when the user changes its name in Settings.
@MainActor @Observable
final class RemindersAccessModel {
    private(set) var status: RemindersAuthorization

    @ObservationIgnored private let writer: EventKitReminderWriter?
    @ObservationIgnored private weak var review: ReviewViewModel?
    @ObservationIgnored private weak var coordinator: ReviewCoordinator?
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "reminders")

    init(writer: EventKitReminderWriter = EventKitReminderWriter()) {
        self.writer = writer
        self.status = EventKitReminderWriter.authorization()
    }

    /// Previews: a fixed status and no EventKit.
    init(preview status: RemindersAuthorization) {
        self.writer = nil
        self.status = status
    }

    /// Connects the review panel and applies the current status to it.
    func attach(review: ReviewViewModel) {
        self.review = review
        apply()
    }

    /// Connects the cross-digest coordinator, which writes approvals with the same writer.
    func attach(coordinator: ReviewCoordinator) {
        self.coordinator = coordinator
        apply()
    }

    /// Re-reads the system status, so granting access in System Settings works without a relaunch.
    func refresh() {
        guard writer != nil else { return }
        status = EventKitReminderWriter.authorization()
        apply()
    }

    /// Shows the system permission prompt (only meaningful while `.notDetermined`).
    func request() async {
        guard let writer else { return }
        _ = await writer.requestAccess()
        refresh()
    }

    /// Renames the stored list after the user commits a new name. A deleted list clears the stored id so
    /// the next approval recreates it.
    func renameList(to name: String) async {
        guard let writer, status == .granted,
              let id = UserDefaults.standard.string(forKey: ReviewViewModel.listIDKey) else { return }
        do {
            try await writer.renameList(id: id, to: name)
        } catch RemindersError.listMissing {
            UserDefaults.standard.removeObject(forKey: ReviewViewModel.listIDKey)
        } catch {
            Self.log.error("could not rename list: \(String(describing: error), privacy: .public)")
        }
    }

    private func apply() {
        let granted: (any ReminderWriter)? = status == .granted ? writer : nil
        review?.setReminderWriter(granted)
        coordinator?.setReminderWriter(granted)
    }
}
