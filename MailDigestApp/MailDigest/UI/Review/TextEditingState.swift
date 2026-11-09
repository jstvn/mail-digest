import AppKit

/// Whether a text field is being edited, so list shortcuts (⌫, Space, ⌘↑, ⌘↓) don't fire while the user types.
enum TextEditingState {
    @MainActor static var isEditing: Bool { NSApp.keyWindow?.firstResponder is NSText }
}
