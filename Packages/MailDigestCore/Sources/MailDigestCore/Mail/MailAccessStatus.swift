import Foundation

/// Result of probing whether Mail Digest can read Mail's local store.
public enum FullDiskAccessState: String, Sendable {
    case granted, denied, mailDataMissing, unsupportedStore, busy, unknown
}

/// Result of probing whether Mail Digest may send Apple Events to Mail.
public enum AutomationState: String, Sendable {
    case granted, denied, notDetermined, mailNotRunning, unknown
}

/// How Mail Digest will read mail given the current permissions.
public enum MailAccessMode: Sendable {
    case fastLocal, automationFallback, unavailable

    /// User-facing headline.
    public var title: String {
        switch self {
        case .fastLocal: return "Fast local access enabled"
        case .automationFallback: return "Using Mail automation fallback"
        case .unavailable: return "Mail access unavailable"
        }
    }
}

/// Combined permission snapshot and the UI decisions derived from it.
public struct MailAccessStatus: Sendable, Equatable {
    public static let fullDiskAccessSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    public static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    public var fullDiskAccess: FullDiskAccessState
    public var automation: AutomationState

    public init(fullDiskAccess: FullDiskAccessState, automation: AutomationState) {
        self.fullDiskAccess = fullDiskAccess
        self.automation = automation
    }

    public var mode: MailAccessMode {
        if fullDiskAccess == .granted { return .fastLocal }
        switch automation {
        case .granted, .notDetermined, .mailNotRunning: return .automationFallback
        case .denied, .unknown: return .unavailable
        }
    }

    /// Automation is still needed for Check for New Mail and per-message fallback, even with FDA.
    public var showsAutomationBanner: Bool { automation == .denied }
    public var showsFullDiskAccessNotice: Bool { fullDiskAccess != .granted }
    public var canRequestAutomation: Bool { automation == .notDetermined || automation == .mailNotRunning }
}
