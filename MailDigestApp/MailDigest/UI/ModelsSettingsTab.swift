import AppKit
import MailDigestCore
import SwiftUI

// MARK: Disclosure text and sheets

/// The facts users must see before and after enabling Cloud Digest (Q63). Shared by the What Gets Sent sheet and
/// the acknowledgement sheet so the two never drift apart.
private struct CloudDisclosureText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Emails the app classifies as eligible have their subject, sender, date and cleaned text sent to Google. Private or uncertain mail, mail that was not fully inspected, and anything the privacy check cannot confirm stays on this Mac.")
            Text("**Unpaid quota:** Google uses submitted content and responses to improve its products, and human reviewers may read and annotate them. Google's terms say not to submit sensitive, confidential or personal information to unpaid services.")
            Text("**Paid quota** (a Google Cloud project with active billing): Google does not use prompts or responses to improve its products, but logs them for a limited time for abuse prevention, safety, security and legal purposes.")
            Text("The app cannot tell which quota your project uses, and a successful Test Connection does not show it. Using a project with active billing is recommended for email.")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sheet shown the first time Cloud Digest is switched on (and again when the disclosure revision rises).
private struct CloudAcknowledgementSheet: View {
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send eligible emails to Google?")
                .font(.headline)
            CloudDisclosureText()
                .font(.body)
                .textSelection(.enabled)
            Link("Gemini API Additional Terms", destination: CloudPrivacyPolicy.termsURL)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("I Understand, Use Gemini", action: accept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// "What Gets Sent…": the full disclosure, unchanged, and how the privacy threshold decides.
private struct WhatGetsSentSheet: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What Gets Sent")
                .font(.headline)
            CloudDisclosureText()
                .textSelection(.enabled)
            Text("An email is sent to Google only if the privacy check is at least as confident as the Privacy Threshold that it is non-sensitive, and at least 85% confident it is a public newsletter or promotion. Scores are model confidences, not guarantees.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: CloudPrivacyPolicy.termsURL) {
                Label("Gemini API Terms", systemImage: "arrow.up.forward.app")
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Edit URL…: the Ollama address, validated as it always was (an http or https address with a host).
private struct EditOllamaURLSheet: View {
    @Binding var url: String
    let done: () -> Void
    @State private var draft = ""

    private var isBlank: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isValid: Bool { isBlank || DigestSettings.usableOllamaURL(draft) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ollama URL").font(.headline)
            TextField("Ollama URL", text: $draft, prompt: Text(DigestSettings.defaultOllamaURL))
                .labelsHidden()
                .textContentType(.URL)
                .onSubmit(save)
            if !isValid {
                Text("This isn't a valid URL. Use an address such as \(DigestSettings.defaultOllamaURL).")
                    .font(.callout).foregroundStyle(.red)
            } else {
                Text("Leave it blank to use \(DigestSettings.defaultOllamaURL). Changes apply from the next run.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { draft = url }
    }

    private func save() {
        guard isValid else { return }
        url = draft.trimmingCharacters(in: .whitespaces)
        done()
    }
}

/// Another Gemini model ID, for a model the Cloud Model popup doesn't list.
private struct CustomModelSheet: View {
    @Binding var model: String
    let done: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cloud Model ID").font(.headline)
            TextField("Model ID", text: $draft, prompt: Text(GeminiDefaults.model))
                .labelsHidden()
                .onSubmit(save)
            Text("Leave it blank to use \(GeminiDefaults.model). Use Test Connection after changing the key or model.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { draft = model }
    }

    private func save() {
        model = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        done()
    }
}

/// Change… (or Add…): a secure field for the Gemini key, Test Connection and Save. The key lives only in this
/// sheet's state until it is saved to the Keychain; it is never logged or shown.
private struct APIKeySheet: View {
    let run: DigestRunModel
    let hasKey: Bool
    let modelID: String
    let saved: () -> Void
    let connected: () -> Void
    let cancel: () -> Void

    private enum TestState: Equatable {
        case idle, running, finished(GeminiConnectionResult)
    }

    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var test = TestState.idle

    private var trimmed: String { keyInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(hasKey ? "Change API Key" : "Add API Key").font(.headline)
            SecureField("API Key", text: $keyInput, prompt: Text("Paste your Gemini API key"))
                .labelsHidden()
                .onSubmit(save)
                .accessibilityLabel("Gemini API Key")
            Text("The key is saved in the Keychain on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            if let keyError {
                Label(keyError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            testRows
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        // A result describes one key; drop it when the key changes.
        .onChange(of: keyInput) { test = .idle }
    }

    @ViewBuilder private var testRows: some View {
        HStack {
            Button("Test Connection", action: runTest)
                .disabled(test == .running || (trimmed.isEmpty && !hasKey))
            if test == .running {
                ProgressView().controlSize(.small).accessibilityLabel("Testing connection")
            }
        }
        if case .finished(let result) = test {
            let message = GeminiConnectionMessage(result: result, modelID: modelID)
            VStack(alignment: .leading, spacing: 2) {
                if let title = message.title {
                    Label(title, systemImage: "checkmark.circle.fill").font(.body.bold()).foregroundStyle(.green)
                    Text(message.detail)
                } else {
                    Label(message.detail, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let footnote = message.footnote {
                    Text(footnote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
        }
        Text("A successful test doesn't guarantee future requests will succeed, and it doesn't show your billing tier.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func runTest() {
        let typed = trimmed
        let model = modelID
        test = .running
        Task {
            // The key stays in this local; the field's value is preferred so a new key can be checked first.
            let key = typed.isEmpty ? (((try? run.credentials.read()) ?? nil) ?? "") : typed
            guard !key.isEmpty else { test = .idle; return }
            let result = await GeminiConnectionTester.test(apiKey: key, model: model)
            test = .finished(result)
            if result == .connected { connected() }
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        do {
            try run.credentials.save(trimmed)
            keyInput = ""
            Task { await run.cloudRouting.invalidateCredential() }
            saved()
        } catch {
            keyError = "The key could not be saved to the Keychain."
        }
    }
}

// MARK: Models tab

/// Models: the local Ollama model, and the optional Cloud Digest (Q93): a master switch, the privacy check, a
/// provider picker (Claude Code or Gemini) and that provider's rows. Nothing but the switch shows while it is off.
/// The switch needs no credential; cloud is effectively on only when the selected provider's notice is accepted
/// and the provider is ready (Gemini key saved, or Claude Code found and signed in).
struct ModelsSettingsTab: View {
    let run: DigestRunModel

    private enum Sheet: Identifiable {
        case editURL, apiKey, acknowledgement, claudeAcknowledgement, whatGetsSent, customModel
        var id: Self { self }
    }

    @State private var sheet: Sheet?
    /// The user just turned Cloud Digest on and still has to accept the notice; declining turns it off again.
    @State private var pendingEnable = false
    @State private var hasKey = false
    @State private var confirmRemove = false
    @State private var keyError: String?
    @State private var lastConnected: Date?
    /// Tags reported by the local Ollama server; nil while unknown or unreachable.
    @State private var installedTags: Set<String>?
    @State private var ollamaChecked = false
    @Environment(\.colorScheme) private var scheme

    private static let otherModelTag = "\u{0}other"

    private var store: SettingsStore { run.settings }
    private var cloudOn: Bool { store.settings.cloudDigestEnabled }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if showsProviderPicker { localProviderPicker }
                if usesOllamaForDigest || cloudOn { ollamaRow }
                if usesOllamaForDigest {
                    digestModelPicker
                } else {
                    Text("Long emails are shortened for Apple Intelligence, which has a smaller context window than Ollama.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("On This Mac")
            } footer: {
                Text("Changes apply from the next run.")
            }
            Section {
                SubtitledToggle(title: "Cloud Digest",
                                subtitle: "Private, uncertain or not fully checked mail always stays on this Mac.",
                                isOn: enableBinding)
                if cloudOn {
                    cloudRows
                }
            } header: {
                Text("Cloud Digest")
            }
        }
        .formStyle(.grouped)
        // 814 with Cloud Digest on ends the window just below "Usage counts toward your Claude plan's limits.",
        // before the next disclosure line starts, so a screenshot shows no half-cut text.
        .frame(height: (cloudOn ? 814 : 430) + (showsProviderPicker ? 70 : 0))
        .task { await refreshKey() }
        // Apple Intelligence can be switched on in System Settings while the app runs.
        .onAppear { run.refreshPlatform() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            run.refreshPlatform()
        }
        // Look for Claude Code whenever it is the selected provider of an active Cloud Digest.
        .task(id: cloudOn && store.settings.cloudProvider == .claudeCode) {
            if cloudOn && store.settings.cloudProvider == .claudeCode { await run.claudeCode.refresh() }
        }
        .task(id: store.settings.resolvedOllamaURL.absoluteString) { await loadInstalledTags() }
        // A finished download changes what is installed.
        .task(id: run.modelDownloads.completedCount) { await loadInstalledTags() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .editURL:
                EditOllamaURLSheet(url: $store.settings.ollamaURL, done: { self.sheet = nil })
            case .apiKey:
                APIKeySheet(run: run, hasKey: hasKey, modelID: store.settings.resolvedGeminiModel,
                            saved: keySaved, connected: { lastConnected = .now },
                            cancel: { self.sheet = nil })
            case .acknowledgement:
                CloudAcknowledgementSheet(accept: { acceptAcknowledgement(.gemini) }, cancel: declineAcknowledgement)
            case .claudeAcknowledgement:
                ClaudeCodeAcknowledgementSheet(accept: { acceptAcknowledgement(.claudeCode) },
                                               cancel: declineAcknowledgement)
            case .whatGetsSent:
                WhatGetsSentSheet(done: { self.sheet = nil })
            case .customModel:
                CustomModelSheet(model: $store.settings.geminiModel, done: { self.sheet = nil })
            }
        }
        .confirmationDialog("Remove the saved API key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive, action: removeKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Gemini won't be used until you add a key. Cloud Digest stays on, and emails stay on this Mac meanwhile.")
        }
    }

    // MARK: On this Mac

    private var ollamaURLText: String {
        let url = store.settings.resolvedOllamaURL
        guard url.scheme?.lowercased() == "http", let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var platform: HostPlatform { run.platform }
    private var usesOllamaForDigest: Bool { store.settings.localProvider == .ollama }
    /// Hidden on Intel and ineligible Macs, except when a stored Apple Intelligence choice needs a way back.
    private var showsProviderPicker: Bool {
        platform.showsFoundationModelsChoice || store.settings.localProvider == .appleFoundationModels
    }

    /// "Local Model": Ollama or Apple Intelligence. The Apple Intelligence item is disabled, with the reason
    /// below, when the system can't run it right now.
    private var localProviderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Local Model", selection: Binding(get: { store.settings.localProvider },
                                                     set: { store.settings.localProvider = $0 })) {
                Text("Ollama").tag(LocalProvider.ollama)
                Text("Apple Intelligence").tag(LocalProvider.appleFoundationModels)
                    .disabled(!platform.canUseFoundationModels)
            }
            if let reason = platform.unavailableExplanation {
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ollamaRow: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if !ollamaChecked {
                    StatusDot(text: "Checking…", color: .gray)
                } else if installedTags != nil {
                    StatusDot(text: "Running", color: .green)
                } else {
                    StatusDot(text: "Not Running", color: .orange)
                }
                Button("Edit URL…") { sheet = .editURL }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ollama")
                Text(ollamaURLText).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Installed models, with the one in use always present so an existing choice is never lost.
    private var digestModelOptions: [String] {
        let current = store.settings.resolvedModel
        let triage = Set(CloudPrivacyPolicy.triageModels(for: platform).map(\.tag))
        var tags = (installedTags ?? []).filter { !triage.contains($0) || $0 == current }
        // Suggested models show even when not installed, with a Download Model row once chosen.
        tags.formUnion(DigestSettings.suggestedDigestModels(for: platform))
        tags.insert(current)
        return tags.sorted { RoutingPresentation.modelDisplayName($0).localizedStandardCompare(RoutingPresentation.modelDisplayName($1)) == .orderedAscending }
    }

    private var digestModelPicker: some View {
        let tag = store.settings.resolvedModel
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Digest Model", selection: Binding(get: { store.settings.resolvedModel },
                                                      set: { store.settings.ollamaModel = $0 })) {
                ForEach(digestModelOptions, id: \.self) { tag in
                    let missing = installedTags.map { !$0.contains(tag) } ?? false
                    Text(RoutingPresentation.modelDisplayName(tag) + (missing ? " (Not Installed)" : "")).tag(tag)
                }
            }
            ModelDownloadRow(tag: tag, installedTags: installedTags, downloads: run.modelDownloads,
                             baseURL: store.settings.resolvedOllamaURL)
        }
    }

    // MARK: Cloud rows

    @ViewBuilder private var cloudRows: some View {
        statusCaption
        privacyModelPicker
        thresholdRow
        providerPicker
        switch store.settings.cloudProvider {
        case nil:
            EmptyView()
        case .gemini?:
            cloudModelPicker
            apiKeyRow
            billingNote
                .listRowBackground(Color.orange.tintedFill(scheme))
        case .claudeCode?:
            ClaudeCodeRows(model: run.claudeCode, claudeModel: claudeModelBinding)
            claudeDisclosure
                .listRowBackground(Color.orange.tintedFill(scheme))
        }
    }

    private var effectiveOffReason: LocalReason? {
        CloudPrivacyPolicy.offReason(settings: store.settings, hasGeminiKey: hasKey, claudeCode: claudeStatus)
    }

    /// Until detection has run, Claude Code counts as ready so the caption doesn't flash a false warning.
    private var claudeStatus: ClaudeCodeStatus { run.claudeCode.detection?.status ?? .ready }

    /// Whether Cloud Digest is really active, and a way back to the notice if it was declined.
    @ViewBuilder private var statusCaption: some View {
        let text = GeminiConnectionMessage.cloudStatusText(settings: store.settings, hasGeminiKey: hasKey,
                                                           claudeCode: claudeStatus)
        if effectiveOffReason == nil {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent {
                if effectiveOffReason == .acknowledgementRequired, let provider = store.settings.cloudProvider {
                    Button("Review Privacy Notice…") { presentAcknowledgement(for: provider) }
                }
            } label: {
                Text(text).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerPicker: some View {
        Picker("Cloud Provider", selection: Binding(
            get: { store.settings.cloudProvider },
            set: { new in
                store.settings.cloudProvider = new
                if let new, needsAcknowledgement(new) { presentAcknowledgement(for: new) }
            })) {
            Text("Choose…").tag(CloudProvider?.none)
            Divider()
            // Claude Code first, Gemini second (display order only).
            ForEach(CloudProvider.allCases, id: \.self) { Text($0.displayName).tag(CloudProvider?.some($0)) }
        }
    }

    private var claudeModelBinding: Binding<String> {
        Binding(get: { store.settings.resolvedClaudeCodeModel }, set: { store.settings.claudeCodeModel = $0 })
    }

    private var claudeDisclosure: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                ClaudeCodeDisclosureText()
                ClaudeCodeLinks()
            }
        }
        .padding(.vertical, 4)
    }

    private var cloudModelOptions: [String] {
        let current = store.settings.resolvedGeminiModel
        return current == GeminiDefaults.model ? [GeminiDefaults.model] : [GeminiDefaults.model, current]
    }

    private var cloudModelPicker: some View {
        Picker("Cloud Model", selection: Binding(
            get: { store.settings.resolvedGeminiModel },
            set: { new in
                if new == Self.otherModelTag { sheet = .customModel } else { store.settings.geminiModel = new }
            })) {
            ForEach(cloudModelOptions, id: \.self) { Text(RoutingPresentation.modelDisplayName($0)).tag($0) }
            Divider()
            Text("Other…").tag(Self.otherModelTag)
        }
    }

    private var apiKeyRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button(hasKey ? "Change…" : "Add…") { sheet = .apiKey }
                if hasKey {
                    Button("Remove") { confirmRemove = true }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API Key")
                    Text(keySubtitle).font(.callout).foregroundStyle(keyError == nil ? Color.secondary : Color.red)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var keySubtitle: String {
        if let keyError { return keyError }
        guard hasKey else { return "No key saved" }
        guard let lastConnected else { return "Saved in Keychain" }
        return "Saved in Keychain · Connected at "
            + SettingsPresentation.time(minutes: Calendar.current.component(.hour, from: lastConnected) * 60
                + Calendar.current.component(.minute, from: lastConnected))
    }

    /// The model that is really used shows even when it was hand-edited, rather than hiding it.
    private var triageSelection: Binding<String> {
        Binding(get: { store.settings.resolvedTriageModel }, set: { store.settings.triageModel = $0 })
    }

    private var triageChoices: [CloudPrivacyPolicy.TriageModel] { CloudPrivacyPolicy.triageModels(for: platform) }

    private var privacyModelPicker: some View {
        let tag = store.settings.resolvedTriageModel
        return LabeledContent {
            Picker("Privacy Check Model", selection: triageSelection) {
                ForEach(triageChoices) { Text($0.displayName).tag($0.tag) }
                if !triageChoices.contains(where: { $0.tag == tag }) { Text(tag).tag(tag) }
            }
            .labelsHidden()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Privacy Check Model")
                if let note = CloudPrivacyPolicy.triageModelNote(for: tag) {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                triageStatus(tag)
                ModelDownloadRow(tag: tag, installedTags: installedTags, downloads: run.modelDownloads,
                                 baseURL: store.settings.resolvedOllamaURL)
            }
        }
    }

    @ViewBuilder private func triageStatus(_ tag: String) -> some View {
        Group {
            if let installed = installedTags {
                if installed.contains(tag) {
                    Label("\(tag) is installed", systemImage: "checkmark.circle")
                } else {
                    Label("Not installed", systemImage: "exclamationmark.triangle")
                }
            } else if ollamaChecked {
                Label("Couldn't check installed models. Is Ollama running?", systemImage: "questionmark.circle")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var thresholdRow: some View {
        @Bindable var store = store
        let percent = Int((store.settings.resolvedPrivacyThreshold * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Privacy Threshold") { Text("\(percent)%").monospacedDigit() }
            Slider(value: $store.settings.privacyThreshold, in: SystemOneSpec.thresholdRange, step: 0.01) {
                Text("Privacy Threshold")
            }
            .labelsHidden()
            .accessibilityValue("\(percent) percent")
            .accessibilityHint("Lower sends more emails to the cloud. Higher is stricter.")
            .help("An email goes to Google only if the privacy check is at least this confident it is non-sensitive.")
            HStack {
                Text("More to the cloud")
                Spacer()
                Text("Stricter")
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    // MARK: Billing note

    private var billingNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Use a Google Cloud project with billing on. On the free quota, Google can use what you send to improve its products and people may read it.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("What Gets Sent…") { sheet = .whatGetsSent }.buttonStyle(.link)
                    Link(destination: CloudPrivacyPolicy.termsURL) {
                        Label("Gemini API Terms", systemImage: "arrow.up.forward")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Key

    private func refreshKey() async {
        hasKey = ((try? run.credentials.read()) ?? nil) != nil
    }

    /// Removing the key keeps Cloud Digest on; Gemini just has no key until one is added again.
    private func removeKey() {
        do {
            try run.credentials.delete()
            keyError = nil
            hasKey = false
            lastConnected = nil
            Task { await run.cloudRouting.invalidateCredential() }
        } catch {
            keyError = "The key could not be removed from the Keychain."
        }
    }

    private func keySaved() {
        hasKey = true
        keyError = nil
        lastConnected = nil
        sheet = nil
    }

    // MARK: Enable and acknowledgement

    /// Whether the provider's privacy notice is missing or older than the current revision.
    private func needsAcknowledgement(_ provider: CloudProvider) -> Bool {
        switch provider {
        case .gemini:
            return (store.settings.cloudPrivacyAcknowledgedRevision ?? 0) < CloudPrivacyPolicy.currentRevision
        case .claudeCode:
            return (store.settings.claudeCodePrivacyAcknowledgedRevision ?? 0) < CloudPrivacyPolicy.currentClaudeCodeRevision
        }
    }

    private func presentAcknowledgement(for provider: CloudProvider) {
        sheet = provider == .gemini ? .acknowledgement : .claudeAcknowledgement
    }

    /// Turning it on needs no credential. The selected provider's notice is shown at once if it is missing; the
    /// switch goes off again when the user declines it, as before.
    private var enableBinding: Binding<Bool> {
        Binding(
            get: { store.settings.cloudDigestEnabled },
            set: { on in
                store.settings.cloudDigestEnabled = on
                pendingEnable = false
                guard on else { return }
                // With no provider chosen there is nothing to acknowledge yet; picking one shows its notice.
                guard let provider = store.settings.cloudProvider else { return }
                if needsAcknowledgement(provider) { pendingEnable = true; presentAcknowledgement(for: provider) }
            })
    }

    private func acceptAcknowledgement(_ provider: CloudProvider) {
        switch provider {
        case .gemini: store.settings.cloudPrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentRevision
        case .claudeCode:
            store.settings.claudeCodePrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentClaudeCodeRevision
        }
        pendingEnable = false
        sheet = nil
    }

    /// Declining leaves the acknowledgement unset (cloud stays off for this provider). A switch the user has
    /// just turned on goes back off; a provider change keeps the switch and shows "Review Privacy Notice…".
    private func declineAcknowledgement() {
        if pendingEnable { store.settings.cloudDigestEnabled = false }
        pendingEnable = false
        sheet = nil
    }

    // MARK: Ollama

    private func loadInstalledTags() async {
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        var request = URLRequest(url: store.settings.resolvedOllamaURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        defer { ollamaChecked = true }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            installedTags = nil
            return
        }
        installedTags = Set(tags.models.map(\.name))
    }
}

/// "Download Model" for a chosen model that Ollama doesn't have, with progress, Cancel and Try Again. Shows
/// nothing when Ollama isn't reachable (`installedTags` is nil) or the model is installed.
private struct ModelDownloadRow: View {
    let tag: String
    let installedTags: Set<String>?
    let downloads: ModelDownloadModel
    let baseURL: URL

    var body: some View {
        switch downloads.state(for: tag) {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction) { Text("Downloading \(tag)") }.labelsHidden()
                    } else {
                        ProgressView { Text("Downloading \(tag)") }.progressViewStyle(.linear).labelsHidden()
                    }
                    Button("Cancel") { downloads.cancel(tag: tag) }
                        .accessibilityLabel("Cancel download of \(tag)")
                }
                Text(progress.text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(progress.text)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try Again") { downloads.start(tag: tag, baseURL: baseURL) }
                    .accessibilityLabel("Try downloading \(tag) again")
            }
        case nil:
            if let installedTags, !installedTags.contains(tag) {
                HStack {
                    Spacer()
                    Button("Download Model") { downloads.start(tag: tag, baseURL: baseURL) }
                        .accessibilityLabel("Download model \(tag)")
                }
            }
        }
    }
}

/// A title followed by its icon, for external links ("Gemini API Terms ↗").
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.caption)
        }
    }
}

#if DEBUG
@MainActor private func previewRow(_ state: ModelDownloadModel.State?) -> some View {
    var progress = ModelPullProgress()
    progress.apply(ModelPullEvent(status: "pulling", digest: "a", total: 2_500_000_000, completed: 1_200_000_000))
    let resolved: ModelDownloadModel.State? = {
        if case .downloading? = state { return .downloading(progress) }
        return state
    }()
    return Form {
        ModelDownloadRow(tag: "qwen3:4b", installedTags: [],
                         downloads: ModelDownloadModel(previewStates: resolved.map { ["qwen3:4b": $0] } ?? [:]),
                         baseURL: URL(string: "http://localhost:11434")!)
    }
    .formStyle(.grouped).frame(width: 460, height: 140)
}

#Preview("Download, idle") { previewRow(nil) }
#Preview("Download, in progress") { previewRow(.downloading(ModelPullProgress())) }
#Preview("Download, failed") { previewRow(.failed("Couldn't reach Ollama. Check that it is running, then try again.")) }

#Preview("Models, cloud off") {
    ModelsSettingsTab(run: PreviewSupport.run())
}
#endif

#if DEBUG
#Preview("Models · Apple silicon, Apple Intelligence ready") {
    ModelsSettingsTab(run: PreviewSupport.run(platform: .appleSiliconReady))
}

#Preview("Models · Apple silicon, Apple Intelligence off") {
    ModelsSettingsTab(run: PreviewSupport.run(
        platform: HostPlatform(isAppleSilicon: true, foundationModels: .unavailable(.appleIntelligenceNotEnabled))))
}

#Preview("Models · Apple Intelligence selected") {
    ModelsSettingsTab(run: PreviewSupport.run(platform: .appleSiliconReady, localProvider: .appleFoundationModels))
}

#Preview("Models · Intel") {
    ModelsSettingsTab(run: PreviewSupport.run(platform: .intel))
}
#endif
