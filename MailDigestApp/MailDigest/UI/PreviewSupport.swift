#if DEBUG
import MailDigestCore
import SwiftUI

/// Builders for SwiftUI previews. Everything comes from the core sample fixtures; nothing reads Mail,
/// Ollama or the database.
@MainActor
enum PreviewSupport {
    static let sampleState = ReviewState(digest: PreviewFixtures.digest)

    static func review(_ state: ReviewState? = sampleState) -> ReviewViewModel {
        ReviewViewModel(preview: state, emails: PreviewFixtures.emails)
    }

    static func run(review: ReviewViewModel = review(), coordinator: ReviewCoordinator? = nil, reminders: RemindersAuthorization = .granted, progress: JobProgress? = nil, banner: String? = nil,
                    failedJobID: UUID? = nil, foundNothing: Bool = false, jobs: [Job] = [],
                    scheduledRunWaiting: Bool = false) -> DigestRunModel {
        DigestRunModel(preview: SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
                       review: review, coordinator: coordinator, reminders: RemindersAccessModel(preview: reminders), progress: progress, banner: banner, failedJobID: failedJobID,
                       lastRunAt: PreviewFixtures.now, lastRunFoundNothing: foundNothing,
                       lastRunSummary: "Last run 6:45 AM · 4 suggestions · 23 emails",
                       jobs: jobs, scheduledRunWaiting: scheduledRunWaiting)
    }

    /// A persisted job for the menu's Daily action previews (Q52); `PreviewFixtures.jobID` by default, the
    /// job the sample progress describes.
    static func job(_ state: JobState, kind: JobKind = .daily, id: UUID = PreviewFixtures.jobID,
                    lastError: String? = nil) -> Job {
        Job(id: id, kind: kind, mailboxes: [], scopeFrom: PreviewFixtures.now.addingTimeInterval(-86_400),
            scopeTo: PreviewFixtures.now, state: state, createdAt: PreviewFixtures.now,
            totals: JobTotals(queued: 12, done: 11, failed: 0, skipped: 0), autoPaused: false, lastError: lastError)
    }

    /// `PreviewFixtures.pausedProgress` as a Daily job.
    static var pausedDailyProgress: JobProgress {
        var progress = PreviewFixtures.pausedProgress
        progress.kind = .daily
        return progress
    }

    // MARK: Cross-digest review (T24 previews)

    /// Gregorian calendar in the fixtures' time zone.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = PreviewFixtures.timeZone
        return c
    }

    /// The sample digest copied to another day with fresh suggestion ids, so several days can coexist.
    static func digest(daysAgo: Int, id: UUID = UUID()) -> Digest {
        var d = PreviewFixtures.digest
        d.id = id
        d.createdAt = PreviewFixtures.now.addingTimeInterval(-Double(daysAgo) * 86_400)
        d.suggestions = d.suggestions.map { var s = $0; s.id = UUID(); return s }
        return d
    }

    /// A multi-day library: today, two earlier days (the older in another month) and one Backlog job.
    static let backlogID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

    /// The sample Backlog job behind the sidebar entry.
    static var backlogJob: Job {
        var j = job(.paused, kind: .backlog, id: backlogID)
        j.mailboxes = [MailboxRef(account: "iCloud", name: "Inbox")]
        return j
    }

    /// The day before the fixtures' "today", the sample Day selection.
    static var yesterday: DigestDay {
        DigestDay(PreviewFixtures.now.addingTimeInterval(-86_400), calendar: calendar)
    }

    static func library(backlogID: UUID = backlogID, backlogJob: Job? = backlogJob) -> ReviewLibrary {
        let summaries = [
            DigestSummary(id: UUID(), createdAt: PreviewFixtures.now, kind: .daily, emailCount: 23, pendingCount: 4, failedCount: 0),
            DigestSummary(id: UUID(), createdAt: PreviewFixtures.now.addingTimeInterval(-86_400), kind: .daily, emailCount: 12, pendingCount: 2, failedCount: 1),
            DigestSummary(id: UUID(), createdAt: PreviewFixtures.now.addingTimeInterval(-40 * 86_400), kind: .daily, emailCount: 9, pendingCount: 0, failedCount: 0),
            DigestSummary(id: backlogID, createdAt: PreviewFixtures.now.addingTimeInterval(-3_600), kind: .backlog, emailCount: 40, pendingCount: 6, failedCount: 0),
        ]
        let archive = DigestArchive(summaries: summaries, now: PreviewFixtures.now, calendar: calendar)
        return ReviewLibrary(preview: archive, calendar: calendar, backlogJobs: backlogJob.map { [$0] } ?? [])
    }

    /// Today with no digest and no carry-over, for the "Inbox zero" state.
    static func emptyTodayCoordinator(review: ReviewViewModel) -> ReviewCoordinator {
        let today = TodayCanvasModel(
            preview: DayCanvasModel(preview: DayContent(digests: []), emails: [:]),
            carryOver: PagedRecordsModel(preview: [], pageSize: 100))
        return ReviewCoordinator(preview: library(), review: review, today: today)
    }

    /// A coordinator with multi-day fixtures and no store: Today (with carry-over), a Day, a Backlog batch,
    /// the Review Queue and the Logbook all filled, so each canvas can be previewed by `selection`.
    static func coordinator(selection: SidebarItem = .today, review: ReviewViewModel = review(),
                            writer: (any ReminderWriter)? = RecordingReminderWriter()) -> ReviewCoordinator {
        let emails = PreviewFixtures.emails
        let todayDigest = digest(daysAgo: 0)
        let earlier = digest(daysAgo: 1)
        let carry = SuggestionRecord.records(from: earlier, kind: .daily, emails: emails)
            .filter { $0.suggestion.status == .pending }
        let todayContent = DayContent(digests: [todayDigest], kind: .daily, emails: emails)
        let owners = Dictionary(uniqueKeysWithValues: todayDigest.info.map {
            ($0.id, InfoOwner(digestID: todayDigest.id, createdAt: todayDigest.createdAt))
        })
        let today = TodayCanvasModel(
            preview: DayCanvasModel(preview: todayContent, emails: emails, owners: owners),
            carryOver: PagedRecordsModel(preview: carry, pageSize: 100))
        let day = DayCanvasModel(preview: DayContent(digests: [earlier], kind: .daily, emails: emails), emails: emails)
        let backlogDigest = digest(daysAgo: 0)
        let batching = BacklogBatching(jobOrder: backlogDigest.suggestions.map(\.emailID),
                                       resultIDs: Set(backlogDigest.suggestions.map(\.emailID)), size: 2)
        let backlog = BacklogCanvasModel(
            preview: DayContent(digests: [batching.digest(backlogDigest, batch: 0)], kind: .backlog, emails: emails),
            emails: emails, batching: batching)
        let queueRecords = carry + SuggestionRecord.records(from: backlogDigest, kind: .backlog, emails: emails)
        var decided = SuggestionRecord.records(from: earlier, kind: .daily, emails: emails).prefix(2).map { r -> SuggestionRecord in
            var r = r
            r.suggestion.status = .approved
            r.suggestion.decidedAt = PreviewFixtures.now
            return r
        }
        decided[1].suggestion.status = .dismissed
        let c = coordinator(selection: selection, review: review, writer: writer, today: today, day: day, backlog: backlog,
                            queue: queueRecords, decided: decided)
        return c
    }

    private static func coordinator(selection: SidebarItem, review: ReviewViewModel, writer: (any ReminderWriter)?,
                                    today: TodayCanvasModel, day: DayCanvasModel, backlog: BacklogCanvasModel,
                                    queue: [SuggestionRecord], decided: [SuggestionRecord]) -> ReviewCoordinator {
        ReviewCoordinator(
            preview: library(), review: review, today: today, day: day, backlog: backlog,
            reviewQueue: PagedRecordsModel(preview: queue, groups: ReviewCanvasLogic.groupByDay(queue, calendar: calendar)),
            logbook: PagedRecordsModel(preview: decided), selection: selection, writer: writer)
    }

    static let fastLocal = MailAccessStatus(fullDiskAccess: .granted, automation: .granted)
    static let fallback = MailAccessStatus(fullDiskAccess: .denied, automation: .granted)
    static let automationDenied = MailAccessStatus(fullDiskAccess: .denied, automation: .denied)
}

/// The review window over multi-day fixtures, selecting one sidebar item.
@MainActor private func window(_ selection: SidebarItem = .today, progress: JobProgress? = nil, banner: String? = nil,
                               failedJobID: UUID? = nil, reminders: RemindersAuthorization = .granted,
                               writer: (any ReminderWriter)? = RecordingReminderWriter(),
                               status: MailAccessStatus = PreviewSupport.fastLocal,
                               foundNothing: Bool = false, review: ReviewViewModel = PreviewSupport.review(),
                               coordinator: ReviewCoordinator? = nil) -> some View {
    let coordinator = coordinator ?? PreviewSupport.coordinator(selection: selection, review: review, writer: writer)
    let run = PreviewSupport.run(review: review, coordinator: coordinator, reminders: reminders, progress: progress,
                                 banner: banner, failedJobID: failedJobID, foundNothing: foundNothing)
    return ReviewWindow(run: run, access: MailAccessModel(preview: status))
        .frame(width: 980, height: 680)
}

#Preview("Window · Today with carry-over") { window() }

#Preview("Window · Day") { window(.day(PreviewSupport.yesterday)) }

#Preview("Window · Backlog") { window(.backlog(PreviewSupport.backlogID)) }

#Preview("Window · Review Queue") { window(.reviewQueue) }

#Preview("Window · Logbook") { window(.logbook) }

#Preview("Window · Mail Cleanup") { window(.mailCleanup) }

#Preview("Window · running job") { window(progress: PreviewFixtures.runningProgress) }

#Preview("Window · paused job") { window(progress: PreviewFixtures.pausedProgress) }

#Preview("Window · Ollama down") {
    window(banner: "Ollama isn't running. Start Ollama, or run `ollama pull qwen3:4b`.", failedJobID: PreviewFixtures.jobID)
}

#Preview("Window · Full Disk Access unavailable") { window(status: PreviewSupport.fallback) }

#Preview("Window · Mail Automation denied") { window(status: PreviewSupport.automationDenied) }

#Preview("Window · Reminders unavailable") { window(reminders: .unavailable, writer: nil) }

#Preview("Window · Reminders access needed") { window(reminders: .notDetermined, writer: nil) }

#Preview("Window · no new mail") {
    let review = PreviewSupport.review(ReviewState(digest: PreviewFixtures.emptyDigest))
    return window(foundNothing: true, review: review,
                  coordinator: PreviewSupport.emptyTodayCoordinator(review: review))
}

@MainActor private func menu(_ run: DigestRunModel) -> some View {
    MenuBarView(run: run, access: MailAccessModel(preview: PreviewSupport.fastLocal))
}

#Preview("Menu bar") {
    menu(PreviewSupport.run(progress: PreviewFixtures.runningProgress,
                            jobs: [PreviewSupport.job(.running, kind: .backlog)]))
}

#Preview("Menu · Run Now") { menu(PreviewSupport.run()) }

#Preview("Menu · Daily paused → Resume") {
    menu(PreviewSupport.run(progress: PreviewSupport.pausedDailyProgress, jobs: [PreviewSupport.job(.paused)],
                            scheduledRunWaiting: true))
}

#Preview("Menu · Backlog paused → Run Now") {
    menu(PreviewSupport.run(progress: PreviewFixtures.pausedProgress, jobs: [PreviewSupport.job(.paused, kind: .backlog)]))
}

#Preview("Menu · Daily running") {
    menu(PreviewSupport.run(progress: PreviewFixtures.dailyRunningProgress, jobs: [PreviewSupport.job(.running)]))
}

#Preview("Menu · Daily stopping") {
    var stopping = PreviewFixtures.dailyRunningProgress
    stopping.state = .stopping
    return menu(PreviewSupport.run(progress: stopping, jobs: [PreviewSupport.job(.running)]))
}

#Preview("Menu · Daily stopped") { menu(PreviewSupport.run(jobs: [PreviewSupport.job(.stopped)])) }

#Preview("Menu · Daily failed → Retry") {
    menu(PreviewSupport.run(jobs: [PreviewSupport.job(.failed, lastError: "Ollama isn't running. Start Ollama, or run `ollama pull qwen3:4b`.")]))
}

#Preview("Menu · two unfinished Daily jobs") {
    menu(PreviewSupport.run(jobs: [PreviewSupport.job(.paused, id: UUID()), PreviewSupport.job(.stopped, id: UUID())]))
}

#Preview("Settings") {
    SettingsView(run: PreviewSupport.run())
}
#endif
