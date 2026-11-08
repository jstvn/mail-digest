import Testing
@testable import MailDigestCore

@Suite struct DockVisibilityTests {
    @Test func firstOpenSwitchesToRegular() {
        var v = DockVisibility()
        #expect(v.windowDidOpen(current: .accessory) == .regular)
    }

    @Test func repeatedOpenIsIgnored() {
        var v = DockVisibility()
        _ = v.windowDidOpen(current: .accessory)
        #expect(v.windowDidOpen(current: .regular) == nil)
        #expect(v.windowDidClose() == .accessory)
    }

    @Test func closeRestoresRememberedRegular() {
        var v = DockVisibility()
        _ = v.windowDidOpen(current: .regular)
        #expect(v.windowDidClose() == .regular)
    }

    @Test func unbalancedCloseReturnsNil() {
        var v = DockVisibility()
        #expect(v.windowDidClose() == nil)
        _ = v.windowDidOpen(current: .accessory)
        _ = v.windowDidClose()
        #expect(v.windowDidClose() == nil)
    }

    @Test func reopenAfterCloseReapplies() {
        var v = DockVisibility()
        _ = v.windowDidOpen(current: .accessory)
        _ = v.windowDidClose()
        #expect(v.windowDidOpen(current: .accessory) == .regular)
    }
}

@Suite struct DockVisibilityCycleTests {
    @Test func repeatedCyclesRestoreEachTime() {
        var v = DockVisibility()
        for _ in 1...6 {
            #expect(v.windowDidOpen(current: .accessory) == .regular)
            #expect(v.windowDidClose() == .accessory)
        }
    }

    @Test func repeatedCyclesRestoreRememberedRegular() {
        var v = DockVisibility()
        for _ in 1...5 {
            #expect(v.windowDidOpen(current: .regular) == .regular)
            #expect(v.windowDidClose() == .regular)
        }
    }

    @Test func openCloseOpenThenClose() {
        var v = DockVisibility()
        #expect(v.windowDidOpen(current: .accessory) == .regular)
        #expect(v.windowDidClose() == .accessory)
        #expect(v.windowDidOpen(current: .accessory) == .regular)
        #expect(v.windowDidClose() == .accessory)
    }

    @Test func noEventsBetweenOpenAndCloseKeepsState() {
        // Minimise or in-window navigation produce no events, so the state is unchanged.
        var v = DockVisibility()
        _ = v.windowDidOpen(current: .accessory)
        let snapshot = v
        #expect(v == snapshot)
        #expect(v.windowDidClose() == .accessory)
    }
}
