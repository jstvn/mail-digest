import Foundation
import MailDigestCore
import Observation

/// Observable permission state for the menu and the Mail Access window.
@MainActor @Observable
final class MailAccessModel {
    private(set) var status: MailAccessStatus?
    private(set) var isChecking = false
    @ObservationIgnored private let probe = MailPermissionProbe()

    /// Re-probes both permissions off the main actor.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        status = await probe.status()
    }

    /// Shows the Automation prompt (only on user request), then refreshes.
    func requestAutomation() async {
        guard !isChecking else { return }
        isChecking = true
        _ = await probe.requestAutomation()
        isChecking = false
        await refresh()
    }
}
