import AppKit
import MailDigestCore
import SwiftUI

/// Shows the Dock icon while the review window exists, restoring the previous policy when it really closes.
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private var visibility = DockVisibility()

    private var current: DockPolicy { NSApp.activationPolicy() == .regular ? .regular : .accessory }

    func windowDidOpen() {
        guard let policy = visibility.windowDidOpen(current: current) else { return }
        apply(policy)
        // The policy flip can leave the window behind other apps.
        NSApp.activate()
    }

    func windowDidClose() {
        guard let policy = visibility.windowDidClose() else { return }
        apply(policy)
    }

    private func apply(_ policy: DockPolicy) {
        NSApp.setActivationPolicy(policy == .regular ? .regular : .accessory)
    }
}

/// Ties `DockPresence` to the review window. SwiftUI reuses the same NSWindow and content view across
/// close and reopen, so open is signalled by the content's `.onAppear` (once per open; not on minimise or
/// in-window navigation) and close by `willCloseNotification`, which stays observed for the window's lifetime.
private struct DockPresenceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { DockPresence.shared.windowDidOpen() }
            .background(WindowCloseObserver { DockPresence.shared.windowDidClose() })
    }
}

extension View {
    /// Shows the Dock icon while this window is open. Apply once to the window's root view.
    func dockPresence() -> some View { modifier(DockPresenceModifier()) }
}

/// Invisible view that reports `willClose` of its hosting window. It is not removed on close because
/// the same window is reused on reopen.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }
    func updateNSView(_ nsView: TrackerView, context: Context) { nsView.onClose = onClose }

    final class TrackerView: NSView {
        var onClose: (@MainActor () -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Selector-based registration: removing first guarantees a single registration, NotificationCenter
            // holds no strong reference to self, and it is dropped automatically on deinit.
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }

        @objc private func windowWillClose(_ note: Notification) { onClose?() }
    }
}
