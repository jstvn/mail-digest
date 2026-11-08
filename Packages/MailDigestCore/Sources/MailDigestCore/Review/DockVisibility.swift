import Foundation

/// The two Dock behaviours the app switches between (mirrors NSApplication.ActivationPolicy without AppKit).
public enum DockPolicy: Sendable, Equatable {
    /// Menu bar agent: no Dock icon.
    case accessory
    /// Regular app: Dock icon and Cmd-Tab entry.
    case regular
}

/// Tracks whether the review window is open and which Dock policy to restore when it closes.
public struct DockVisibility: Sendable, Equatable {
    private var restoreTo: DockPolicy?

    public init() {}

    /// Returns `.regular` to apply on the first open (remembering `current`); a repeated open returns nil.
    public mutating func windowDidOpen(current: DockPolicy) -> DockPolicy? {
        guard restoreTo == nil else { return nil }
        restoreTo = current
        return .regular
    }

    /// Returns the remembered policy to restore; a close without a matching open returns nil.
    public mutating func windowDidClose() -> DockPolicy? {
        defer { restoreTo = nil }
        return restoreTo
    }
}
