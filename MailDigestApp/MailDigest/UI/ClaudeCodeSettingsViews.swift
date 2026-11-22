import MailDigestCore
import SwiftUI

/// Where Claude Code is installed from; shown when it isn't found.
let claudeCodeSetupURL = URL(string: "https://code.claude.com/docs/en/setup")!
let anthropicConsumerTermsURL = URL(string: "https://www.anthropic.com/legal/consumer-terms")!
let anthropicPrivacyURL = URL(string: "https://www.anthropic.com/legal/privacy")!

/// The facts users must see before using Claude Code for Cloud Digest (Q93, revision 1). Shared by the
/// acknowledgement sheet and the disclosure row so the two never drift apart.
struct ClaudeCodeDisclosureText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Emails the app classifies as eligible have their subject, sender, date and cleaned text sent to Anthropic through Claude Code, under your own Claude account. Private or uncertain mail, mail that was not fully inspected, and anything the privacy check cannot confirm stays on this Mac.")
            Text("Usage counts toward your Claude plan's limits.")
            Text("Whether Anthropic may use chats to improve its models depends on the \"Help improve Claude\" setting in your Claude privacy settings. Mail Digest can't read that setting.")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A title followed by its icon, for external links ("Consumer Terms ↗").
struct ExternalLinkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.caption)
        }
    }
}

struct ClaudeCodeLinks: View {
    var body: some View {
        HStack(spacing: 16) {
            Link(destination: anthropicConsumerTermsURL) {
                Label("Anthropic Consumer Terms", systemImage: "arrow.up.forward").labelStyle(ExternalLinkLabelStyle())
            }
            Link(destination: anthropicPrivacyURL) {
                Label("Anthropic Privacy Policy", systemImage: "arrow.up.forward").labelStyle(ExternalLinkLabelStyle())
            }
        }
    }
}

/// Shown the first time Claude Code is selected while Cloud Digest is on, and again when the revision rises.
struct ClaudeCodeAcknowledgementSheet: View {
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send eligible emails to Anthropic through Claude Code?")
                .font(.headline)
            ClaudeCodeDisclosureText()
                .textSelection(.enabled)
            ClaudeCodeLinks()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("I Understand, Use Claude Code", action: accept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Claude Code rows for Settings > Models: status, Check Again, Model, Test Connection.
struct ClaudeCodeRows: View {
    @Bindable var model: ClaudeCodeModel
    @Binding var claudeModel: String

    private static let models: [(id: String, name: String)] = [("haiku", "Haiku"), ("sonnet", "Sonnet")]

    var body: some View {
        statusRow
        modelPicker
        testRows
    }

    // MARK: Status

    private var statusRow: some View {
        LabeledContent {
            Button("Check Again") { Task { await model.refresh() } }
                .disabled(model.isChecking)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code")
                statusDetail
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var statusDetail: some View {
        if let d = model.detection, !model.isChecking {
            switch d.status {
            case .ready:
                StatusDot(text: "Signed in" + (d.planDisplayName.map { " · \($0) plan" } ?? ""))
                installLine(d)
            case .notSignedIn:
                StatusDot(text: "Not signed in", color: .orange)
                Text("Open Terminal, run claude to sign in, then choose Check Again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                installLine(d)
            case .tooOld:
                StatusDot(text: "Update needed", color: .orange)
                Text("This version is older than \(ClaudeCodeVersion.minimum). Update Claude Code, then choose Check Again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                installLine(d)
            case .notFound:
                StatusDot(text: "Not found", color: .orange)
                Text("Install Claude Code, sign in, then choose Check Again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(destination: claudeCodeSetupURL) {
                    Label("Claude Code Setup", systemImage: "arrow.up.forward").labelStyle(ExternalLinkLabelStyle())
                }
                .font(.callout)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        }
    }

    /// "~/.local/bin/claude · version 2.1.323"
    @ViewBuilder private func installLine(_ d: ClaudeCodeDetection) -> some View {
        let path = d.executable.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        let parts = [path, d.version.map { "version \($0)" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: Model

    private var modelPicker: some View {
        Picker("Model", selection: $claudeModel) {
            ForEach(Self.models, id: \.id) { Text($0.name).tag($0.id) }
            // A hand-edited alias keeps showing rather than silently changing.
            if !Self.models.contains(where: { $0.id == claudeModel }) { Text(claudeModel).tag(claudeModel) }
        }
    }

    // MARK: Test Connection

    @ViewBuilder private var testRows: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.test == .running {
                    ProgressView().controlSize(.small).accessibilityLabel("Testing connection")
                }
                Button("Test Connection") { model.runTest(model: claudeModel) }
                    .disabled(model.test == .running || model.detection?.status != .ready)
            }
        } label: {
            if case .finished(let result) = model.test {
                let message = ClaudeCodeConnectionMessage(result: result)
                VStack(alignment: .leading, spacing: 2) {
                    if let title = message.title {
                        Label(title, systemImage: "checkmark.circle.fill").font(.body.bold()).foregroundStyle(.green)
                        Text(message.detail).font(.callout)
                    } else {
                        Label(message.detail, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if let footnote = message.footnote {
                        Text(footnote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
            } else {
                Text("Connection")
            }
        }
    }
}

#if DEBUG
#Preview("Claude Code rows") {
    @Previewable @State var m = "haiku"
    let found = ClaudeCodeDetection(status: .ready, executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude"),
                                    version: ClaudeCodeVersion.parse("2.1.323"), subscriptionType: "max")
    return Form {
        ClaudeCodeRows(model: ClaudeCodeModel(preview: found, test: .finished(.connected(model: "claude-haiku-5-5"))),
                       claudeModel: $m)
        ClaudeCodeRows(model: ClaudeCodeModel(preview: ClaudeCodeDetection(status: .notFound)), claudeModel: $m)
    }
    .formStyle(.grouped).frame(width: 520, height: 520)
}
#endif
