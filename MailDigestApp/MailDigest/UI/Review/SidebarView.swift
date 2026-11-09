import AppKit
import MailDigestCore
import SwiftUI

/// The review window's sidebar: workflows, a month calendar of digests, Backlog jobs and the footer.
/// It reads only the library's summaries, so it never loads a digest.
struct SidebarView: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openWindow) private var openWindow

    @State private var showsJob = false
    @State private var renaming: UUID?
    @State private var deleting: UUID?
    @State private var nameDraft = ""

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var library: ReviewLibrary { run.library }
    private var archive: DigestArchive { library.archive }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { coordinator.selection }, set: { if let item = $0 { coordinator.select(item) } })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                row(.today, badge: archive.todayCount) {
                    Label { Text("Today") } icon: { SidebarTile(.today) }
                }
                row(.reviewQueue, badge: archive.reviewQueueCount) {
                    Label { Text("Review Queue") } icon: { SidebarTile(.reviewQueue) }
                }
                row(.logbook) {
                    Label { Text("Logbook") } icon: { SidebarTile(.logbook) }
                }
                row(.mailCleanup, badge: run.processed.allEntries.count) {
                    Label { Text("Mail Cleanup") } icon: { SidebarTile(.mailCleanup) }
                }
                row(.activity) {
                    Label { Text("Activity") } icon: { SidebarTile(.activity) }
                }
            }

            Section {
                MiniMonthCalendar(archive: archive, calendar: library.calendar, selection: coordinator.selection) {
                    coordinator.select($0)
                }
                .listRowSeparator(.hidden)
                .selectionDisabled()
            }

            Section("Backlog Jobs") {
                ForEach(archive.backlogs) { backlog in
                    backlogRow(backlog)
                }
                Button {
                    openWindow(id: "job-setup")
                    NSApp.activate()
                } label: {
                    Label("New Backlog Job…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .selectionDisabled()
                .disabled(run.isRunning || access.status?.mode == .unavailable)
                .help("Process older mail in the mailboxes you choose")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onChange(of: run.activeProgress == nil) { _, none in
            if none { showsJob = false }
        }
        .alert("Rename Backlog Job", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let id = renaming { Task { await run.renameBacklogJob(id, to: nameDraft) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to use the mailbox name.")
        }
        .alert("Delete This Backlog Job?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleting { Task { await run.deleteBacklogJob(id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its digest and suggestions are removed from Mail Digest. Your mail and any reminders you already added are not affected.")
        }
    }

    /// A selectable sidebar row; the order of `.badge` and `.tag` lives in `selectableRow`.
    private func row<Content: View>(_ item: SidebarItem, badge: Int? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
        content().selectableRow(item, badge: badge)
    }

    // MARK: Backlog jobs

    /// The state the row shows: the runner's live state for the job it holds, otherwise the stored one.
    private func effectiveState(_ job: Job?, id: UUID) -> JobState {
        if let live = run.activeProgress, live.jobID == id { return live.state }
        return job?.state ?? .finished
    }

    private func backlogRow(_ backlog: ArchiveBacklog) -> some View {
        let job = library.backlogJobs[backlog.id]
        let state = effectiveState(job, id: backlog.id)
        let isRunning = [.listing, .running, .pausing].contains(state)
        let actions = BacklogJobActions(
            state: state, isLoaded: run.activeProgress?.jobID == backlog.id,
            anotherJobRuns: run.isRunning)
        return row(.backlog(backlog.id), badge: isRunning ? nil : backlog.actionableCount) {
            backlogLabel(backlog.id, job: job, state: state, isRunning: isRunning)
        }
        .contextMenu {
            Button("Pause") { run.pause() }.disabled(!actions.canPause)
            Button("Resume") { Task { await run.resumeJob(backlog.id) } }.disabled(!actions.canResume)
            Button("Stop") { run.stop() }.disabled(!actions.canStop)
            Divider()
            Button("Rename…") {
                nameDraft = job?.name ?? ""
                renaming = backlog.id
            }
            Button("Delete…", role: .destructive) { deleting = backlog.id }
                .disabled(!actions.canDelete)
        }
    }

    /// The job's name (or, until it has one, the mailbox name) over its subtitle, with a progress ring while it runs.
    private func backlogLabel(_ id: UUID, job: Job?, state: JobState, isRunning: Bool) -> some View {
        let name = job?.name
        let title = name ?? library.sidebarTitle(forBacklog: id)
        let scope = library.scope(forBacklog: id)
        let subtitle = rowSubtitle(job: job, state: state, id: id, named: name != nil, scope: scope)
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(subtitle.map { "\(title)\n\($0)" } ?? title)
        } icon: {
            if isRunning, let live = run.activeProgress, live.jobID == id {
                pillIndicator(live)
            } else {
                Image(systemName: "tray.and.arrow.down")
            }
        }
    }

    /// Named running job: "iCloud, Outlook · 52%". Paused and Stopped say so, so the two stay distinct (Q48, Q78).
    private func rowSubtitle(job: Job?, state: JobState, id: UUID, named: Bool, scope: String?) -> String? {
        let percent: Int?
        if let live = run.activeProgress, live.jobID == id, live.total > 0 {
            percent = Int(Double(min(live.done, live.total)) / Double(live.total) * 100)
        } else {
            percent = job.flatMap { BacklogRowText.percent($0.totals) }
        }
        switch state {
        case .listing, .running, .pausing:
            guard named, let job else { return scope }
            return BacklogRowText.runningSubtitle(accounts: BacklogRowText.accounts(of: job), percent: percent)
        case .paused, .stopped, .stopping:
            let word = state == .paused ? "Paused" : "Stopped"
            let detail = named ? percent.map { "\($0)%" } : scope
            return detail.map { "\(word) · \($0)" } ?? word
        default:
            return scope
        }
    }

    // MARK: Footer

    /// Idle: when the next scheduled digest runs. Running or paused: the task capsule.
    @ViewBuilder private var footer: some View {
        if run.activeProgress != nil {
            jobPill
        } else {
            // Re-evaluated each minute so "today at" turns into "tomorrow at" once the time passes.
            TimelineView(.everyMinute) { context in
                let schedule = run.settings.settings
                Label(NextDigestText.text(now: context.date, hour: schedule.runHour, minute: schedule.runMinute,
                                          timeZone: library.calendar.timeZone), systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: Job status

    @ViewBuilder private var jobPill: some View {
        if let progress = run.activeProgress {
            let name = ReviewPresentation.jobName(progress.kind)
            let counts = Self.pillCounts(progress)
            Button { showsJob.toggle() } label: {
                HStack(spacing: 8) {
                    pillIndicator(progress)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).font(.callout.weight(.medium))
                        Text(counts).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(10)
            .popover(isPresented: $showsJob, arrowEdge: .trailing) { jobPopover(progress) }
            .help("Show job progress")
            .accessibilityLabel("\(name) job")
            .accessibilityValue(counts)
            .accessibilityHint("Shows progress and recent emails")
        }
    }

    @ViewBuilder private func pillIndicator(_ progress: JobProgress) -> some View {
        if progress.state == .listing || progress.total == 0 {
            ProgressView().controlSize(.small)
        } else {
            ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
    }

    private func jobPopover(_ progress: JobProgress) -> some View {
        JobProgressView(run: run, progress: progress, onReveal: { emailID in
            showsJob = false
            Task { await coordinator.reveal(emailID: emailID, jobID: progress.jobID, kind: progress.kind) }
        }, onViewAll: {
            showsJob = false
            openWindow(id: "review")
            NSApp.activate()
            coordinator.select(.activity)
        })
        .padding(14)
        .frame(width: 440)
    }

    /// "12 of 23", "Paused · 412 of 2,960", "Looking for new mail…".
    static func pillCounts(_ p: JobProgress) -> String {
        let counts = "\(JobFormat.number(p.done)) of \(JobFormat.number(p.total))"
        switch p.state {
        case .listing: return "Looking for new mail…"
        case .paused: return "Paused · \(counts)"
        case .pausing: return "Pausing · \(counts)"
        case .stopping: return "Stopping…"
        default: return p.total == 0 ? "Starting…" : counts
        }
    }
}

private extension View {
    /// `.tag` must be the outermost modifier: `List(selection:)` does not see a tag that `.badge` wraps, so
    /// such rows would never show as selected or accept selection. A zero badge is hidden.
    func selectableRow(_ item: SidebarItem, badge: Int?) -> some View {
        self.badge(badge ?? 0)
            .tag(item)
    }
}
