import MailDigestCore
import SwiftUI

/// Senders: VIP, Blocked, Ignored and Newsletters, one list at a time. `MailFilter` matches a sender's full
/// email address, so each row is an address; whole domains aren't supported and so aren't offered.
struct SendersSettingsTab: View {
    let run: DigestRunModel

    @State private var list: SenderList = .vip
    @State private var selection: String?
    @State private var showsAdd = false
    @State private var showsRecent = false

    private var store: SettingsStore { run.settings }

    var body: some View {
        Form {
            Section {
                Picker("Sender List", selection: $list) {
                    ForEach(SenderList.allCases) { kind in
                        Text("\(kind.title) \(store.settings.senders(in: kind).count)").tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(list.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                listBox
            } footer: {
                Text(SenderList.precedenceFootnote + " Tip: right-click a suggestion or summary in the review window to add its sender.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onChange(of: list) { selection = nil }
        .sheet(isPresented: $showsRecent) {
            RecentSendersSheet(run: run, list: list) { addresses in
                var settings = store.settings
                for address in addresses { settings.add(sender: address, to: list) }
                store.settings = settings
                showsRecent = false
            } cancel: {
                showsRecent = false
            }
        }
    }

    private var addresses: [String] { store.settings.senders(in: list) }

    private var listBox: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(addresses, id: \.self) { address in
                    row(address).tag(address)
                }
            }
            .listStyle(.plain)
            .frame(height: 220)
            .overlay {
                if addresses.isEmpty {
                    Text("No \(list.title.lowercased()) senders")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("This list is empty")
                }
            }
            .onDeleteCommand(perform: removeSelected)
            Divider()
            HStack(spacing: 0) {
                Button { showsAdd = true } label: {
                    Image(systemName: "plus").frame(width: 28, height: 24)
                }
                .help("Add an email address")
                .accessibilityLabel("Add Address")
                .popover(isPresented: $showsAdd, arrowEdge: .bottom) {
                    AddAddressPopover(list: list, store: store) { showsAdd = false }
                }
                Divider().frame(height: 16)
                Button(action: removeSelected) {
                    Image(systemName: "minus").frame(width: 28, height: 24)
                }
                .disabled(selection == nil)
                .help("Remove the selected address")
                .accessibilityLabel("Remove Selected Address")
                Spacer()
                Button("Add from Recent Senders…") { showsRecent = true }
                    .buttonStyle(.link)
                    .padding(.trailing, 10)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)
        }
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ address: String) -> some View {
        HStack(spacing: 10) {
            SenderAvatar(sender: address, size: .small)
            Text(address).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            // An entry saved before addresses were checked, such as a bare domain, never matches mail.
            if !DigestSettings.isMatchableAddress(address) {
                Text("Won't Match").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DigestSettings.isMatchableAddress(address)
                            ? address : "\(address), won't match any email")
        .contextMenu {
            Button("Remove", role: .destructive) { remove(address) }
        }
    }

    private func removeSelected() {
        if let selection { remove(selection) }
    }

    private func remove(_ address: String) {
        var settings = store.settings
        settings.remove(address, from: list)
        store.settings = settings
        if selection == address { selection = nil }
    }
}

/// Types one address onto the current list. Whole domains are explained, not accepted.
private struct AddAddressPopover: View {
    let list: SenderList
    let store: SettingsStore
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isValid: Bool { DigestSettings.isMatchableAddress(text) }
    private var isDuplicate: Bool { isValid && store.settings.contains(sender: text, in: list) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to \(list.title)").font(.headline)
            TextField("Email address", text: $text, prompt: Text("name@example.com"))
                .labelsHidden()
                .focused($focused)
                .onSubmit(add)
                .frame(width: 240)
            if isDuplicate {
                Text("Already on this list.").font(.callout).foregroundStyle(.secondary)
            } else if !text.isEmpty && !isValid {
                Text("Enter a full email address. Whole domains aren't supported.")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(!isValid || isDuplicate)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }

    private func add() {
        guard isValid, !isDuplicate else { return }
        var settings = store.settings
        settings.add(sender: text, to: list)
        store.settings = settings
        done()
    }
}

/// "Add from Recent Senders…": senders from the mail this app has already read, most frequent first. Reads only
/// what is stored on this Mac.
private struct RecentSendersSheet: View {
    let run: DigestRunModel
    let list: SenderList
    let add: ([String]) -> Void
    let cancel: () -> Void

    @State private var senders: [RecentSender] = []
    @State private var isLoading = true
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to \(list.title)").font(.headline)
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if senders.isEmpty {
                    ContentUnavailableView("No Recent Senders", systemImage: "person.2",
                                           description: Text("Senders appear here after Mail Digest has read some mail."))
                } else {
                    List(senders, selection: $chosen) { sender in
                        HStack(spacing: 10) {
                            SenderAvatar(sender: sender.name == sender.address ? sender.address : "\(sender.name) <\(sender.address)>",
                                         size: .small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sender.name)
                                if sender.name != sender.address {
                                    Text(sender.address).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(sender.count) \(sender.count == 1 ? "email" : "emails")")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(sender.address)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(height: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { add(senders.map(\.address).filter(chosen.contains)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            senders = await run.recentSenders(excluding: list)
            isLoading = false
        }
    }
}

#if DEBUG
#Preview("Senders") {
    let run = PreviewSupport.run()
    run.settings.settings.vipSenders = ["jacob@example.com", "philip@example.com"]
    run.settings.settings.ignoredSenders = ["deals@shop.example", "@legacy.example"]
    return SendersSettingsTab(run: run)
}
#endif
