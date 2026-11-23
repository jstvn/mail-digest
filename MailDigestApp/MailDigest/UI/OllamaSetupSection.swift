import AppKit
import MailDigestCore
import SwiftUI

/// Onboarding's Ollama step (Q92, Q100): installs, starts and downloads the digest model without Terminal,
/// or switches to Apple Intelligence. Every step is optional; nothing here blocks finishing onboarding.
struct OllamaSetupSection: View {
    let run: DigestRunModel
    /// Fixed state for previews; skips all checks.
    var previewState: OllamaSetupState?

    @State private var setup: OllamaSetupState?
    @State private var isChecking = false
    @State private var isWaitingForStart = false
    @State private var pollTask: Task<Void, Never>?

    private var settings: DigestSettings { run.settings.settings }
    private var usesAppleIntelligence: Bool { settings.localProvider == .appleFoundationModels }
    private var state: OllamaSetupState? { previewState ?? setup }
    private var tag: String { settings.resolvedModel }

    var body: some View {
        Section {
            content
        } header: {
            Text("Summaries")
        } footer: {
            Text("A model running on this Mac writes the summaries. You can change this later in Settings \u{203A} Models.")
        }
        .task(id: run.modelDownloads.completedCount) { await check() }
        .onAppear { run.refreshPlatform() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            run.refreshPlatform()
            if !usesAppleIntelligence { Task { await check() } }
        }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        if usesAppleIntelligence {
            statusRow(.appleIntelligence)
            Button("Use Ollama Instead") {
                run.settings.settings.localProvider = .ollama
                Task { await check() }
            }
        } else if let state {
            let presentation = OllamaSetupPresentation.make(for: state, model: tag)
            statusRow(presentation)
            actions(for: state)
            if state != .ready, run.platform.canUseFoundationModels {
                Button("Use Apple Intelligence Instead") {
                    pollTask?.cancel()
                    isWaitingForStart = false
                    run.settings.settings.localProvider = .appleFoundationModels
                }
            }
        } else {
            ProgressView("Checking Ollama…")
        }
    }

    @ViewBuilder private func actions(for state: OllamaSetupState) -> some View {
        switch state {
        case .notInstalled, .versionTooOld:
            Button { OllamaLauncher.openDownloadPage() } label: {
                Label("Download Ollama", systemImage: "arrow.up.forward.app")
            }
            checkAgain
        case .notRunning:
            if isWaitingForStart {
                ProgressView("Waiting for Ollama to start…")
            }
            Button("Start Ollama") { startOllama() }
                .disabled(isWaitingForStart)
            checkAgain
        case .modelMissing:
            downloadRow
            checkAgain
        case .ready:
            EmptyView()
        }
    }

    private var checkAgain: some View {
        HStack {
            Button("Check Again") { Task { await check() } }
                .disabled(isChecking || previewState != nil)
            if isChecking { ProgressView().controlSize(.small).accessibilityLabel("Checking Ollama") }
        }
    }

    /// Download Model, with progress, Cancel and Try Again; the same download shows in Settings (Q87).
    @ViewBuilder private var downloadRow: some View {
        let downloads = run.modelDownloads
        switch downloads.state(for: tag) {
        case .downloading(let progress)?:
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
        case .failed(let message)?:
            HStack(spacing: 8) {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try Again") { startDownload() }
                    .accessibilityLabel("Try downloading \(tag) again")
            }
        case nil:
            Button("Download Model") { startDownload() }
                .accessibilityLabel("Download model \(tag)")
        }
    }

    private func statusRow(_ p: OllamaSetupPresentation) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).fontWeight(.medium)
                Text(p.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: p.symbol)
                .foregroundStyle(p.tone == .ready ? Color.green : Color.yellow)
                .accessibilityLabel(p.title)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func startDownload() {
        run.modelDownloads.start(tag: tag, baseURL: settings.resolvedOllamaURL)
    }

    private func check() async {
        guard previewState == nil, !usesAppleIntelligence else { return }
        isChecking = true
        setup = await OllamaSetupChecker.check(baseURL: settings.resolvedOllamaURL, model: tag)
        isChecking = false
    }

    /// Launches Ollama, then re-checks every couple of seconds until the server answers or time runs out.
    private func startOllama() {
        OllamaLauncher.start()
        guard previewState == nil else { return }
        pollTask?.cancel()
        isWaitingForStart = true
        pollTask = Task {
            let policy = OllamaStartPolling()
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(policy.interval))
                if Task.isCancelled { break }
                elapsed += policy.interval
                await check()
                guard let current = setup, policy.shouldContinue(after: current, elapsed: elapsed) else { break }
            }
            isWaitingForStart = false
        }
    }
}

#if DEBUG
@MainActor private func previewSetup(_ state: OllamaSetupState, downloads: [String: ModelDownloadModel.State] = [:],
                                     provider: LocalProvider = .ollama,
                                     platform: HostPlatform = .appleSiliconReady) -> some View {
    let run = PreviewSupport.run(platform: platform, localProvider: provider)
    return Form { OllamaSetupSection(run: run, previewState: state) }
        .formStyle(.grouped).frame(width: 520, height: 300)
}

#Preview("Not installed") { previewSetup(.notInstalled) }
#Preview("Not running") { previewSetup(.notRunning, platform: .intel) }
#Preview("Version too old") { previewSetup(.versionTooOld(installed: "0.3.2")) }
#Preview("Model missing") { previewSetup(.modelMissing("qwen3:4b")) }
#Preview("Ready") { previewSetup(.ready) }
#Preview("Apple Intelligence") { previewSetup(.notInstalled, provider: .appleFoundationModels) }
#endif
