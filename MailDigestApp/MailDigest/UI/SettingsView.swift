import AppKit
import MailDigestCore
import SwiftUI

/// The tabs of the Settings window.
enum SettingsTab: Hashable {
    case general, mail, models, senders
}

/// Settings window: General, Mail, Models and Senders. `docs/MAC_TODO.md` lists which settings take effect when.
/// Job history is not a setting; it lives in Activity (Q78).
struct SettingsView: View {
    @Bindable var run: DigestRunModel
    let access: MailAccessModel

    var body: some View {
        TabView(selection: $run.settingsTab) {
            GeneralSettingsTab(run: run)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            MailSettingsTab(run: run, access: access)
                .tabItem { Label("Mail", systemImage: "envelope") }
                .tag(SettingsTab.mail)
            ModelsSettingsTab(run: run)
                .tabItem { Label("Models", systemImage: "sparkles") }
                .tag(SettingsTab.models)
            SendersSettingsTab(run: run)
                .tabItem { Label("Senders", systemImage: "person.2") }
                .tag(SettingsTab.senders)
        }
        .frame(width: 520)
    }
}

/// A toggle with a one-line explanation under its title, as the grouped rows in the design.
struct SubtitledToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: General

private struct GeneralSettingsTab: View {
    let run: DigestRunModel

    private var store: SettingsStore { run.settings }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                DatePicker("Run At", selection: $store.runTime, displayedComponents: .hourAndMinute)
                Picker("Look Back", selection: $store.settings.lookbackHours) {
                    ForEach(SettingsPresentation.lookbackOptions(current: store.settings.lookbackHours), id: \.self) {
                        Text(SettingsPresentation.lookbackTitle($0)).tag($0)
                    }
                }
                SubtitledToggle(title: "Limit Emails per Run",
                                subtitle: "Handy on slow days. Extra emails wait for the next run.", isOn: limitEnabled)
                if let limit = store.settings.maxEmailsPerRun {
                    Stepper(value: Binding(get: { limit }, set: { store.settings.maxEmailsPerRun = $0 }),
                            in: 10...1_000, step: 10) {
                        LabeledContent("Newest Emails per Run", value: "\(limit)")
                    }
                }
            } header: {
                Text("Daily Digest")
            } footer: {
                Text(SettingsPresentation.runAtFootnote(hour: store.settings.runHour, minute: store.settings.runMinute))
            }
            RemindersListSection(run: run)
            BackgroundWorkSection(store: store)
            Section("Startup") {
                LaunchAtLoginToggle()
            }
            Section("Sender Logos") {
                SubtitledToggle(title: "Show Sender Logos",
                                subtitle: "Fetches logos from senders' websites. They can see your IP address.",
                                isOn: $store.settings.showSenderLogos)
            }
            HistorySection(run: run)
        }
        .formStyle(.grouped)
        .frame(height: 720)
    }

    private var limitEnabled: Binding<Bool> {
        Binding(get: { run.settings.settings.maxEmailsPerRun != nil },
                set: { run.settings.settings.maxEmailsPerRun = $0 ? 100 : nil })
    }
}

/// Where approved reminders go. Choosing a list only points new reminders at it: the list itself is never
/// renamed or changed. Without Reminders access the lists can't be read, so the name is shown instead.
private struct RemindersListSection: View {
    let run: DigestRunModel

    private var reminders: RemindersAccessModel { run.reminders }
    private var name: String { run.settings.settings.resolvedListName }

    /// The id of the real list in use, or nil when none has been chosen or created yet (or it was deleted).
    private var selectedID: String? {
        guard let id = reminders.storedListID, reminders.lists.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        @Bindable var store = run.settings
        Section {
            if reminders.status == .granted {
                Picker("Add Reminders To", selection: Binding(get: { selectedID }, set: { choose($0) })) {
                    // Until a list exists, the named list is made the first time something is added.
                    if selectedID == nil { Text("\(name) (New List)").tag(String?.none) }
                    ForEach(reminders.lists) { Text($0.title).tag(Optional($0.id)) }
                }
            } else {
                LabeledContent("Add Reminders To", value: name)
                accessRow
            }
            Toggle(isOn: $store.settings.autoAddSuggestedReminders) {
                Text("Add Suggested Reminders Automatically")
            }
            Picker("Reminder Date", selection: $store.settings.reminderDateMode) {
                Text("Plan Ahead on the Day It Arrives").tag(ReminderDateMode.planToday)
                Text("Deadline from Email").tag(ReminderDateMode.emailDeadline)
            }
            DatePicker(planTimeTitle, selection: planTime, displayedComponents: .hourAndMinute)
                .accessibilityLabel(planTimeTitle)
        } header: {
            Text("Reminders")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.settings.autoAddSuggestedReminders
                     ? "Only preselected suggestions from the daily digest. Payment requests from new senders always wait for your review."
                     : "Nothing is added until you press Add to Reminders, unless you turn on automatic adding.")
                Text(store.settings.reminderDateMode == .planToday
                     ? "Reminders are due at this time on the day they\u{2019}re added, or the next day if it has passed. The email\u{2019}s deadline stays in the title. Times use Brisbane time."
                     : "Reminders use the deadline from the email. Reminders without a deadline are due at this time, on the day they\u{2019}re added or the next day. Times use Brisbane time.")
            }
        }
        .onAppear { reminders.refresh() }
    }

    private var store: SettingsStore { run.settings }

    private var planTimeTitle: String {
        store.settings.reminderDateMode == .planToday ? "Remind At" : "Undated Reminders At"
    }

    /// The plan time as a time-of-day picker value over the stored hour and minute.
    private var planTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: store.settings.reminderPlanHour,
                                      minute: store.settings.reminderPlanMinute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                store.settings.reminderPlanHour = parts.hour ?? ReminderDatePolicy.defaultPlanHour
                store.settings.reminderPlanMinute = parts.minute ?? ReminderDatePolicy.defaultPlanMinute
            })
    }

    private func choose(_ id: String?) {
        guard let id, let option = reminders.lists.first(where: { $0.id == id }) else { return }
        reminders.chooseList(option, settings: run.settings)
    }

    @ViewBuilder private var accessRow: some View {
        if reminders.status == .notDetermined {
            LabeledContent {
                Button("Allow Access…") { Task { await run.reminders.request() } }
            } label: {
                Text("Mail Digest needs Reminders access to show your lists. Until then, new reminders go to a list named \"\(name)\".")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent {
                Button("Open Reminders Settings…") {
                    if let url = URL(string: PanelAlert.remindersSettingsURL) { NSWorkspace.shared.open(url) }
                }
            } label: {
                Text("Reminders access is off, so your lists can't be shown. New reminders go to a list named \"\(name)\".")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Power and run-window rules for Backlog jobs (the window is where they may run, Q45). Low Power Mode and
/// serious heat always pause them, so they have no switch here. The time pickers show only when the toggle is on.
private struct BackgroundWorkSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Section {
            Toggle("Pause on Battery", isOn: $store.settings.pauseBacklogOnBattery)
            SubtitledToggle(
                title: "Only Run Overnight",
                subtitle: SettingsPresentation.overnightSubtitle(startMinute: store.settings.quietHoursStartMinute,
                                                                 endMinute: store.settings.quietHoursEndMinute),
                isOn: $store.settings.quietHoursEnabled)
            if store.settings.quietHoursEnabled {
                DatePicker("From", selection: minuteBinding(\.quietHoursStartMinute), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minuteBinding(\.quietHoursEndMinute), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Background Work")
        } footer: {
            Text("Backlog jobs also pause in Low Power Mode or when your Mac gets hot, then pick up again by themselves. The Daily digest only pauses in Low Power Mode. The time window uses Brisbane time.")
        }
    }

    /// A time-of-day picker over stored minutes after midnight.
    private func minuteBinding(_ keyPath: WritableKeyPath<DigestSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = store.settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                store.settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}

/// History retention and "Delete All History…", which goes through the same retention path as the daily
/// cleanup: pinned items and unfinished jobs stay, Mail and Reminders are never touched.
private struct HistorySection: View {
    let run: DigestRunModel
    @State private var confirming = false
    @State private var isDeleting = false
    @State private var result: DeleteHistoryResult?

    var body: some View {
        @Bindable var store = run.settings
        Section {
            Picker("Keep Digests and Activity For", selection: $store.settings.retention) {
                ForEach(SettingsPresentation.retentionChoices, id: \.self) {
                    Text(SettingsPresentation.retentionTitle($0)).tag($0)
                }
            }
            LabeledContent {
                Button("Delete All History…") { confirming = true }
                    .disabled(isDeleting)
            } label: {
                if let result {
                    switch result {
                    case .success(let text):
                        Label(text, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    case .failure(let text):
                        Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Digest History")
        } footer: {
            Text("Covers past digests, the Logbook and Activity, stored only on this Mac. Pinned items, unfinished jobs, processed-email records and sender rules are kept, and nothing in Mail or Reminders changes.")
        }
        .confirmationDialog("Delete all history?", isPresented: $confirming) {
            Button("Delete All History", role: .destructive) {
                isDeleting = true
                result = nil
                Task {
                    result = await run.deleteAllHistory()
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Past digests, suggestions and finished jobs will be removed. Pinned items, unfinished jobs, emails in Mail and reminders are kept. This can't be undone.")
        }
    }
}

// MARK: Mail

private struct MailSettingsTab: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openWindow) private var openWindow

    private var store: SettingsStore { run.settings }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                statusRow
                LabeledContent("Daily Digest Reads", value: DailyMailboxSelection.summary(
                    stored: store.settings.dailyMailboxes, available: run.mailboxes))
            } header: {
                Text("Mail Access")
            } footer: {
                Text("Choose which mailboxes the daily digest reads in Mail Access.")
            }
            Section {
                SubtitledToggle(
                    title: "File Handled Emails",
                    subtitle: "Once every suggestion from an email is added or dismissed, it moves to the Mail Digest mailbox or Trash in the same account.",
                    isOn: $store.settings.autoFileProcessed)
                if store.settings.autoFileProcessed {
                    destinationPicker(
                        "Reminders Added or Info Only",
                        subtitle: "Emails with at least one reminder added, or with nothing to act on.",
                        selection: $store.settings.autoFileHandledDestination)
                    destinationPicker(
                        "All Suggestions Dismissed",
                        subtitle: "Emails where you dismissed every suggestion.",
                        selection: $store.settings.autoFileDismissedDestination)
                }
            } header: {
                Text("Mail Cleanup")
            } footer: {
                Text("Only mail handled after you turn this on is moved. Nothing is deleted: Trash keeps mail until Mail empties it. You can undo from Mail Cleanup until you quit.")
            }
        }
        .formStyle(.grouped)
        .frame(height: store.settings.autoFileProcessed ? 540 : 400)
        .task {
            await access.refresh()
            if canLoadMailboxes, run.mailboxes.isEmpty { await run.loadMailboxes() }
        }
    }

    private func destinationPicker(_ title: String, subtitle: String,
                                   selection: Binding<AutoFileDestination>) -> some View {
        Picker(selection: selection) {
            Text("Mail Digest Mailbox").tag(AutoFileDestination.mailDigest)
            Text("Trash").tag(AutoFileDestination.trash)
        } label: {
            Text(title)
            Text(subtitle)
        }
    }

    /// Listing mailboxes in automation mode needs the Automation grant, so never load before it.
    private var canLoadMailboxes: Bool {
        guard let status = access.status else { return false }
        return status.mode == .fastLocal || status.automation == .granted
    }

    @ViewBuilder private var statusRow: some View {
        LabeledContent {
            Button("Mail Access…") {
                openWindow(id: "mail-access")
                NSApp.activate()
            }
        } label: {
            if let status = access.status {
                let summary = MailAccessPresentation(status).settingsSummary
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(summary.isReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8).padding(.top, 5).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                        Text(summary.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Checking…").foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettingsTab(run: PreviewSupport.run())
}

#Preview("Mail") {
    let status = MailAccessStatus(fullDiskAccess: .granted, automation: .granted)
    MailSettingsTab(run: PreviewSupport.run(), access: MailAccessModel(preview: status, checkedAt: .now))
}

#Preview("Mail, slower mode") {
    let status = MailAccessStatus(fullDiskAccess: .denied, automation: .granted)
    MailSettingsTab(run: PreviewSupport.run(), access: MailAccessModel(preview: status, checkedAt: .now))
}
#endif
