import AppKit
import MailDigestCore
import SwiftUI

/// The review window's sidebar: workflows, Recent Digests by month, Backlog jobs and the job status pill.
/// It reads only the library's summaries, so it never loads a digest.
struct SidebarView: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openWindow) private var openWindow

    /// Months the user opened or closed this session; others follow the default (current month open).
    @State private var monthExpansion: [DigestMonth: Bool] = [:]
    @State private var showsJob = false

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var library: ReviewLibrary { run.library }
    private var archive: DigestArchive { library.archive }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { coordinator.selection }, set: { if let item = $0 { coordinator.select(item) } })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                Label("Today", systemImage: "sun.max")
                    .tag(SidebarItem.today)
                    .badge(archive.todayCount)
                Label("Review Queue", systemImage: "tray.full")
                    .tag(SidebarItem.reviewQueue)
                    .badge(archive.reviewQueueCount)
                Label("Logbook", systemImage: "checkmark.circle")
                    .tag(SidebarItem.logbook)
                Label("Mail Cleanup", systemImage: "archivebox")
                    .tag(SidebarItem.mailCleanup)
            }

            if !archive.months.isEmpty {
                Section("Recent Digests") {
                    ForEach(archive.months) { month in
                        DisclosureGroup(isExpanded: expansion(of: month)) {
                            ForEach(month.days) { day in dayRow(day) }
                        } label: {
                            Text(ReviewDateText.month(month.month, calendar: library.calendar))
                        }
                    }
                }
            }

            Section("Backlog Jobs") {
                ForEach(archive.backlogs) { backlog in
                    Label(library.title(forBacklog: backlog.id), systemImage: "tray.and.arrow.down")
                        .lineLimit(1)
                        .tag(SidebarItem.backlog(backlog.id))
                        .badge(backlog.actionableCount)
                }
                Button {
                    openWindow(id: "job-setup")
                    NSApp.activate()
                } label: {
                    Label("New Backlog Job…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(run.isRunning || access.status?.mode == .unavailable)
                .help("Process older mail in the mailboxes you choose")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { jobPill }
        .onChange(of: run.activeProgress == nil) { _, none in
            if none { showsJob = false }
        }
    }

    // MARK: Recent digests

    private func dayRow(_ day: ArchiveDay) -> some View {
        let title = ReviewDateText.day(day.day, calendar: library.calendar)
        return HStack {
            Text(title)
            Spacer(minLength: 4)
            Text("\(day.emailCount)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(day.emailCount) \(day.emailCount == 1 ? "email" : "emails")")
        .tag(SidebarItem.day(day.day))
        .badge(day.actionableCount)
    }

    /// The current month, and the one holding the selected day, start open; the rest start collapsed.
    private func expansion(of month: ArchiveMonth) -> Binding<Bool> {
        Binding(
            get: {
                if let chosen = monthExpansion[month.month] { return chosen }
                let current = DigestMonth(DigestDay(archive.startOfToday, calendar: library.calendar))
                if month.month == current { return true }
                if case .day(let d) = coordinator.selection { return DigestMonth(d) == month.month }
                return false
            },
            set: { monthExpansion[month.month] = $0 })
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
            .accessibilityHint("Shows progress, recent emails and the activity log")
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
        ScrollView {
            JobProgressView(run: run, progress: progress) { emailID in
                showsJob = false
                Task { await coordinator.reveal(emailID: emailID, jobID: progress.jobID, kind: progress.kind) }
            }
            .padding(14)
        }
        .frame(width: 440, height: 480)
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
