import AppKit
import MailDigestCore
import SwiftUI

/// Explains Mail permissions, lets the user fix them, and chooses which mailboxes the daily digest reads.
struct MailAccessView: View {
    let model: MailAccessModel
    let run: DigestRunModel
    /// This window, so only its own focus changes trigger a re-check.
    @State private var window: NSWindow?
    @State private var showsOthers = false

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.status {
                let info = MailAccessPresentation(status)
                Form {
                    Section { header(info.header) }
                    permissions(info)
                    dailyReads
                }
                .formStyle(.grouped)
            } else {
                ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 560)
        .background(WindowReader(window: $window))
        .task { await model.refresh() }
        .onChange(of: canLoadMailboxes, initial: true) { _, can in
            if can, run.mailboxes.isEmpty { Task { await run.loadMailboxes() } }
        }
        // Coming back from System Settings makes this window key again. Other windows' focus is ignored.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window, (note.object as? NSWindow) === window else { return }
            Task { await model.refresh() }
        }
    }

    // MARK: Header

    private func header(_ state: MailAccessPresentation.Header) -> some View {
        HStack(alignment: .top, spacing: 14) {
            TintedSymbolTile(symbol: state.symbol, tint: state.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.title2.weight(.semibold))
                Text(state.subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Permissions

    private func permissions(_ info: MailAccessPresentation) -> some View {
        Section {
            permissionRow(symbol: "internaldrive", title: "Full Disk Access",
                          subtitle: "Reads Mail's database directly. Fastest for large mailboxes.",
                          status: info.fullDiskAccessText, color: info.fullDiskAccessOn ? .green : .orange) {
                if info.showsGrantAccess {
                    Button("Grant Access…") { open(MailAccessStatus.fullDiskAccessSettingsURL) }
                        .buttonStyle(.borderedProminent)
                        .help("Opens Privacy & Security in System Settings, where you turn on Full Disk Access for Mail Digest.")
                }
            }
            permissionRow(symbol: "arrow.triangle.2.circlepath", title: "Mail Automation",
                          subtitle: "Opens emails in Mail and moves them during Mail Cleanup.",
                          status: info.automationText, color: info.automationAllowed ? .green : .orange) {
                switch info.automationAction {
                case .none: EmptyView()
                case .request:
                    Button("Allow…") { Task { await model.requestAutomation() } }
                        .help("Asks macOS to let Mail Digest control Mail.")
                case .openSettings:
                    Button("Allow…") { open(MailAccessStatus.automationSettingsURL) }
                        .help("Opens Privacy & Security in System Settings, where you turn on Mail under Mail Digest.")
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            if info.showsPermissionFootnote {
                Text("After you turn on Mail Digest in Privacy & Security, come back here. This window updates by itself.")
            }
        }
    }

    private func permissionRow<Action: View>(symbol: String, title: String, subtitle: String, status: String,
                                             color: Color, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StatusDot(text: status, color: color)
            action()
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Daily Digest Reads

    /// Listing mailboxes in automation mode needs the Automation grant, so never load before it.
    private var canLoadMailboxes: Bool {
        guard let status = model.status else { return false }
        return status.mode == .fastLocal || status.automation == .granted
    }

    private var stored: [MailboxRef] { run.settings.settings.dailyMailboxes }
    private var selected: Set<MailboxRef> { DailyMailboxSelection.effective(stored: stored, available: run.mailboxes) }

    @ViewBuilder private var dailyReads: some View {
        Section {
            if !canLoadMailboxes {
                Text("Allow Mail access first to see your mailboxes.").foregroundStyle(.secondary)
            } else if run.mailboxes.isEmpty {
                if run.isLoadingMailboxes {
                    ProgressView("Loading mailboxes…")
                } else {
                    Text(run.mailboxError ?? "No mailboxes found in Mail.").foregroundStyle(.secondary)
                }
            } else {
                let rows = DailyMailboxSelection.rows(run.mailboxes)
                ForEach(rows.inboxes) { row in mailboxToggle(row, symbol: "tray") }
                if rows.otherCount > 0 {
                    DisclosureGroup(isExpanded: $showsOthers) {
                        ForEach(rows.others) { account in
                            ForEach(account.rows) { row in mailboxToggle(row, symbol: "folder") }
                        }
                    } label: {
                        HStack {
                            Text("Show Other Mailboxes")
                            Spacer()
                            Text(rows.otherCount, format: .number).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Daily Digest Reads")
        } footer: {
            Text("Empty folders, Junk, Sent and Deleted mail are hidden. Backlog jobs can still pick any mailbox.")
        }
    }

    private func mailboxToggle(_ row: MailboxTreeRow, symbol: String) -> some View {
        let ref = row.info.ref
        let isOn = selected.contains(ref)
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { on in
                // Takes effect on the next run: the run model rebuilds its runner when this setting changes.
                run.settings.settings.dailyMailboxes = DailyMailboxSelection.toggled(
                    ref, on: on, stored: stored, available: run.mailboxes)
            })) {
            HStack {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(MailboxTree.displayTitle(row)) + Text(" · \(ref.account)").foregroundStyle(.secondary)
                Spacer()
                Text(row.info.messageCount, format: .number).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isOn && !DailyMailboxSelection.canUntick(ref, stored: stored, available: run.mailboxes))
        .help(isOn && !DailyMailboxSelection.canUntick(ref, stored: stored, available: run.mailboxes)
              ? "The daily digest needs at least one mailbox." : "")
        .accessibilityLabel(DailyMailboxSelection.label(row))
        .accessibilityValue(Text("\(row.info.messageCount) emails"))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(MailAccessCheckedText.text(checkedAt: model.lastChecked, now: context.date, calendar: run.library.calendar))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check Again") {
                Task {
                    await model.refresh()
                    if canLoadMailboxes { await run.loadMailboxes() }
                }
            }
            .disabled(model.isChecking)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

/// Reports the hosting `NSWindow` so the view can tell its own key-window changes from other windows'.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if window !== view.window { window = view.window } }
    }
}

#if DEBUG
private let previewMailboxes: [MailboxInfo] = [
    MailboxInfo(ref: MailboxRef(account: "iCloud", name: "INBOX"), messageCount: 2555, unreadCount: 0, kind: .inbox),
    MailboxInfo(ref: MailboxRef(account: "Outlook", name: "Inbox"), messageCount: 1075, unreadCount: 0, kind: .inbox),
    MailboxInfo(ref: MailboxRef(account: "iCloud", name: "Archive"), messageCount: 900, unreadCount: 0, kind: .archive),
    MailboxInfo(ref: MailboxRef(account: "Outlook", name: "Receipts"), messageCount: 40, unreadCount: 0, kind: .custom),
    MailboxInfo(ref: MailboxRef(account: "iCloud", name: "Sent"), messageCount: 300, unreadCount: 0, kind: .sent),
]

#Preview("Ready") {
    MailAccessView(model: MailAccessModel(preview: MailAccessStatus(fullDiskAccess: .granted, automation: .granted),
                                          checkedAt: Date()),
                   run: DigestRunModel(preview: SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
                                       mailboxes: previewMailboxes))
        .frame(width: 480, height: 560)
}

#Preview("Limited") {
    MailAccessView(model: MailAccessModel(preview: MailAccessStatus(fullDiskAccess: .denied, automation: .granted),
                                          checkedAt: Date()),
                   run: DigestRunModel(preview: SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
                                       mailboxes: previewMailboxes))
        .frame(width: 480, height: 560)
}
#endif
