import Foundation
import MailDigestCore

/// A banner above the panel content. Several can show at once (for example the FDA notice and a Reminders notice).
enum PanelAlert: Identifiable, Equatable {
    /// A run problem, such as Ollama being down or the model missing. Retry re-runs or resumes the job.
    case runProblem(String)
    case mailAutomationDenied
    case fullDiskAccessFallback
    case remindersUnavailable

    var id: String {
        switch self {
        case .runProblem: return "run"
        case .mailAutomationDenied: return "automation"
        case .fullDiskAccessFallback: return "fda"
        case .remindersUnavailable: return "reminders"
        }
    }

    static let remindersSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"

    /// The banners that apply right now, most urgent first.
    @MainActor
    static func current(run: DigestRunModel, access: MailAccessModel, remindersAvailable: Bool) -> [PanelAlert] {
        var alerts: [PanelAlert] = []
        if let banner = run.banner { alerts.append(.runProblem(banner)) }
        if let status = access.status {
            if status.showsAutomationBanner { alerts.append(.mailAutomationDenied) }
            if status.fullDiskAccess == .denied { alerts.append(.fullDiskAccessFallback) }
        }
        if !remindersAvailable { alerts.append(.remindersUnavailable) }
        return alerts
    }
}
