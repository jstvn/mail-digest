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
