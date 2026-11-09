import Foundation
import IOKit.pwr_mgt

/// Holds one power assertion that stops idle system sleep (not display sleep) while an overnight job works.
/// `set(_:)` is idempotent, so callers can pass the current decision on every change without leaking or
/// double-creating an assertion. The system also drops it if the process exits.
@MainActor
final class IdleSleepAssertion {
    static let shared = IdleSleepAssertion()

    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var isHeld = false

    /// True while the assertion is held (for tests and diagnostics).
    var isActive: Bool { isHeld }

    /// Creates the assertion when `hold` is true and none exists; releases it when false.
    func set(_ hold: Bool) {
        if hold { acquire() } else { release() }
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        isHeld = false
    }

    private func acquire() {
        guard !isHeld else { return }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Mail Digest is running an overnight job" as CFString,
            &id)
        guard result == kIOReturnSuccess else { return }
        assertionID = id
        isHeld = true
    }
}
