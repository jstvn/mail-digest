import AppKit
import MailDigestCore
import SwiftUI
import UserNotifications

/// First-run setup: one scrolling form, every step optional. Nothing here blocks finishing.
struct OnboardingView: View {
    /// UserDefaults key set once the user has seen onboarding.
    static let completedKey = "didCompleteOnboarding"

    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        @Bindable var store = run.settings
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Mail Digest reads your new mail each morning, summarises it with a model running on this Mac, and suggests reminders for you to approve. Nothing leaves this Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Welcome")
                }
                OllamaSetupSection(run: run)
                mailSection
                remindersSection
                notificationsSection
                Section("Daily Digest") {
                    TextField("Reminders list", text: $store.settings.remindersListName,
                              prompt: Text(DigestSettings.defaultListName))
                    DatePicker("Run At", selection: $store.runTime, displayedComponents: .hourAndMinute)
                    LaunchAtLoginToggle()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Run Now") { finish(runNow: true) }
                    .disabled(run.isRunning)
                Button("Done") { finish(runNow: false) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 640)
        .task {
            await access.refresh()
            run.reminders.refresh()
            notificationStatus = await UserNotifier.authorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await access.refresh()
                run.reminders.refresh()
                notificationStatus = await UserNotifier.authorizationStatus()
            }
        }
        // Closing the window any way counts as seen; onboarding never returns uninvited.
        .onDisappear { UserDefaults.standard.set(true, forKey: Self.completedKey) }
    }

    // MARK: Steps

    private var mailSection: some View {
        Section {
            if let mail = access.status {
                switch mail.automation {
                case .granted:
                    status("checkmark.circle.fill", .green, "Allowed", "Mail Digest can read Mail.")
                case .denied:
                    status("xmark.circle.fill", .red, "Not allowed", "Enable Mail access for Mail Digest in Automation settings.")
                    Button("Open Automation Settings…") { open(MailAccessStatus.automationSettingsURL) }
                default:
                    status("exclamationmark.triangle.fill", .yellow, "Not requested yet", "Not requested yet.")
                }
                if mail.canRequestAutomation {
                    Button("Allow Mail Access…") { Task { await access.requestAutomation() } }
                }
            } else {
                ProgressView("Checking…")
            }
            Button("Mail Access Options…") {
                openWindow(id: "mail-access")
                NSApp.activate()
            }
        } header: {
            Text("Mail")
        } footer: {
            Text("Full Disk Access is optional and makes reading large mailboxes faster. Mail Access Options explains it.")
        }
    }

    private var remindersSection: some View {
        Section {
            switch run.reminders.status {
            case .granted:
                status("checkmark.circle.fill", .green, "Allowed", "Mail Digest can add the reminders you approve.")
            case .notDetermined:
                Button("Allow Reminders Access…") { Task { await run.reminders.request() } }
            default:
                status("xmark.circle.fill", .red, "Not allowed", "Allow Reminders in Privacy & Security settings.")
                Button("Open Reminders Settings…") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Nothing is added until you approve it in the review panel.")
        }
    }

    private var notificationsSection: some View {
        Section {
            switch notificationStatus {
            case .authorized, .provisional, .ephemeral:
                status("checkmark.circle.fill", .green, "Allowed", "You'll be told when a digest is ready.")
            case .notDetermined:
                Button("Allow Notifications…") {
                    Task {
                        await UserNotifier.requestAuthorization()
                        notificationStatus = await UserNotifier.authorizationStatus()
                    }
                }
            default:
                status("xmark.circle.fill", .red, "Not allowed", "Allow notifications for Mail Digest in System Settings.")
                Button("Open Notification Settings…") { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Used only to say how many suggestions are ready.")
        }
    }

    // MARK: Helpers

    private func status(_ symbol: String, _ color: Color, _ label: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color).accessibilityLabel(label)
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func finish(runNow: Bool) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
        guard runNow else { return }
        openWindow(id: "review")
        NSApp.activate()
        Task { await run.runNow() }
    }
}
