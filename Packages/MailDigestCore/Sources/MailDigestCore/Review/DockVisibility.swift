import Foundation

/// The two Dock behaviours the app switches between (mirrors NSApplication.ActivationPolicy without AppKit).
public enum DockPolicy: Sendable, Equatable {
    /// Menu bar agent: no Dock icon.
    case accessory
    /// Regular app: Dock icon and Cmd-Tab entry.
    case regular
}

/// Decides the Dock policy from how many real windows are open.
public enum DockVisibility {
    /// Returns the policy to apply (`.regular` with any real window, else `.accessory`),
    /// or nil when `current` already matches.
    public static func change(current: DockPolicy, realWindowCount: Int) -> DockPolicy? {
        let wanted: DockPolicy = realWindowCount > 0 ? .regular : .accessory
        return wanted == current ? nil : wanted
    }
}
