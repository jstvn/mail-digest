import MailDigestCore
import SwiftUI

/// "New processing job": pick mailboxes, pick a date range, preview from headers only, then confirm.
/// Nothing is queued until the user clicks Start on the last step.
struct JobSetupView: View {
    let run: DigestRunModel
    @State private var model = JobSetupModel()
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            Group {
                switch model.step {
                case .mailboxes: mailboxStep
                case .dateRange: dateRangeStep
                case .preview: previewStep
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .navigationTitle("New Processing Job")
        .task {
            if run.mailboxes.isEmpty { await run.loadMailboxes() }
            model.applyDefaultSelection(from: run.mailboxes)
        }
        .onChange(of: run.mailboxes) { _, boxes in model.applyDefaultSelection(from: boxes) }
        // The window is a single scene whose state can outlive it; never reopen on an old preview.
        .onDisappear { model.reset() }
    }

    // MARK: Header and footer

    private var stepHeader: some View {
        HStack(spacing: 18) {
            ForEach(JobSetupModel.Step.allCases, id: \.self) { step in
                Label(title(of: step), systemImage: symbol(of: step))
                    .font(step == model.step ? .headline : .body)
                    .foregroundStyle(step == model.step ? Color.primary : Color.secondary)
                    .accessibilityLabel("Step \(step.rawValue + 1) of 3, \(title(of: step))")
                    .accessibilityAddTraits(step == model.step ? .isSelected : [])
            }
            Spacer()
        }
        .padding(14)
    }

    private func title(of step: JobSetupModel.Step) -> String {
        switch step {
        case .mailboxes: return "Mailboxes"
        case .dateRange: return "Date range"
        case .preview: return "Preview"
        }
    }

    private func symbol(of step: JobSetupModel.Step) -> String {
        step.rawValue < model.step.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle"
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismissWindow(id: "job-setup") }
                .keyboardShortcut(.cancelAction)
            if model.step != .mailboxes {
                Button("Back") { model.goBack() }
            }
            switch model.step {
            case .mailboxes:
                Button("Next") { model.step = .dateRange }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty)
            case .dateRange:
                Button("Preview") {
                    model.step = .preview
                    model.loadPreview(run: run)
                }
                .keyboardShortcut(.defaultAction)
            case .preview:
                startButton
            }
        }
        .padding(14)
    }

    @ViewBuilder private var startButton: some View {
        if let title = model.startTitle(filter: run.settings.settings.mailFilter),
           let confirmed = model.confirmed, !confirmed.toProcess.isEmpty {
            Button(title) {
                Task {
                    if await model.start(run: run) {
                        dismissWindow(id: "job-setup")
                        openWindow(id: "review")
                        NSApp.activate()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.isStarting)
            .help("Queues exactly these emails and starts processing them one at a time")
        } else {
            Button("Start") {}.disabled(true)
        }
    }

    // MARK: Step 1: mailboxes

    private var mailboxStep: some View {
        List {
            if run.isLoadingMailboxes && run.mailboxes.isEmpty {
                ProgressView("Loading mailboxes…")
            } else if run.mailboxes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(run.mailboxError ?? "Mailboxes appear once Mail access is allowed.")
                        .foregroundStyle(.secondary)
                    Button("Load Mailboxes") { Task { await run.loadMailboxes() } }
                }
            } else {
                Section {
                    Toggle(isOn: Binding(get: { model.allInboxesState(run.mailboxes) },
                                         set: { model.setAllInboxes($0, mailboxes: run.mailboxes) })) {
                        HStack {
                            Label("All Inboxes", systemImage: "tray.2")
                            Spacer()
                            Text(inboxTotal, format: .number).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(MailboxTree.accounts(run.mailboxes, showAll: model.showAllMailboxes)) { account in
                    Section(account.account) {
                        ForEach(account.rows) { row in
                            Toggle(isOn: Binding(get: { model.isSelected(row.info.ref) },
                                                 set: { model.setSelected(row.info.ref, $0) })) {
                                HStack {
                                    if row.info.kind == .inbox {
                                        Image(systemName: "tray").accessibilityHidden(true)
                                    }
                                    Text(row.title)
                                    Spacer()
                                    Text(row.info.messageCount, format: .number)
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.leading, CGFloat(row.depth) * 16)
                            }
                            .accessibilityLabel("\(account.account), \(row.info.ref.name)")
                            .accessibilityValue("\(row.info.messageCount) emails")
                        }
                    }
                }
                Section {
                    Toggle("Show all mailboxes", isOn: Bindable(model).showAllMailboxes)
                } footer: {
                    Text("Sent, Drafts, Junk and Trash are hidden, since processing them rarely makes sense.")
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var inboxTotal: Int {
        run.mailboxes.filter { $0.kind == .inbox }.reduce(0) { $0 + $1.messageCount }
    }

    // MARK: Step 2: date range

    private var dateRangeStep: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Process mail from", selection: $model.scope) {
                    Text("Last 30 days").tag(JobSetupModel.Scope.last30)
                    Text("Last 90 days").tag(JobSetupModel.Scope.last90)
                    Text("Everything").tag(JobSetupModel.Scope.everything)
                    Text("Custom range").tag(JobSetupModel.Scope.custom)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: model.scope) { _, _ in model.scopeChanged() }
                if model.scope == .custom {
                    DatePicker("From", selection: $model.customFrom, in: ...Date.now, displayedComponents: .date)
                    DatePicker("To", selection: $model.customTo, in: ...Date.now, displayedComponents: .date)
                }
            } footer: {
                Text("Newest mail is processed first. Mail that arrives after you start goes to the next Daily digest, not this job.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.customFrom) { _, _ in model.scopeChanged() }
        .onChange(of: model.customTo) { _, _ in model.scopeChanged() }
    }

    // MARK: Step 3: preview

    @ViewBuilder private var previewStep: some View {
        if model.isLoadingPreview {
            VStack(spacing: 10) {
                ProgressView()
                Text("Listing mail (headers only)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.preview, let confirmed = model.confirmed {
            VStack(spacing: 0) {
                previewSummary(preview, confirmed: confirmed)
                Divider()
                emailList(preview)
            }
        } else {
            VStack(spacing: 10) {
                Text(model.error ?? "No preview yet.").foregroundStyle(.secondary)
                Button("Try Again") { model.loadPreview(run: run) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewSummary(_ preview: JobPreview, confirmed: JobPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview · \(model.scopeDescription) · \(JobFormat.number(confirmed.toProcess.count)) emails · \(JobFormat.duration(confirmed.estimatedSeconds))")
                .font(.headline)
            if confirmed.toProcess.isEmpty {
                Text(nothingToProcessText(preview, confirmed: confirmed))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(preview.plan.mailboxes, id: \.self) { box in
                HStack {
                    Text("\(box.account) · \(box.name)")
                    Spacer()
                    Text(JobFormat.number(preview.mailboxTotals[box] ?? 0)).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Group {
                if let range = preview.dateRangeFound {
                    Text("Found \(JobFormat.number(preview.totalFound)) emails from \(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) to \(range.upperBound.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text("No mail found in this range.")
                }
                Text("\(JobFormat.number(preview.alreadyProcessed)) already processed or queued (skipped) · \(JobFormat.number(confirmed.excluded)) unticked")
                let t = preview.estimatedTiers
                Text("Estimate: about \(JobFormat.number(t.skip)) skipped bulk mail, \(JobFormat.number(t.infoOnly)) info only, \(JobFormat.number(t.full)) full summaries")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why Start is unavailable: no mail at all, everything handled already, or everything unticked.
    private func nothingToProcessText(_ preview: JobPreview, confirmed: JobPreview) -> String {
        if preview.totalFound == 0 { return "There is no mail in this range, so there is nothing to process." }
        if preview.toProcess.isEmpty {
            return "Nothing to process: every email found is already processed or queued in another job."
        }
        return "Nothing to process: every email is unticked."
    }

    private func emailList(_ preview: JobPreview) -> some View {
        List {
            Section {
                ForEach(preview.firstItems, id: \.id) { header in
                    let included = model.isIncluded(header.id)
                    Toggle(isOn: Binding(get: { included }, set: { model.setIncluded(header.id, $0) })) {
                        HStack(spacing: 10) {
                            Text(header.receivedAt, format: .dateTime.day().month(.abbreviated))
                                .frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                            Text(ReviewPresentation.senderName(header.sender))
                                .frame(width: 140, alignment: .leading).lineLimit(1)
                            Text(header.subject).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(header.account).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    .contextMenu {
                        let name = ReviewPresentation.senderName(header.sender)
                        let count = model.senderCount(header.sender)
                        Button("Untick All from \(name) (\(count))") { model.setSender(header.sender, included: false) }
                        Button("Tick All from \(name)") { model.setSender(header.sender, included: true) }
                    }
                    .accessibilityLabel("\(ReviewPresentation.senderName(header.sender)), \(header.subject), \(header.account)")
                }
            } header: {
                let shown = preview.firstItems.count
                Text(preview.toProcess.count > shown
                     ? "First \(shown) of \(JobFormat.number(preview.toProcess.count)) emails. Untick any you don't want processed."
                     : "Untick any email you don't want processed.")
            }
        }
    }
}
