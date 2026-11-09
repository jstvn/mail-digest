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
                    scheduledRunWaiting: Bool = false, bannerKind: JobFailureKind? = nil,
                    dailyStartFailedAt: Date? = nil, mailboxes: [MailboxInfo] = []) -> DigestRunModel {
        DigestRunModel(preview: SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
                       review: review, coordinator: coordinator, reminders: RemindersAccessModel(preview: reminders), progress: progress, banner: banner, failedJobID: failedJobID,
                       lastRunAt: PreviewFixtures.now, lastRunFoundNothing: foundNothing,
                       lastRunSummary: "Last run 6:45 AM · 4 suggestions · 23 emails",
                       jobs: jobs, scheduledRunWaiting: scheduledRunWaiting,
                       bannerKind: bannerKind, dailyStartFailedAt: dailyStartFailedAt, mailboxes: mailboxes)
    }

    /// A persisted job for the menu's Daily action previews (Q52); `PreviewFixtures.jobID` by default, the
    /// job the sample progress describes.
    static func job(_ state: JobState, kind: JobKind = .daily, id: UUID = PreviewFixtures.jobID,
                    lastError: String? = nil, failureKind: JobFailureKind? = nil,
                    startedAt: Date? = PreviewFixtures.now.addingTimeInterval(-3_600)) -> Job {
        Job(id: id, kind: kind, mailboxes: [], scopeFrom: PreviewFixtures.now.addingTimeInterval(-86_400),
            scopeTo: PreviewFixtures.now, state: state, createdAt: PreviewFixtures.now,
            totals: JobTotals(queued: 12, done: 11, failed: 0, skipped: 0), autoPaused: false, lastError: lastError,
            startedAt: startedAt, failureKind: failureKind)
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

    /// Today with no digest, for the "Inbox zero" state.
    static func emptyTodayCoordinator(review: ReviewViewModel) -> ReviewCoordinator {
        let today = TodayCanvasModel(
            preview: DayCanvasModel(preview: DayContent(digests: []), emails: [:]))
        return ReviewCoordinator(preview: library(), review: review, today: today)
    }

    /// A coordinator with multi-day fixtures and no store: Today, a Day, a Backlog batch,
    /// the Review Queue and the Logbook all filled, so each canvas can be previewed by `selection`.
    static func coordinator(selection: SidebarItem = .today, review: ReviewViewModel = review(),
                            writer: (any ReminderWriter)? = RecordingReminderWriter()) -> ReviewCoordinator {
        var emails = PreviewFixtures.emails
        var todayDigest = digest(daysAgo: 0)
        // Every card state on Today: a failed write, a decided (read-only) suggestion, and two orders from one
        // sender that collapse into one Worth Knowing card with a total.
        if todayDigest.suggestions.count >= 4 {
            todayDigest.suggestions[3].status = .failed
            var added = todayDigest.suggestions[0]
            added.id = UUID()
            added.status = .approved
            todayDigest.suggestions.append(added)
        }
        let box = MailboxRef(account: "iCloud", name: "Inbox")
        for (id, total) in [("coles1@example.com", "$17.45"), ("coles2@example.com", "$33.90")] {
            todayDigest.info.append(InfoItem(id: id, emailID: id, category: .personal, importance: 3,
                                             summary: "Your Coles order was delivered.", keyFacts: ["Total \(total)"], pinned: false))
            emails[id] = EmailContext(sender: "Coles <orders@coles.example>", subject: "Your order", mailbox: box,
                                      receivedAt: PreviewFixtures.now.addingTimeInterval(-86_400))
        }
        let earlier = digest(daysAgo: 1)
        let carry = SuggestionRecord.records(from: earlier, kind: .daily, emails: emails)
            .filter { $0.suggestion.status == .pending }
        let todayContent = DayContent(digests: [todayDigest], kind: .daily, emails: emails)
        let owners = Dictionary(uniqueKeysWithValues: todayDigest.info.map {
            ($0.id, InfoOwner(digestID: todayDigest.id, createdAt: todayDigest.createdAt))
        })
        let today = TodayCanvasModel(
            preview: DayCanvasModel(preview: todayContent, emails: emails, owners: owners),
            runInfo: RunInfo(localEmails: 20, cloudEmails: 3, localModel: "qwen3:4b", cloudModel: "gemini-3.5-flash-lite",
                             finishedAt: PreviewFixtures.now, duration: 46 * 60))
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
        .frame(width: 1200, height: 760)
}

#Preview("Window · Today") { window() }

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

/// The menu panel with a Daily digest in the library, so the last-run row shows.
@MainActor private func menuRun(progress: JobProgress? = nil, banner: String? = nil, failedJobID: UUID? = nil,
                                jobs: [Job] = [], scheduledRunWaiting: Bool = false,
                                bannerKind: JobFailureKind? = nil, dailyStartFailedAt: Date? = nil) -> DigestRunModel {
    PreviewSupport.run(coordinator: PreviewSupport.coordinator(), progress: progress, banner: banner,
                       failedJobID: failedJobID, jobs: jobs, scheduledRunWaiting: scheduledRunWaiting,
                       bannerKind: bannerKind, dailyStartFailedAt: dailyStartFailedAt)
}

#Preview("Menu · Backlog running") {
    menu(menuRun(progress: PreviewFixtures.runningProgress, jobs: [PreviewSupport.job(.running, kind: .backlog)]))
}

#Preview("Menu · Daily running") {
    menu(menuRun(progress: PreviewFixtures.dailyRunningProgress, jobs: [PreviewSupport.job(.running)]))
}

#Preview("Menu · Run Daily Digest Now") { menu(menuRun()) }

#Preview("Menu · no digest yet") { menu(PreviewSupport.run()) }

#Preview("Menu · Daily paused → Resume") {
    menu(menuRun(progress: PreviewSupport.pausedDailyProgress, jobs: [PreviewSupport.job(.paused)],
                 scheduledRunWaiting: true))
}

#Preview("Menu · Backlog paused") {
    menu(menuRun(progress: PreviewFixtures.pausedProgress, jobs: [PreviewSupport.job(.paused, kind: .backlog)]))
}

#Preview("Menu · Daily stopping") {
    var stopping = PreviewFixtures.dailyRunningProgress
    stopping.state = .stopping
    return menu(menuRun(progress: stopping, jobs: [PreviewSupport.job(.running)]))
}

#Preview("Menu · Daily stopped") { menu(menuRun(jobs: [PreviewSupport.job(.stopped)])) }

#Preview("Menu · Ollama isn't running") {
    menu(menuRun(jobs: [PreviewSupport.job(.failed, lastError: "Ollama is not reachable. Start Ollama and try again.",
                                           failureKind: .ollamaUnreachable, startedAt: PreviewFixtures.now.addingTimeInterval(-300))]))
}

#Preview("Menu · Ollama down at Daily start") {
    menu(menuRun(banner: "Ollama is not reachable. Start Ollama and try again.", bannerKind: .ollamaUnreachable,
                 dailyStartFailedAt: PreviewFixtures.now.addingTimeInterval(-300)))
}

#Preview("Menu · Model isn't installed") {
    menu(menuRun(jobs: [PreviewSupport.job(.failed, lastError: "The model qwen3:4b is not installed. Run: ollama pull qwen3:4b",
                                           failureKind: .modelMissing)]))
}

#Preview("Menu · Daily failed (generic)") {
    menu(menuRun(jobs: [PreviewSupport.job(.failed, lastError: "Ollama returned HTTP 500.", failureKind: .other)]))
}

#Preview("Menu · other banner") {
    menu(menuRun(banner: "No inboxes found in Mail."))
}

#Preview("Menu · two unfinished Daily jobs") {
    menu(menuRun(jobs: [PreviewSupport.job(.paused, id: UUID()), PreviewSupport.job(.stopped, id: UUID())]))
}

#Preview("Settings") {
    SettingsView(run: PreviewSupport.run(),
                 access: MailAccessModel(preview: MailAccessStatus(fullDiskAccess: .granted, automation: .granted)))
}
#endif
