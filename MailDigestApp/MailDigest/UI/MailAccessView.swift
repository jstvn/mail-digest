import AppKit
import MailDigestCore
import SwiftUI

/// Explains Mail permissions and lets the user fix them. Compact settings-style window.
struct MailAccessView: View {
    let model: MailAccessModel
    let run: DigestRunModel

    var body: some View {
        Form {
            Section {
                Text("Mail Digest reads your new mail on this Mac to summarise it and suggest reminders. Nothing leaves this Mac. Full Disk Access enables fast local reads of the Mail database and message files. Without it, Mail Digest asks Mail through automation, which is slower for large mailboxes.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.status {
                Section {
                    Label(status.mode.title, systemImage: "envelope")
                        .font(.headline)
                    if status.showsAutomationBanner {
                        Label {
                            Text("Mail Automation is turned off. Open Automation Settings and enable Mail access for Mail Digest.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            // Only the symbol is tinted; yellow body text would be hard to read.
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        }
                    }
                }
                Section("Full Disk Access") {
                    row(symbol: fdaSymbol(status.fullDiskAccess), text: fdaText(status.fullDiskAccess))
                    if status.showsFullDiskAccessNotice {
                        Button("Open Full Disk Access Settings…") { open(MailAccessStatus.fullDiskAccessSettingsURL) }
                        Text("After changing Full Disk Access, quit and reopen Mail Digest.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Mail Automation") {
                    row(symbol: autoSymbol(status.automation), text: autoText(status.automation))
                    if status.canRequestAutomation {
                        Button("Allow Mail Access…") { Task { await model.requestAutomation() } }
                    }
                    if status.automation == .denied {
                        Button("Open Automation Settings…") { open(MailAccessStatus.automationSettingsURL) }
                    }
                }
            } else {
                Section { ProgressView("Checking…") }
            }
            mailboxSection
            Section {
                HStack {
                    Spacer()
                    Button("Check Again") { Task { await model.refresh() } }
                        .disabled(model.isChecking)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await model.refresh()
            if canLoadMailboxes, run.mailboxes.isEmpty { await run.loadMailboxes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    /// Listing mailboxes in automation mode needs the Automation grant, so never load before it.
    private var canLoadMailboxes: Bool {
        guard let status = model.status else { return false }
        return status.mode == .fastLocal || status.automation == .granted
    }

    private var mailboxGroups: [(account: String, boxes: [MailboxInfo])] {
        Dictionary(grouping: run.mailboxes, by: { $0.ref.account })
            .map { (account: $0.key, boxes: $0.value.sorted { $0.ref.name < $1.ref.name }) }
            .sorted { $0.account < $1.account }
    }

    @ViewBuilder private var mailboxSection: some View {
        if canLoadMailboxes {
            ForEach(mailboxGroups, id: \.account) { group in
                Section(group.account) {
                    ForEach(group.boxes, id: \.ref) { box in
                        HStack {
                            if box.kind == .inbox {
                                Image(systemName: "tray").accessibilityLabel("Inbox")
                            }
                            Text(box.ref.name)
                            Spacer()
                            Text(box.messageCount, format: .number)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Mailboxes") {
                if run.isLoadingMailboxes {
                    ProgressView("Loading mailboxes…")
                } else if let error = run.mailboxError {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    Text("Daily runs read every inbox (\(run.inboxCount))")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh") { Task { await run.loadMailboxes() } }
                    .disabled(run.isLoadingMailboxes)
            }
        } else if model.status != nil {
            Section("Mailboxes") {
                Text("Allow Mail access first to see your mailboxes.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(symbol: (name: String, color: Color, label: String), text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol.name).foregroundStyle(symbol.color)
                .accessibilityLabel(symbol.label)
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func fdaSymbol(_ s: FullDiskAccessState) -> (name: String, color: Color, label: String) {
        switch s {
        case .granted: return ("checkmark.circle.fill", .green, "Granted")
        case .denied: return ("xmark.circle.fill", .red, "Not granted")
        default: return ("exclamationmark.triangle.fill", .yellow, "Warning")
        }
    }

    private func fdaText(_ s: FullDiskAccessState) -> String {
        switch s {
        case .granted: return "Granted. Mail Digest can read the Mail database directly."
        case .denied: return "Not granted. Mail Digest will use Mail automation instead."
        case .mailDataMissing: return "Mail data not found. Open Mail and set up an account."
        case .unsupportedStore: return "This version of Mail's database is not supported."
        case .busy: return "Mail is busy. Try again in a moment."
        case .unknown: return "Could not be determined."
        }
    }

    private func autoSymbol(_ s: AutomationState) -> (name: String, color: Color, label: String) {
        switch s {
        case .granted: return ("checkmark.circle.fill", .green, "Granted")
        case .denied: return ("xmark.circle.fill", .red, "Not granted")
        default: return ("exclamationmark.triangle.fill", .yellow, "Warning")
        }
    }

    private func autoText(_ s: AutomationState) -> String {
        switch s {
        case .granted: return "Allowed. Mail Digest can ask Mail for messages."
        case .denied: return "Not allowed. Enable Mail access for Mail Digest in Automation settings."
        case .notDetermined: return "Not requested yet."
        case .mailNotRunning: return "Mail is not running. It will be opened when needed."
        case .unknown: return "Could not be determined."
        }
    }
}
