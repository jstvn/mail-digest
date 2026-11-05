import MailDigestCore
import SwiftUI

/// Settings window. Everything here is stored now; `docs/MAC_TODO.md` lists which settings take effect when.
struct SettingsView: View {
    let run: DigestRunModel

    var body: some View {
        TabView {
            GeneralSettingsTab(run: run)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettingsTab(store: run.settings)
                .tabItem { Label("Model & Reminders", systemImage: "sparkles") }
            SendersSettingsTab(store: run.settings)
                .tabItem { Label("Senders", systemImage: "person.2") }
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: General

private struct GeneralSettingsTab: View {
    let run: DigestRunModel

    private var store: SettingsStore { run.settings }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Daily digest") {
                DatePicker("Run at", selection: runTime, displayedComponents: .hourAndMinute)
                Stepper(value: $store.settings.lookbackHours, in: 12...336, step: 12) {
                    LabeledContent("Look back", value: "\(store.settings.lookbackHours) hours")
                }
                Toggle("Limit emails per run", isOn: limitEnabled)
                if let limit = store.settings.maxEmailsPerRun {
                    Stepper(value: Binding(get: { limit }, set: { store.settings.maxEmailsPerRun = $0 }),
                            in: 10...1_000, step: 10) {
                        LabeledContent("Newest emails per run", value: "\(limit)")
                    }
                }
            }
            Section("History") {
                Picker("Keep history for", selection: $store.settings.retention) {
                    Text("30 days").tag(HistoryRetention.thirtyDays)
                    Text("90 days").tag(HistoryRetention.ninetyDays)
                    Text("1 year").tag(HistoryRetention.oneYear)
                    Text("Forever").tag(HistoryRetention.forever)
                }
            }
            MailboxesSection(run: run)
        }
        .formStyle(.grouped)
    }

    /// The scheduler arrives later; the time is only stored for now.
    private var runTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: run.settings.settings.runHour,
                                      minute: run.settings.settings.runMinute, second: 0, of: .now) ?? .now
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                run.settings.settings.runHour = parts.hour ?? 6
                run.settings.settings.runMinute = parts.minute ?? 30
            })
    }

    private var limitEnabled: Binding<Bool> {
        Binding(get: { run.settings.settings.maxEmailsPerRun != nil },
                set: { run.settings.settings.maxEmailsPerRun = $0 ? 100 : nil })
    }
}

/// Daily mailboxes: all inboxes by default, or a chosen set.
private struct MailboxesSection: View {
    let run: DigestRunModel

    private var chosen: [MailboxRef] { run.settings.settings.dailyMailboxes }

    var body: some View {
        Section("Daily mailboxes") {
            Toggle("All inboxes", isOn: Binding(
                get: { chosen.isEmpty },
                set: { allInboxes in
                    if allInboxes {
                        run.settings.settings.dailyMailboxes = []
                    } else {
                        // Start from the inboxes so turning this off doesn't change what runs.
                        run.settings.settings.dailyMailboxes = run.mailboxes.filter { $0.kind == .inbox }.map(\.ref)
                        Task { await run.loadMailboxes() }
                    }
                }))
            if !chosen.isEmpty {
                if run.isLoadingMailboxes {
                    ProgressView("Loading mailboxes…")
                } else if run.mailboxes.isEmpty {
                    Text(run.mailboxError ?? "Mailboxes appear once Mail access is allowed.")
                        .foregroundStyle(.secondary)
                    Button("Load Mailboxes") { Task { await run.loadMailboxes() } }
                }
                ForEach(selectable, id: \.ref) { box in
                    Toggle(isOn: binding(for: box.ref)) {
                        Text("\(box.ref.account) · \(box.ref.name)")
                    }
                }
            }
        }
    }

    /// Sent, Drafts, Junk and Trash are hidden; processing them rarely makes sense.
    private var selectable: [MailboxInfo] {
        run.mailboxes.filter { ![.sent, .drafts, .junk, .trash].contains($0.kind) }
            .sorted { ($0.ref.account, $0.ref.name) < ($1.ref.account, $1.ref.name) }
    }

    private func binding(for ref: MailboxRef) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(ref) },
            set: { on in
                var list = chosen
                if on { if !list.contains(ref) { list.append(ref) } } else { list.removeAll { $0 == ref } }
                // An empty list would mean "all inboxes", so keep at least one mailbox.
                if !list.isEmpty { run.settings.settings.dailyMailboxes = list }
            })
    }
}

// MARK: Model and Reminders

private struct ModelSettingsTab: View {
    let store: SettingsStore

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextField("Ollama URL", text: $store.settings.ollamaURL, prompt: Text(DigestSettings.defaultOllamaURL))
                    .textContentType(.URL)
                if URL(string: store.settings.ollamaURL.trimmingCharacters(in: .whitespaces))?.host == nil {
                    Text("This isn't a valid URL, so the default is used.")
                        .font(.caption).foregroundStyle(.red)
                }
                TextField("Model", text: $store.settings.ollamaModel, prompt: Text(DigestSettings.defaultModel))
            } header: {
                Text("Ollama")
            } footer: {
                Text("Changes apply to the next run.").foregroundStyle(.secondary)
            }
            Section {
                TextField("List name", text: $store.settings.remindersListName,
                          prompt: Text(DigestSettings.defaultListName))
            } header: {
                Text("Reminders")
            } footer: {
                Text("Approved reminders go into this list.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Senders

private struct SendersSettingsTab: View {
    let store: SettingsStore

    var body: some View {
        @Bindable var store = store
        Form {
            SenderListSection(title: "VIP senders", footer: "Always get a full summary.",
                              list: $store.settings.vipSenders)
            SenderListSection(title: "Blocked senders", footer: "Never read.",
                              list: $store.settings.blockedSenders)
            SenderListSection(title: "Ignored senders", footer: "Skipped without a summary.",
                              list: $store.settings.ignoredSenders)
            SenderListSection(title: "Trusted newsletter senders",
                              footer: "Newsletters from these senders can suggest reminders.",
                              list: $store.settings.trustedNewsletterSenders)
        }
        .formStyle(.grouped)
    }
}

/// A list of email addresses with an add field and a remove button per row.
private struct SenderListSection: View {
    let title: String
    let footer: String
    @Binding var list: [String]
    @State private var draft = ""

    var body: some View {
        Section {
            ForEach(list, id: \.self) { address in
                HStack {
                    Text(address)
                    Spacer()
                    Button {
                        list.removeAll { $0 == address }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(address)")
                    .accessibilityLabel("Remove \(address)")
                }
            }
            HStack {
                TextField("Add address", text: $draft, prompt: Text("name@example.com"))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(normalised.isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer).foregroundStyle(.secondary)
        }
    }

    private var normalised: String { MailFilter.address(from: draft) }

    private func add() {
        let address = normalised
        guard address.contains("@"), !list.contains(address) else { return }
        list.append(address)
        draft = ""
    }
}
