import MailDigestCore
import SwiftUI

/// The facts users must see before and after enabling Cloud Digest (Q63). Shared by the persistent footer and
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
                Button("I Understand, Enable Cloud Digest", action: accept)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// "Cloud AI (Gemini)" settings: key, connection test, enable switch, triage model, threshold and disclosure.
struct CloudSettingsSection: View {
    let run: DigestRunModel

    private enum TestState: Equatable {
        case idle, running, finished(GeminiConnectionResult)
    }

    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var keyError: String?
    @State private var test = TestState.idle
    @State private var showAcknowledgement = false
    @State private var confirmRemove = false
    /// Tags reported by the local Ollama server; nil while unknown or unreachable.
    @State private var installedTags: Set<String>?

    private var store: SettingsStore { run.settings }

    var body: some View {
        @Bindable var store = store
        Section {
            modelInfoRow
            TextField("Model ID", text: $store.settings.geminiModel, prompt: Text(GeminiDefaults.model))
                .accessibilityLabel("Gemini model ID")
            keyRows
            testRows
            Toggle("Enable Cloud Digest for Non-Sensitive Emails", isOn: enableBinding)
                .disabled(!hasKey && !store.settings.cloudDigestEnabled)
            Text(GeminiConnectionMessage.cloudStatusText(settings: store.settings, hasKey: hasKey))
                .font(.caption).foregroundStyle(.secondary)
            Picker("Privacy Triage Model", selection: $store.settings.triageModel) {
                ForEach(CloudPrivacyPolicy.triageModels) { Text($0.displayName).tag($0.tag) }
            }
            if let note = CloudPrivacyPolicy.triageModelNote(for: store.settings.triageModel) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            triageStatus
            thresholdRow
        } header: {
            Text("Cloud AI (Gemini)")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                CloudDisclosureText()
                    .textSelection(.enabled)
                Link("Gemini API Additional Terms", destination: CloudPrivacyPolicy.termsURL)
            }
            .foregroundStyle(.secondary)
        }
        .task { await refresh() }
        // A result describes one key and model; drop it when either changes.
        .onChange(of: store.settings.resolvedGeminiModel) { test = .idle }
        .onChange(of: keyInput) { test = .idle }
        .task(id: store.settings.resolvedOllamaURL) { await loadInstalledTags() }
        .sheet(isPresented: $showAcknowledgement) {
            CloudAcknowledgementSheet(accept: acceptAcknowledgement, cancel: { showAcknowledgement = false })
        }
        .confirmationDialog("Remove the saved API key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive, action: removeKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cloud Digest will be turned off and every email stays on this Mac.")
        }
    }

    // MARK: Model

    @ViewBuilder private var modelInfoRow: some View {
        let id = store.settings.resolvedGeminiModel
        let name = RoutingPresentation.modelDisplayName(id)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Cloud Digest Model") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(name).font(.headline)
                    if name != id {
                        Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
            Text("Used for emails that pass Mail Digest's privacy checks when Cloud Digest is enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Key

    @ViewBuilder private var keyRows: some View {
        Label(hasKey ? "API key saved in Keychain" : "No API key",
              systemImage: hasKey ? "checkmark.seal.fill" : "key")
            .accessibilityLabel(hasKey ? "API key saved in Keychain" : "No API key saved")
        SecureField("API Key", text: $keyInput, prompt: Text("Paste your Gemini API key"))
            .onSubmit(saveKey)
        if let keyError {
            Label(keyError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
        HStack {
            Button(hasKey ? "Update Key" : "Save Key", action: saveKey)
                .disabled(trimmedInput.isEmpty)
            Spacer()
            if hasKey {
                Button("Remove Key", role: .destructive) { confirmRemove = true }
            }
        }
    }

    private var trimmedInput: String { keyInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveKey() {
        let key = trimmedInput
        guard !key.isEmpty else { return }
        do {
            try run.credentials.save(key)
            keyInput = ""
            keyError = nil
            hasKey = true
            test = .idle
            Task { await run.cloudRouting.invalidateCredential() }
        } catch {
            keyError = "The key could not be saved to the Keychain."
        }
    }

    private func removeKey() {
        do {
            try run.credentials.delete()
            keyError = nil
            hasKey = false
            test = .idle
            store.settings.cloudDigestEnabled = false
            Task { await run.cloudRouting.invalidateCredential() }
        } catch {
            keyError = "The key could not be removed from the Keychain."
        }
    }

    private func refresh() async {
        hasKey = ((try? run.credentials.read()) ?? nil) != nil
        // A key removed elsewhere must not leave Cloud Digest looking on.
        if !hasKey && store.settings.cloudDigestEnabled { store.settings.cloudDigestEnabled = false }
    }

    // MARK: Test Connection

    @ViewBuilder private var testRows: some View {
        HStack {
            Button("Test Connection", action: runTest)
                .disabled(test == .running || (trimmedInput.isEmpty && !hasKey))
            if test == .running {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Testing connection")
            }
        }
        if case .finished(let result) = test {
            let message = GeminiConnectionMessage(result: result, modelID: store.settings.resolvedGeminiModel)
            VStack(alignment: .leading, spacing: 2) {
                if let title = message.title {
                    Label(title, systemImage: "checkmark.circle.fill")
                        .font(.body.bold()).foregroundStyle(.green)
                    Text(message.detail)
                } else {
                    Label(message.detail, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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
        let typed = trimmedInput
        let model = store.settings.resolvedGeminiModel
        test = .running
        Task {
            // The key stays in this local; the field's value is preferred so a new key can be checked first.
            let key = typed.isEmpty ? (((try? run.credentials.read()) ?? nil) ?? "") : typed
            guard !key.isEmpty else { test = .idle; return }
            test = .finished(await GeminiConnectionTester.test(apiKey: key, model: model))
        }
    }

    // MARK: Enable and acknowledgement

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { store.settings.cloudDigestEnabled },
            set: { on in
                guard on else { store.settings.cloudDigestEnabled = false; return }
                let revision = store.settings.cloudPrivacyAcknowledgedRevision ?? 0
                if revision < CloudPrivacyPolicy.currentRevision {
                    // The switch only turns on after the user accepts the sheet.
                    showAcknowledgement = true
                } else {
                    store.settings.cloudDigestEnabled = true
                }
            })
    }

    private func acceptAcknowledgement() {
        store.settings.cloudPrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentRevision
        store.settings.cloudDigestEnabled = hasKey
        showAcknowledgement = false
    }

    // MARK: Triage model and threshold

    @ViewBuilder private var triageStatus: some View {
        let tag = store.settings.resolvedTriageModel
        if let installed = installedTags {
            if installed.contains(tag) {
                Label("\(tag) is installed", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Not installed. Run `ollama pull \(tag)` in Terminal.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } else {
            Label("Couldn't check installed models. Is Ollama running?", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var thresholdRow: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Privacy Threshold", value: "\(Int((store.settings.resolvedPrivacyThreshold * 100).rounded()))%")
            Slider(value: $store.settings.privacyThreshold, in: SystemOneSpec.thresholdRange, step: 0.01) {
                Text("Privacy Threshold")
            }
            .labelsHidden()
            .accessibilityValue("\(Int((store.settings.resolvedPrivacyThreshold * 100).rounded())) percent")
            Text("An email is sent to Google only if the privacy check is at least this confident it is non-sensitive, and at least 85% confident it is a public newsletter or promotion. Scores are model confidences, not guarantees.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadInstalledTags() async {
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        var request = URLRequest(url: store.settings.resolvedOllamaURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            installedTags = nil
            return
        }
        installedTags = Set(tags.models.map(\.name))
    }
}
