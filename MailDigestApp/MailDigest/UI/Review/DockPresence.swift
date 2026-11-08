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

/// Invisible background view that ties `DockPresence` to the hosting NSWindow's real lifetime
/// (minimising and in-window navigation do not post willClose).
struct DockPresenceModifier: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackerView { TrackerView() }
    func updateNSView(_ nsView: TrackerView, context: Context) {}

    final class TrackerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            DockPresence.shared.windowDidOpen()
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let o = self?.observer { NotificationCenter.default.removeObserver(o) }
                    self?.observer = nil
                    DockPresence.shared.windowDidClose()
                }
            }
        }
    }
}
