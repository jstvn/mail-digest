import Foundation
import Testing
@testable import MailDigestCore

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Australia/Brisbane")!
    return c
}

private func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func job(_ boxes: [(String, String)] = [("iCloud", "INBOX"), ("Outlook", "Inbox")], name: String? = nil,
                 from: Date = at(2026, 10, 1), to: Date = at(2026, 10, 31), state: JobState = .stopped,
                 overnight: Bool = false, reason: PauseReason? = nil) -> Job {
    Job(id: UUID(), kind: .backlog, mailboxes: boxes.map { MailboxRef(account: $0.0, name: $0.1) },
        scopeFrom: from, scopeTo: to, state: state, createdAt: .now,
        totals: JobTotals(queued: 48, done: 52, failed: 0, skipped: 0), autoPaused: false,
        pauseReason: reason, name: name, overnightOnly: overnight)
}

@Suite struct BacklogRowTextTests {
    @Test func titleIsTheRangeOrTheCustomName() {
        #expect(BacklogRowText.title(job(from: at(2026, 10, 21), to: at(2026, 10, 21)), calendar: cal) == "21 Oct 2026")
        #expect(BacklogRowText.title(job(), calendar: cal) == "1\u{2013}31 Oct 2026")
        #expect(BacklogRowText.title(job(from: at(2026, 10, 21), to: at(2026, 11, 4)), calendar: cal) == "21 Oct \u{2013} 4 Nov 2026")
        #expect(BacklogRowText.title(job(from: at(2025, 12, 21), to: at(2026, 1, 4)), calendar: cal) == "21 Dec 2025 \u{2013} 4 Jan 2026")
        #expect(BacklogRowText.title(job(name: "Tax time"), calendar: cal) == "Tax time")
        #expect(BacklogRowText.title(job(name: "  "), calendar: cal) == "1\u{2013}31 Oct 2026")
    }

    @Test func inboxesAreNotSpelledOutAndFoldersAre() {
        #expect(BacklogRowText.locations(of: job()) == "iCloud, Outlook")
        #expect(BacklogRowText.locations(of: job([("iCloud", "INBOX"), ("iCloud", "Inbox"), ("Outlook", "Inbox")])) == "iCloud, Outlook")
        #expect(BacklogRowText.locations(of: job([("iCloud", "INBOX"), ("Outlook", "Archive")])) == "iCloud, Outlook Archive")
        #expect(BacklogRowText.locations(of: job([])) == "")
    }

    @Test func subtitleStatuses() {
        let j = job()
        func text(_ state: JobState, _ percent: Int? = nil, _ job: Job? = nil) -> String {
            BacklogRowText.subtitle(job ?? j, state: state, percent: percent, startMinute: 22 * 60)
        }
        #expect(text(.running, 52) == "iCloud, Outlook \u{B7} 52%")
        #expect(text(.listing) == "iCloud, Outlook \u{B7} Starting\u{2026}")
        #expect(text(.stopped) == "iCloud, Outlook \u{B7} Stopped")
        #expect(text(.paused) == "iCloud, Outlook \u{B7} Paused")
        #expect(text(.finished) == "iCloud, Outlook \u{B7} Done")
        #expect(text(.failed) == "iCloud, Outlook \u{B7} Failed")
        let waiting = job(state: .paused, overnight: true, reason: .quietHours)
        #expect(text(.paused, nil, waiting) == "iCloud, Outlook \u{B7} Waiting for 10 pm")
        // A running job is not "waiting", even if its stored copy still says so.
        #expect(text(.running, 3, waiting) == "iCloud, Outlook \u{B7} 3%")
        #expect(BacklogRowText.subtitle(waiting, state: .paused, percent: nil, startMinute: 21 * 60 + 30)
                == "iCloud, Outlook \u{B7} Waiting for 9:30 pm")
        #expect(BacklogRowText.subtitle(job([]), state: .finished, percent: nil, startMinute: 0) == "Done")
    }
}

@Suite struct ToolbarRunActionTests {
    private let id = UUID()
    private func progress(_ state: JobState, kind: JobKind = .daily, id: UUID? = nil) -> JobProgress {
        var p = PreviewFixtures.runningProgress
        p.jobID = id ?? self.id
        p.kind = kind
        p.state = state
        return p
    }
    private func daily(_ lifecycle: DailyLifecycle) -> DailyMenuAction { lifecycle.menuAction }
    private func dailyJob(_ state: JobState) -> Job {
        Job(id: id, kind: .daily, mailboxes: [], scopeFrom: .now, scopeTo: .now, state: state, createdAt: .now,
            totals: JobTotals(queued: 3, done: 1, failed: 0, skipped: 0), autoPaused: false)
    }

    @Test func idleIsRunNow() {
        let a = ToolbarRunAction(progress: nil, daily: daily(.none))
        #expect(a.title == "Run Now" && a.systemImage == "play.fill" && a.behavior == .runNow)
    }

    @Test func aRunningJobPauses() {
        let a = ToolbarRunAction(progress: progress(.running, kind: .backlog), daily: daily(.none))
        #expect(a.title == "Pause" && a.systemImage == "pause.fill" && a.behavior == .pause)
        #expect(ToolbarRunAction(progress: progress(.listing), daily: .running).behavior == .pause)
        #expect(ToolbarRunAction(progress: progress(.pausing), daily: .running).behavior == .unavailable)
    }

    @Test func aPausedJobResumes() {
        let backlog = ToolbarRunAction(progress: progress(.paused, kind: .backlog, id: UUID()), daily: daily(.none))
        #expect(backlog.title == "Resume" && backlog.behavior != .runNow)
        let d = ToolbarRunAction(progress: progress(.paused), daily: daily(.paused(dailyJob(.paused))))
        #expect(d.title == "Resume" && d.behavior == .resumeDaily(id))
        // Without a strip the Daily lifecycle alone still offers it.
        #expect(ToolbarRunAction(progress: nil, daily: daily(.paused(dailyJob(.paused)))).behavior == .resumeDaily(id))
    }

    @Test func aFailureOffersRetry() {
        let failed = ToolbarRunAction(progress: nil, daily: daily(.failed(dailyJob(.failed))))
        #expect(failed.title == "Retry" && failed.systemImage == "arrow.clockwise" && failed.behavior == .retryDaily(id))
        let start = ToolbarRunAction(progress: nil, daily: .retryStart)
        #expect(start.title == "Retry" && start.behavior == .runNow)
    }

    @Test func decisionStatesStayDisabledRunNow() {
        let stopped = ToolbarRunAction(progress: nil, daily: daily(.stopped(dailyJob(.stopped))))
        #expect(stopped.title == "Run Now" && stopped.behavior == .unavailable && !stopped.help.isEmpty)
        #expect(ToolbarRunAction(progress: nil, daily: daily(.conflict([dailyJob(.stopped)]))).behavior == .unavailable)
    }
}
