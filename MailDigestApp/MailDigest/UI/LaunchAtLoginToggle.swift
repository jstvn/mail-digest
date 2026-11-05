import AppKit
import ServiceManagement
import SwiftUI

/// "Launch at login" backed by `SMAppService.mainApp`. The system status is the source of truth, so nothing
/// is stored in the app's settings. Used by Settings and onboarding.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorText: String?

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { set($0) }))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        if status == .requiresApproval {
            Text("macOS needs your approval before Mail Digest can open at login.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let errorText {
            Text(errorText).font(.callout).foregroundStyle(.red)
        }
    }

    private func refresh() { status = SMAppService.mainApp.status }

    private func set(_ on: Bool) {
        errorText = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorText = "Could not change the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}
