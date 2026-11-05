import Foundation
import MailDigestCore
import Observation
import OSLog
import UserNotifications

/// Posts user notifications through `UNUserNotificationCenter`. The text comes from the pipeline
/// (for example "6 suggestions ready") and never contains email bodies.
struct UserNotifier: Notifier {
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "notifications")

    init() { NotificationRouter.install() }

    /// Asks for permission. Only shows the system prompt while the status is not determined.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func post(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        var status = await Self.authorizationStatus()
        // Ask lazily if onboarding was skipped.
        if status == .notDetermined {
            await Self.requestAuthorization()
            status = await Self.authorizationStatus()
        }
        guard status == .authorized || status == .provisional else {
            Self.log.notice("notification not posted: not authorised")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Mail Digest"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do { try await center.add(request) } catch {
            Self.log.error("could not post notification: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Receives notification clicks and tells the app to open the review panel.
@MainActor @Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    /// Incremented on each click; the App opens the review panel when it changes.
    private(set) var openReviewRequests = 0

    @ObservationIgnored private let delegate = Delegate()

    /// Makes this router the notification center's delegate. UNUserNotificationCenter holds it weakly,
    /// so the router keeps the delegate alive.
    nonisolated static func install() {
        Task { @MainActor in UNUserNotificationCenter.current().delegate = shared.delegate }
    }

    fileprivate func requestOpenReview() { openReviewRequests += 1 }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// Show the banner even while Mail Digest is frontmost.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            await MainActor.run { NotificationRouter.shared.requestOpenReview() }
        }
    }
}
