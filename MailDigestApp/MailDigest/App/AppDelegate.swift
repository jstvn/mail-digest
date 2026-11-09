import AppKit

/// Hooks the Dock-presence controller into launch and handles Dock icon clicks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        WindowPresenceController.shared.start()
    }

    /// A Dock click with no real window opens the review window. The flag is ignored because
    /// non-window items (status bar) can make it true.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !WindowPresenceController.shared.hasRealWindows {
            NotificationRouter.shared.requestOpenReview()
            return false
        }
        return true
    }
}
