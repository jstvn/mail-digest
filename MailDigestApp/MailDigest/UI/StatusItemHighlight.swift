import AppKit

/// Keeps the menu bar icon highlighted while the `.window`-style `MenuBarExtra` panel is open, as a native
/// menu does. SwiftUI doesn't highlight the status item for window-style extras, so this finds the app's
/// `NSStatusBarButton` (public API, looked up through the app's own windows) and sets its highlight.
@MainActor
enum StatusItemHighlight {
    static func set(_ highlighted: Bool) {
        for window in NSApp.windows {
            guard let content = window.contentView, let button = statusButton(in: content) else { continue }
            button.highlight(highlighted)
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = statusButton(in: sub) { return found }
        }
        return nil
    }
}
