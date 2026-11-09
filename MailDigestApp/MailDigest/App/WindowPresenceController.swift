import AppKit
import MailDigestCore

/// Keeps the Dock icon in step with the app's real windows: `.regular` while any is open, `.accessory`
/// (menu bar only) otherwise.
@MainActor
final class WindowPresenceController {
    static let shared = WindowPresenceController()
    private var started = false

    /// Starts observing window events. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowsChanged(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowsChanged(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        // Windows can also go away or come back without either event above: `orderOut` (no willClose) changes
        // occlusion state, and unhiding or deminiaturising a window does not always make it key.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(windowsChanged(_:)), name: name, object: nil)
        }
    }

    /// True while a real window is open. Also true when the app is hidden (Cmd-H), as hidden windows report not visible.
    var hasRealWindows: Bool { NSApp.isHidden || realWindowCount > 0 }

    // Selector-based observer: delivered on the posting thread, which is the main thread for window events.
    @objc private nonisolated func windowsChanged(_ note: Notification) {
        // Next run loop turn, so a window that is closing is no longer visible when counted.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    private var realWindowCount: Int { NSApp.windows.filter(Self.isRealWindow).count }

    /// Excludes panels (menu bar panel, popovers), sheets and the status bar window.
    private static func isRealWindow(_ window: NSWindow) -> Bool {
        // isMiniaturized: a minimised window is not visible, but dropping to .accessory would strand it without a Dock tile.
        window.canBecomeMain && !(window is NSPanel) && !window.isSheet
            && (window.isVisible || window.isMiniaturized)
    }

    private func reevaluate() {
        if NSApp.isHidden { return }
        let current: DockPolicy = NSApp.activationPolicy() == .regular ? .regular : .accessory
        guard let policy = DockVisibility.change(current: current, realWindowCount: realWindowCount) else { return }
        NSApp.setActivationPolicy(policy == .regular ? .regular : .accessory)
        // The policy flip can leave the window behind other apps.
        if policy == .regular { NSApp.activate() }
    }
}
