import Charts
import MailDigestCore
import SwiftUI

/// "New Backlog Job": choose mailboxes, pick a date range, then check the details and start. Counts come from
/// the Mail index or the header preview; nothing is queued until the user clicks Start Job on the last step.
struct JobSetupView: View {
    let run: DigestRunModel
    @State private var model: JobSetupModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    /// Previews pass `loadsData: false` so nothing opens the database or Mail.
    private let loadsData: Bool

    init(run: DigestRunModel, model: JobSetupModel = JobSetupModel(), loadsData: Bool = true) {
        self.run = run
        self.loadsData = loadsData
        _model = State(initialValue: model)
    }

    private static let windowID = "new-backlog-job"
    private var filter: MailFilter { run.settings.settings.mailFilter }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(steps: ["Mailboxes", "Date Range", "Preview"], current: model.step.rawValue)
                .padding(.top, 12)
                .padding(.bottom, 16)
            Group {
                switch model.step {
                case .mailboxes: MailboxStep(run: run, model: model)
                case .dateRange: DateRangeStep(run: run, model: model)
                case .preview: ReadyStep(run: run, model: model)
                }
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 640)
        .task {
            guard loadsData else { return }
            if run.mailboxes.isEmpty { await run.loadMailboxes() }
            model.applyDefaultSelection(from: run.mailboxes)
            await model.loadHistory(run: run)
        }
        .onChange(of: run.mailboxes) { _, boxes in model.applyDefaultSelection(from: boxes) }
        .onChange(of: model.step) { _, step in
            if step != .mailboxes, model.preview == nil, !model.isLoadingPreview { model.refreshCounts(run: run) }
        }
        .onChange(of: model.inputs) { _, _ in
            if model.step != .mailboxes { model.refreshCounts(run: run) } else { model.invalidateCounts() }
        }
        // The window is a single scene whose state can outlive it; never reopen on an old preview.
        .onDisappear { model.reset() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            footerSummary
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if model.step != .mailboxes {
                Button("Back") { model.goBack() }
            }
            Button("Cancel", role: .cancel) { dismissWindow(id: Self.windowID) }
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder private var footerSummary: some View {
        switch model.step {
        case .mailboxes:
            Text(BacklogSetupText.mailboxFooter(mailboxCount: model.selectedMailboxes(run.mailboxes).count,
                                                emailCount: model.selectedMessageCount(run.mailboxes)))
        case .dateRange:
            countsSummary
        case .preview:
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    /// "374 emails to read · 8 batches", from the same numbers the job will queue (Q26).
    @ViewBuilder private var countsSummary: some View {
        if let error = model.error {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try Again") { model.refreshCounts(run: run) }.controlSize(.small)
            }
        } else if let confirmed = model.confirmed(filter: filter) {
            Text(BacklogSetupText.readFooter(toProcess: confirmed.toProcess.count,
                                             deferredByLimit: confirmed.deferredByLimit))
        } else {
            Text("Counting…")
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.step {
        case .mailboxes:
            Button("Continue") { model.step = .dateRange }
                .disabled(model.selected.isEmpty)
                .modifier(PrimaryAction())
        case .dateRange:
            Button("Continue") { model.step = .preview }
                .disabled(model.preview == nil)
                .modifier(PrimaryAction())
        case .preview:
            Button("Start Job") {
                Task {
                    if await model.start(run: run) {
                        dismissWindow(id: Self.windowID)
                        openWindow(id: "review")
                        NSApp.activate()
                    }
                }
            }
            .disabled(!model.canStart(filter: filter))
            .modifier(PrimaryAction())
            .help("Queues exactly these emails")
        }
    }
}

/// The prominent default button of the window's footer.
private struct PrimaryAction: ViewModifier {
    func body(content: Content) -> some View {
        content
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }
}

/// Step title and one-line description above a step's content.
private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Step 1: mailboxes

private struct MailboxStep: View {
    let run: DigestRunModel
    @Bindable var model: JobSetupModel

    var body: some View {
        VStack(spacing: 8) {
            StepHeader(title: "Choose Mailboxes",
                       subtitle: "Pick where your older mail lives. Mail Digest only reads it. Nothing is moved, marked or deleted.")
            if run.isLoadingMailboxes && run.mailboxes.isEmpty {
                ProgressView("Loading mailboxes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if run.mailboxes.isEmpty {
                ContentUnavailableView {
                    Label("No Mailboxes Yet", systemImage: "tray")
                } description: {
                    Text(run.mailboxError ?? "Mailboxes appear once Mail access is allowed.")
                } actions: {
                    Button("Load Mailboxes") { Task { await run.loadMailboxes() } }
                }
            } else {
                filterRow
                list
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Filter Mailboxes", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter Mailboxes")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button("Select Inboxes Only") { model.selectInboxesOnly(run.mailboxes) }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
    }

    private var list: some View {
        let partition = MailboxTree.partition(run.mailboxes, filter: model.filterText)
        let isFiltering = !model.filterText.trimmingCharacters(in: .whitespaces).isEmpty
        return Form {
            if !isFiltering {
                Section {
                    Toggle(isOn: Binding(get: { model.allInboxesState(run.mailboxes) },
                                         set: { model.setAllInboxes($0, mailboxes: run.mailboxes) })) {
                        HStack {
                            Label("All Inboxes", systemImage: "tray.2").fontWeight(.semibold)
                            Spacer()
                            count(inboxTotal)
                        }
                    }
                    .accessibilityValue("\(inboxTotal) emails")
                }
            }
            ForEach(partition.useful) { account in
                Section(account.account) { rows(account) }
            }
            if partition.noiseCount > 0 {
                Section {
                    DisclosureGroup(isExpanded: $model.showsNoise) {
                        ForEach(partition.noise) { account in
                            Text(account.account).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            rows(account)
                        }
                    } label: {
                        Text("\(model.showsNoise ? "Hide" : "Show") \(partition.noiseCount) Empty and System Folders")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if partition.useful.isEmpty && partition.noiseCount == 0 {
                ContentUnavailableView.search(text: model.filterText)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
    }

    private func rows(_ account: MailboxTreeAccount) -> some View {
        ForEach(account.rows) { row in
            Toggle(isOn: Binding(get: { model.isSelected(row.info.ref) },
                                 set: { model.setSelected(row.info.ref, $0) })) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(row)).foregroundStyle(row.info.kind == .inbox ? Color.accentColor : .secondary)
                        .frame(width: 18).accessibilityHidden(true)
                    Text(MailboxTree.displayTitle(row))
                    Spacer()
                    if let note = MailboxTree.annotation(row) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    count(row.info.messageCount)
                }
                .padding(.leading, CGFloat(row.depth) * 16)
            }
            .accessibilityLabel("\(account.account), \(row.info.ref.name)")
            .accessibilityValue("\(row.info.messageCount) emails")
        }
    }

    private func count(_ n: Int) -> some View {
        Text(n, format: .number).monospacedDigit().foregroundStyle(.secondary)
    }

    private func symbol(_ row: MailboxTreeRow) -> String {
        switch row.info.kind {
        case .inbox: return "tray"
        case .archive: return "archivebox"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .custom: return "folder"
        }
    }

    private var inboxTotal: Int {
        run.mailboxes.filter { $0.kind == .inbox }.reduce(0) { $0 + $1.messageCount }
    }
}

// MARK: - Step 2: date range

private struct DateRangeStep: View {
    let run: DigestRunModel
    @Bindable var model: JobSetupModel

    private var filter: MailFilter { run.settings.settings.mailFilter }

    var body: some View {
        VStack(spacing: 8) {
            StepHeader(title: "Pick a Date Range",
                       subtitle: "Older mail is read in batches of 50, oldest first. You can pause or stop between batches.")
            Picker("Date Range", selection: $model.preset) {
                ForEach(BacklogRangePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)
            .padding(.top, 4)
            Form {
                Section {
                    rangeHeader
                    VolumeChart(volume: model.volume, calendar: model.calendar)
                    if model.preset == .sinceLastJob, model.lastJobEnd == nil {
                        Text("There is no earlier Backlog job yet, so this covers the last 30 days.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle(isOn: .constant(true)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip Emails Already Processed")
                            Text(processedSubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // Mail Digest never reads an email twice, so this one is a statement, not a choice.
                    .disabled(true)
                    .help("Emails that were already read, or are queued in another job, are never processed twice.")
                    Toggle(isOn: $model.skipIgnoredSenders) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip Ignored Senders")
                            Text(ignoredSubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The range in words (or two date fields for Custom) and the number of emails in it.
    private var rangeHeader: some View {
        HStack(spacing: 8) {
            if model.preset == .custom {
                Text("From")
                DatePicker("From", selection: $model.customFrom, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden()
                Text("to")
                DatePicker("To", selection: $model.customTo, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden()
            } else {
                Text(model.rangeText).foregroundStyle(.secondary)
            }
            Spacer()
            Text(rangeTotal).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    /// Emails in the range before skipping: from the Mail index when it is available, else the header listing.
    private var rangeTotal: String {
        let total: Int?
        if case .ready(let bins) = model.volume { total = VolumeHistogram.total(bins) } else { total = model.preview?.totalFound }
        guard let total else { return "Counting…" }
        return "\(JobFormat.number(total)) \(total == 1 ? "email" : "emails")"
    }

    private var processedSubtitle: String {
        guard let preview = model.preview else { return "Emails Mail Digest has already read are left out." }
        return "\(JobFormat.number(preview.alreadyProcessed)) already read or queued in another job"
    }

    private var ignoredSubtitle: String {
        let note = "Uses your list in Settings › Senders"
        let n = model.ignoredSenderCount(filter: filter)
        return n > 0 ? "\(JobFormat.number(n)) \(n == 1 ? "email" : "emails") · \(note)" : note
    }
}

/// Emails per day for the chosen mailboxes: the range in the accent colour, the days around it in grey.
private struct VolumeChart: View {
    let volume: JobSetupModel.Volume
    let calendar: Calendar

    var body: some View {
        switch volume {
        case .ready(let bins) where !bins.isEmpty:
            Chart(bins) { bin in
                BarMark(x: .value("Day", bin.date, unit: .day), y: .value("Emails", bin.count))
                    .foregroundStyle(bin.isInRange ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                }
            }
            .chartPlotStyle { $0.frame(height: 84) }
            .frame(height: 112)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Emails per day")
            .accessibilityValue(VolumeHistogram.accessibilitySummary(bins, calendar: calendar))
        case .unavailable:
            placeholder("Daily volume needs Full Disk Access. The numbers below still count the chosen range.")
        case .idle, .loading, .ready:
            placeholder("Counting…")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 112)
    }
}

// MARK: - Step 3: ready to start

private struct ReadyStep: View {
    let run: DigestRunModel
    @Bindable var model: JobSetupModel

    private var filter: MailFilter { run.settings.settings.mailFilter }
    private var window: QuietHours {
        let s = run.settings.settings
        return QuietHours(startMinute: s.quietHoursStartMinute, endMinute: s.quietHoursEndMinute)
    }

    var body: some View {
        VStack(spacing: 8) {
            StepHeader(title: "Ready to Start",
                       subtitle: "Check the details. Suggestions show up in the sidebar under this job as each batch finishes.")
            Form {
                summary
                Section("When to Run") {
                    RunChoice(title: "Overnight While Plugged In", detail: overnightDetail,
                              isSelected: model.runMode == .overnight) { model.runMode = .overnight }
                    RunChoice(title: "Start Now",
                              detail: "Runs in the background and pauses on battery, Low Power Mode or when it gets hot.",
                              isSelected: model.runMode == .now) { model.runMode = .now }
                }
                Section {
                    Label("Nothing is added to Reminders until you review it.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private var summary: some View {
        let confirmed = model.confirmed(filter: filter)
        Section {
            LabeledContent("Name") {
                TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0 }),
                          prompt: Text(model.defaultName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Mailboxes", value: BacklogSetupText.mailboxList(model.selectedMailboxes(run.mailboxes).map(\.ref)))
            LabeledContent("Date Range", value: model.rangeText)
            LabeledContent("Emails") { emails(confirmed) }
            LabeledContent("Processing") {
                Label("Local · " + RoutingPresentation.modelDisplayName(run.settings.settings.resolvedModel), systemImage: "lock.fill")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            }
            LabeledContent("Estimated Time") { estimate(confirmed) }
        }
    }

    @ViewBuilder private func emails(_ confirmed: JobPreview?) -> some View {
        if let confirmed, let preview = model.preview {
            Text(BacklogSetupText.emailsRow(toProcess: confirmed.toProcess.count, alreadyProcessed: preview.alreadyProcessed,
                                            deferredByLimit: confirmed.deferredByLimit))
                .multilineTextAlignment(.trailing)
        } else {
            Text("Counting…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func estimate(_ confirmed: JobPreview?) -> some View {
        if let confirmed {
            Text(BacklogSetupText.estimateRow(seconds: confirmed.estimatedSeconds, toProcess: confirmed.toProcess.count))
        } else {
            Text("Counting…").foregroundStyle(.secondary)
        }
    }

    private var overnightDetail: String {
        let seconds = model.confirmed(filter: filter)?.estimatedSeconds
            ?? model.secondsPerEmail * Double(model.preview?.toProcess.count ?? 0)
        return BacklogEstimate.overnightDescription(window: window, estimatedSeconds: seconds)
    }
}

/// One option of the "When to Run" group: a radio mark, a title and a sentence.
private struct RunChoice: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Previews

#if DEBUG
private extension JobSetupModel {
    /// A model parked on `step` with fixed counts, for previews.
    static func sample(step: Step) -> JobSetupModel {
        let model = JobSetupModel()
        model.applyDefaultSelection(from: JobSetupSamples.mailboxes)
        model.step = step
        model.installSampleCounts()
        return model
    }
}

private enum JobSetupSamples {
    static let mailboxes: [MailboxInfo] = {
        func box(_ account: String, _ name: String, _ kind: MailboxKind, _ count: Int) -> MailboxInfo {
            MailboxInfo(ref: MailboxRef(account: account, name: name), messageCount: count, unreadCount: 0, kind: kind)
        }
        return [box("iCloud", "INBOX", .inbox, 2_555), box("iCloud", "Archive", .archive, 568),
                box("iCloud", "Mail Digest", .custom, 14), box("iCloud", "Sent Messages", .sent, 301),
                box("iCloud", "Notes", .custom, 0), box("Outlook", "Inbox", .inbox, 1_075),
                box("Outlook", "Archive", .archive, 1_016), box("Outlook", "Outbox", .custom, 0),
                box("Outlook", "Untitled list", .custom, 2)]
    }()
}

@MainActor private func setupPreview(_ step: JobSetupModel.Step) -> some View {
    JobSetupView(run: PreviewSupport.run(mailboxes: JobSetupSamples.mailboxes), model: .sample(step: step),
                 loadsData: false)
}

#Preview("New Backlog Job · Mailboxes") { setupPreview(.mailboxes) }
#Preview("New Backlog Job · Date Range") { setupPreview(.dateRange) }
#Preview("New Backlog Job · Ready to Start") { setupPreview(.preview) }
#endif
