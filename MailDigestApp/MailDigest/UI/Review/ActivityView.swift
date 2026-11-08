import MailDigestCore
import SwiftUI

/// Activity Center: every retained Daily and Backlog job as its own record, grouped by day. Jobs expand to
/// lifecycle events and per-email results with privacy and execution badges. Items load only on expansion.
struct ActivityView: View {
    let run: DigestRunModel
    let access: MailAccessModel

    private var model: ActivityModel { run.coordinator.activity }
    private var calendar: Calendar { run.library.calendar }

    var body: some View {
        @Bindable var model = model
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Job type", selection: $model.kindFilter) {
                        ForEach(ActivityModel.KindFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Show Daily jobs, Backlog jobs or both")
                }
                ToolbarItem(placement: .principal) {
                    Picker("Processed by", selection: $model.pathFilter) {
                        ForEach(ActivityModel.PathFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Show jobs with emails processed locally, by Gemini, or both")
                }
            }
            // Progress arrives about twice a second; the model throttles to once a second.
            .onChange(of: run.progress) { _, _ in model.liveRefresh() }
    }

    @ViewBuilder private var content: some View {
        if !model.isLoaded {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.timeline.jobs.isEmpty {
            ContentUnavailableView(model.loadFailed ? "Couldn't Load Activity" : "No Activity",
                                   systemImage: "clock.arrow.circlepath",
                                   description: Text(emptyDescription))
        } else {
            list
        }
    }

    private var emptyDescription: String {
        if model.loadFailed { return "Try again in a moment." }
        if model.kindFilter != .all || model.pathFilter != .all { return "No jobs match these filters." }
        return "Daily and Backlog jobs appear here once they run."
    }

    private var list: some View {
        // Computed once per body; `now` only decides Today and Yesterday, so a stale value is harmless.
        let sections = model.timeline.sections(calendar: calendar, now: SystemClock().now())
        let newest = sections.first?.id
        let lastJobID = model.timeline.jobs.last?.id
        return List {
            ForEach(sections) { section in
                DisclosureGroup(isExpanded: Binding(
                    get: { model.isSectionExpanded(section.id, newest: newest) },
                    set: { model.setSection(section.id, expanded: $0) })) {
                    ForEach(section.jobs) { job in
                        ActivityJobRow(job: job, model: model, calendar: calendar)
                            .onAppear {
                                if job.id == lastJobID { Task { await model.loadMore() } }
                            }
                    }
                } label: {
                    Text(section.title).font(.headline)
                }
            }
            if model.hasMore || model.isLoadingMore {
                footer
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if model.isLoadingMore {
                ProgressView().controlSize(.small)
            } else {
                Button("Load Earlier Activity") { Task { await model.loadMore() } }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        // Reaching the end of the list (even when every day is collapsed) loads the next page.
        .onAppear { Task { await model.loadMore() } }
    }
}

// MARK: - Job row

private struct ActivityJobRow: View {
    let job: Job
    let model: ActivityModel
    let calendar: Calendar

    private var status: ActivityJobStatus { ActivityJobStatus(job) }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.isJobExpanded(job.id) },
            set: { model.setJob(job, expanded: $0) })) {
            ActivityJobDetailView(job: job, detail: model.details[job.id], calendar: calendar)
        } label: {
            header
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.kind == .daily ? "sun.max" : "tray.full")
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(ActivityText.title(job)).font(.body.weight(.medium)).lineLimit(1)
                Text(timesText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                summaryLine
                if status == .running, total > 0 {
                    ProgressView(value: Double(min(finished, total)), total: Double(total))
                        .controlSize(.small)
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Progress")
                        .accessibilityValue(ActivityText.progressText(job))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ActivityText.title(job)), \(status.title)")
        .accessibilityValue(accessibilitySummary)
    }

    private var finished: Int { job.totals.done + job.totals.failed + job.totals.skipped }
    private var total: Int { finished + job.totals.queued }

    private var timesText: String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        var parts: [String] = []
        if let start = job.startedAt { parts.append("Started \(start.formatted(style))") }
        else { parts.append("Created \(job.createdAt.formatted(style))") }
        if let end = job.endedAt, !status.isLive { parts.append("Ended \(end.formatted(style))") }
        return parts.joined(separator: " · ")
    }

    private var summaryLine: some View {
        HStack(spacing: 6) {
            Label(statusText, systemImage: Self.symbol(status))
                .foregroundStyle(Self.tint(status))
            Text("· \(ActivityText.progressText(job))")
            if job.totals.failed > 0 { Text("· \(job.totals.failed) failed") }
            // Live jobs tick once a second; finished ones are static.
            if status.isLive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("· \(ActivityText.elapsedText(ActivityText.elapsed(job, now: context.date)))")
                }
            } else {
                Text("· \(ActivityText.elapsedText(ActivityText.elapsed(job, now: job.endedAt ?? job.createdAt)))")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var statusText: String {
        if status == .paused, let reason = job.pauseReason { return "Paused (\(reason.displayText))" }
        return status.title
    }

    private var accessibilitySummary: String {
        var parts = [ActivityText.progressText(job)]
        if job.totals.failed > 0 { parts.append("\(job.totals.failed) failed") }
        parts.append("elapsed \(ActivityText.elapsedText(ActivityText.elapsed(job, now: job.endedAt ?? job.createdAt)))")
        return parts.joined(separator: ", ")
    }

    static func symbol(_ s: ActivityJobStatus) -> String {
        switch s {
        case .notStarted: return "circle.dashed"
        case .running, .pausing, .stopping: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .stopped: return "stop.circle"
        case .completed: return "checkmark.circle"
        case .completedWithFailures: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        }
    }

    static func tint(_ s: ActivityJobStatus) -> Color {
        switch s {
        case .completed: return .green
        case .completedWithFailures: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Expanded job

private struct ActivityJobDetailView: View {
    let job: Job
    let detail: ActivityJobDetail?
    let calendar: Calendar

    var body: some View {
        if let detail, detail.isLoaded {
            events(detail.events)
            // Only finished items ran a model; skipped ones have no routing to summarise.
            if let summary = RoutingPresentation.localReasonSummaryText(
                detail.items.filter { $0.state == .done }.map(\.routing)) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Processed locally. \(summary.dropFirst("Local: ".count))")
            }
            if detail.items.isEmpty {
                Text("No emails in this job.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(detail.items) { item in
                ActivityItemRow(item: item, calendar: calendar)
            }
        } else if detail?.loadFailed == true {
            Label("Couldn't load this job.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func events(_ events: [JobEvent]) -> some View {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone)
        VStack(alignment: .leading, spacing: 2) {
            Text("Lifecycle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if events.isEmpty {
                Text("Lifecycle history not recorded").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    HStack(spacing: 8) {
                        Text(event.at.formatted(style)).foregroundStyle(.secondary).monospacedDigit()
                        Text(ActivityText.eventText(event))
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Item row

private struct ActivityItemRow: View {
    let item: JobItem
    let calendar: Calendar
    @State private var showsInfo = false

    var body: some View {
        let privacy = RoutingPresentation.privacyBadge(for: item)
        let execution = RoutingPresentation.executionBadge(for: item)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timeText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 64, alignment: .leading)
                Text(item.subject).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let seconds = item.seconds, seconds > 0 {
                    Text("\(Int(seconds.rounded())) s").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("\(ReviewPresentation.senderName(item.sender)) · \(item.outcome ?? stateText)")
                .font(.caption)
                .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                .lineLimit(1)
                .padding(.leading, 72)
            HStack(spacing: 6) {
                if let privacy {
                    badge(privacy, label: "Privacy", symbol: Self.privacySymbol(privacy))
                        .help(routingExplanation ?? "")
                }
                if let execution {
                    badge(execution, label: "Processed by", symbol: Self.executionSymbol(execution))
                }
                if privacy == nil, execution == nil, item.state == .skipped {
                    MetaPillLabel(text: RoutingPresentation.noModelText, symbol: "minus.circle")
                }
                if let routing = item.routing {
                    Button { showsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("Show how this email was routed")
                        .accessibilityLabel("Routing details")
                        .popover(isPresented: $showsInfo, arrowEdge: .bottom) { RoutingDetailView(routing: routing) }
                }
            }
            .padding(.leading, 72)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    /// Tooltip text: the inspection explanation, or the route for a trusted direct send.
    private var routingExplanation: String? {
        item.routing.flatMap(RoutingPresentation.routingExplanation(for:))
    }

    private var timeText: String {
        guard let t = item.finishedAt else { return "" }
        return t.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
    }

    private var stateText: String { item.state.rawValue.capitalized }

    private func badge(_ b: RoutingBadge, label: String, symbol: String) -> some View {
        MetaPillLabel(text: b.text, symbol: symbol, tint: Self.tint(b.tone))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(b.text)")
    }

    static func tint(_ tone: RoutingBadgeTone) -> Color {
        switch tone {
        case .private: return .green
        case .public: return .blue
        case .uncertain, .fallback: return .orange
        case .local: return .gray
        case .cloud: return .blue
        case .neutral: return .secondary
        }
    }

    static func privacySymbol(_ b: RoutingBadge) -> String {
        switch b.tone {
        case .private: return "lock.fill"
        case .public: return "globe"
        case .uncertain: return "questionmark.circle"
        default: return "circle.dashed"
        }
    }

    static func executionSymbol(_ b: RoutingBadge) -> String {
        switch b.tone {
        case .cloud: return "cloud"
        case .fallback: return "exclamationmark.triangle"
        case .local: return "cpu"
        default: return "circle.dashed"
        }
    }
}

/// The info popover: rule, triage model, scores, thresholds and the reason an email stayed local.
private struct RoutingDetailView: View {
    let routing: RoutingProvenance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let explanation = RoutingPresentation.inspectionExplanation(for: routing) {
                Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(RoutingPresentation.details(routing).enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text(line.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(line.value).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if RoutingPresentation.showsScores(routing) {
                Text(RoutingPresentation.scoreNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}
