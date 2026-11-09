import Foundation
import MailDigestCore
import Observation

/// Observable permission state for the menu and the Mail Access window.
@MainActor @Observable
final class MailAccessModel {
    private(set) var status: MailAccessStatus?
    private(set) var isChecking = false
    /// When the last probe finished.
    private(set) var lastChecked: Date?
    /// Previews keep their fixed snapshot instead of probing the real Mac.
    @ObservationIgnored private var isFixed = false
    /// Set when a check was requested while one was running, so the newest state is never missed.
    @ObservationIgnored private var recheckQueued = false
    @ObservationIgnored private let probe = MailPermissionProbe()

    init() {}

    /// Previews: a fixed permission snapshot.
    init(preview status: MailAccessStatus?, checkedAt: Date? = nil) {
        self.status = status
        self.lastChecked = checkedAt
        self.isFixed = true
    }

    /// Re-probes both permissions off the main actor.
    /// A call during a running check queues one more pass instead of racing it: the user may have just
    /// granted access, and the running probe could have read the old state.
    func refresh() async {
        guard !isFixed else { return }
        if isChecking { recheckQueued = true; return }
        isChecking = true
        defer { isChecking = false }
        repeat {
            recheckQueued = false
            status = await probe.status()
            lastChecked = Date()
        } while recheckQueued
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
