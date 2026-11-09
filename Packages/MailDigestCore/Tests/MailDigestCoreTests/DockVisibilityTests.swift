import Testing
@testable import MailDigestCore

@Suite struct DockVisibilityTests {
    @Test func windowsOpenFromAccessorySwitchToRegular() {
        #expect(DockVisibility.change(current: .accessory, realWindowCount: 1) == .regular)
    }

    @Test func windowsOpenWhileRegularChangesNothing() {
        #expect(DockVisibility.change(current: .regular, realWindowCount: 3) == nil)
    }

    @Test func lastWindowClosedSwitchesToAccessory() {
        #expect(DockVisibility.change(current: .regular, realWindowCount: 0) == .accessory)
    }

    @Test func noWindowsWhileAccessoryChangesNothing() {
        #expect(DockVisibility.change(current: .accessory, realWindowCount: 0) == nil)
    }

    @Test func openCloseSequence() {
        let counts = [0, 1, 2, 1, 0, 1]
        let expected: [DockPolicy?] = [nil, .regular, nil, nil, .accessory, .regular]
        var current = DockPolicy.accessory
        for (count, want) in zip(counts, expected) {
            let change = DockVisibility.change(current: current, realWindowCount: count)
            #expect(change == want)
            if let change { current = change }
        }
    }
}
