import Foundation
import Testing
@testable import MailDigestCore

private let brisbane = TimeZone(identifier: "Australia/Brisbane")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = brisbane
    return c
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func box(_ account: String, _ name: String, _ kind: MailboxKind, count: Int) -> MailboxInfo {
    MailboxInfo(ref: MailboxRef(account: account, name: name), messageCount: count, unreadCount: 0, kind: kind)
}

private func job(_ state: JobState = .finished, ended: Date, id: UUID = UUID()) -> Job {
    Job(id: id, kind: .backlog, mailboxes: [], scopeFrom: ended, scopeTo: ended, state: state, createdAt: ended,
        totals: JobTotals(queued: 0, done: 1, failed: 0, skipped: 0), autoPaused: false, endedAt: ended)
}

private func item(_ jobID: UUID, seconds: Double?, state: JobItemState = .done, provider: ExecutionProvider? = .local) -> JobItem {
    JobItem(id: UUID(), jobID: jobID, messageID: UUID().uuidString, mailbox: MailboxRef(account: "iCloud", name: "Inbox"),
            sender: "a@b.c", subject: "s", receivedAt: .now, position: 1, state: state, outcome: "ok", seconds: seconds,
            attempts: 1, lastError: nil, provider: provider)
}

@Suite struct NoiseMailboxTests {
    @Test func emptyMailboxesAreNoise() {
        #expect(isNoiseMailbox(name: "Archive", messageCount: 0))
        #expect(!isNoiseMailbox(name: "Archive", messageCount: 3))
    }

    @Test func systemFoldersAreNoiseWhateverTheirCountOrCase() {
        for name in ["Outbox", "DRAFTS", "Sent Items", "Junk Email", "Deleted Messages", "Trash", "Recovered Messages",
                     "SendLater", "Notes", "Tasks", "Journal", "Conversation History", "Starred", "Sent (3)"] {
            #expect(isNoiseMailbox(name: name, messageCount: 12), "\(name)")
        }
    }

    @Test func listMirroringFoldersAreNoise() {
        #expect(isNoiseMailbox(name: "Untitled list 2", messageCount: 4))
        #expect(isNoiseMailbox(name: "Deleted Items/Old", messageCount: 4))
    }

    @Test func ordinaryFoldersAreNot() {
        for name in ["Inbox", "Archive", "Projects/2026", "Notes for Mum", "Sentinel"] {
            #expect(!isNoiseMailbox(name: name, messageCount: 5), "\(name)")
        }
    }
}

@Suite struct MailboxPartitionTests {
    private let boxes = [
        box("iCloud", "INBOX", .inbox, count: 2_555), box("iCloud", "Archive", .archive, count: 568),
        box("iCloud", "Mail Digest", .custom, count: 14), box("iCloud", "Sent Messages", .sent, count: 90),
        box("iCloud", "Empty Folder", .custom, count: 0),
        box("Outlook", "Inbox", .inbox, count: 1_075), box("Outlook", "Notes", .custom, count: 8),
        box("Outlook", "Untitled list", .custom, count: 3), box("Outlook", "Archive", .archive, count: 1_016),
    ]

    @Test func usefulAndNoiseSplitByAccount() {
        let p = MailboxTree.partition(boxes)
        #expect(p.useful.map(\.account) == ["iCloud", "Outlook"])
        #expect(p.useful[0].rows.map(\.title) == ["INBOX", "Archive", "Mail Digest"])
        #expect(p.useful[1].rows.map(\.title) == ["Inbox", "Archive"])
        #expect(p.noiseCount == 4)
        #expect(Set(p.noise.flatMap(\.rows).map(\.title)) == ["Sent Messages", "Empty Folder", "Notes", "Untitled list"])
    }

    @Test func anEmptyInboxIsStillUseful() {
        let p = MailboxTree.partition([box("iCloud", "INBOX", .inbox, count: 0)])
        #expect(p.useful.flatMap(\.rows).count == 1 && p.noiseCount == 0)
    }

    @Test func inboxIsLabelledInboxAndTheDigestFolderIsAnnotated() {
        let rows = MailboxTree.partition(boxes).useful.flatMap(\.rows)
        #expect(rows.map(MailboxTree.displayTitle).prefix(3) == ["Inbox", "Archive", "Mail Digest"])
        #expect(MailboxTree.annotation(rows[2]) == "Mail Cleanup folder")
        #expect(MailboxTree.annotation(rows[1]) == nil)
    }

    @Test func filterMatchesMailboxOrAccountName() {
        let byName = MailboxTree.partition(boxes, filter: "arch")
        #expect(byName.useful.flatMap(\.rows).map(\.title) == ["Archive", "Archive"])
        let byAccount = MailboxTree.partition(boxes, filter: "outlook")
        #expect(byAccount.useful.map(\.account) == ["Outlook"])
        #expect(MailboxTree.partition(boxes, filter: "  ").useful.count == 2)
    }
}

@Suite struct BacklogNamingTests {
    @Test func defaultNameIsTheDateRange() {
        func d(_ a: Date, _ b: Date, _ c: Calendar) -> String { BacklogJobNaming.defaultName(from: a, to: b, calendar: c) }
        #expect(d(at(2026, 10, 21, 0), at(2026, 10, 21, 23), cal) == "21 Oct 2026")
        #expect(d(at(2026, 10, 1, 0), at(2026, 10, 31, 23, 59), cal) == "1\u{2013}31 Oct 2026")
        #expect(d(at(2026, 10, 21), at(2026, 11, 4), cal) == "21 Oct \u{2013} 4 Nov 2026")
        #expect(d(at(2025, 12, 21), at(2026, 1, 4), cal) == "21 Dec 2025 \u{2013} 4 Jan 2026")
    }

    @Test func untouchedOrBlankNamesStoreNil() {
        #expect(BacklogJobNaming.resolvedName("  \n ", defaultName: "1\u{2013}31 Oct 2026") == nil)
        #expect(BacklogJobNaming.resolvedName("1\u{2013}31 Oct 2026", defaultName: "1\u{2013}31 Oct 2026") == nil)
        #expect(BacklogJobNaming.resolvedName("  Tax time ", defaultName: "1\u{2013}31 Oct 2026") == "Tax time")
    }

    @Test func rangeText() {
        #expect(BacklogJobNaming.rangeText(from: at(2026, 10, 1), to: at(2026, 10, 31), calendar: cal) == "1 to 31 Oct 2026")
        #expect(BacklogJobNaming.rangeText(from: at(2026, 11, 9, 1), to: at(2026, 11, 9, 20), calendar: cal) == "9 Nov 2026")
        #expect(BacklogJobNaming.rangeText(from: at(2026, 9, 20), to: at(2026, 10, 14), calendar: cal) == "20 Sep to 14 Oct 2026")
        #expect(BacklogJobNaming.rangeText(from: at(2025, 12, 20), to: at(2026, 1, 14), calendar: cal) == "20 Dec 2025 to 14 Jan 2026")
    }
}

@Suite struct BacklogRangeTests {
    private let now = at(2026, 11, 9, 20, 15)

    @Test func presetsResolveToCalendarDays() {
        let l7 = BacklogDateRange.resolve(.last7, now: now, calendar: cal, lastJobEnd: nil, customFrom: now, customTo: now)
        #expect(l7.from == at(2026, 11, 3, 0) && l7.to == now)
        let l30 = BacklogDateRange.resolve(.last30, now: now, calendar: cal, lastJobEnd: nil, customFrom: now, customTo: now)
        #expect(l30.from == at(2026, 10, 11, 0))
    }

    @Test func sinceLastJobStartsOnTheDayThatJobEndedAndFallsBackToThirtyDays() {
        let since = BacklogDateRange.resolve(.sinceLastJob, now: now, calendar: cal, lastJobEnd: at(2026, 10, 20, 15),
                                             customFrom: now, customTo: now)
        #expect(since.from == at(2026, 10, 20, 0))
        let none = BacklogDateRange.resolve(.sinceLastJob, now: now, calendar: cal, lastJobEnd: nil, customFrom: now, customTo: now)
        #expect(none.from == at(2026, 10, 11, 0))
    }

    @Test func customTakesEitherOrderAndNeverReachesPastNow() {
        let r = BacklogDateRange.resolve(.custom, now: now, calendar: cal, lastJobEnd: nil,
                                         customFrom: at(2026, 11, 20), customTo: at(2026, 10, 1))
        #expect(r.from == at(2026, 10, 1, 0) && r.to == now)
        let past = BacklogDateRange.resolve(.custom, now: now, calendar: cal, lastJobEnd: nil,
                                            customFrom: at(2026, 10, 1), customTo: at(2026, 10, 31))
        #expect(past.to == at(2026, 11, 1, 0).addingTimeInterval(-1))
    }
}

@Suite struct BacklogEstimateTests {
    @Test func noHistoryUsesSixMinutesPerEmail() {
        #expect(BacklogEstimate.secondsPerEmail(samples: []) == 360)
        #expect(BacklogEstimate.secondsPerEmail(jobs: [], items: [:]) == 360)
    }

    @Test func medianOfOddAndEvenSamples() {
        #expect(BacklogEstimate.secondsPerEmail(samples: [30, 10, 20]) == 20)
        #expect(BacklogEstimate.secondsPerEmail(samples: [10, 20, 30, 50]) == 25)
    }

    @Test func aJobSampleIsTheMeanOfItsLocalDoneEmails() {
        let id = UUID()
        let items = [item(id, seconds: 10), item(id, seconds: 30), item(id, seconds: 500, provider: .cloud),
                     item(id, seconds: 99, state: .failed), item(id, seconds: nil), item(id, seconds: 20, provider: nil)]
        #expect(BacklogEstimate.secondsPerEmail(of: items) == 20)
        #expect(BacklogEstimate.secondsPerEmail(of: [item(id, seconds: 5, provider: .cloud)]) == nil)
        #expect(BacklogEstimate.secondsPerEmail(of: []) == nil)
    }

    @Test func onlyTheLastFiveCompletedJobsCountAndEmptyOnesAreNotSamples() {
        // Seven finished jobs, oldest first: speeds 1000, 1000 (too old), then 10, 20, [empty], 30, 40, 50.
        let speeds: [Double?] = [1000, 1000, 10, 20, nil, 30, 40, 50]
        var jobs: [Job] = [], items: [UUID: [JobItem]] = [:]
        for (i, s) in speeds.enumerated() {
            let j = job(ended: at(2026, 10, 1 + i))
            jobs.append(j)
            items[j.id] = s.map { [item(j.id, seconds: $0)] } ?? []
        }
        jobs.append(job(.running, ended: at(2026, 10, 30)))      // not completed
        jobs.append(job(.stopped, ended: at(2026, 10, 31)))      // not completed
        // Newest five with data: 50, 40, 30, 20, 10 (the empty job is skipped, not counted) -> median 30.
        #expect(BacklogEstimate.secondsPerEmail(jobs: jobs, items: items) == 30)
    }

    @Test func friendlyDurations() {
        #expect(BacklogEstimate.friendlyDuration(30) == "Under a minute")
        #expect(BacklogEstimate.friendlyDuration(5 * 60) == "About 5 minutes")
        #expect(BacklogEstimate.friendlyDuration(41 * 60) == "About 40 minutes")
        #expect(BacklogEstimate.friendlyDuration(58 * 60) == "About an hour")
        #expect(BacklogEstimate.friendlyDuration(5.6 * 3600) == "About 6 hours")
        #expect(BacklogEstimate.friendlyDuration(36 * 3600) == "About 36 hours")
        #expect(BacklogEstimate.friendlyDuration(374 * 360) == "About 37 hours")
        #expect(BacklogEstimate.friendlyDuration(100 * 3600) == "About 4 days")
    }

    @Test func nightsComeFromTheConfiguredWindow() {
        let nineHours = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        let sevenHours = QuietHours(startMinute: 23 * 60, endMinute: 6 * 60)
        #expect(BacklogEstimate.nights(seconds: 36 * 3600, window: nineHours) == 4)
        #expect(BacklogEstimate.nights(seconds: 36 * 3600, window: sevenHours) == 6)
        #expect(BacklogEstimate.nights(seconds: 60, window: sevenHours) == 1)
        #expect(BacklogEstimate.nights(seconds: 0, window: sevenHours) == 1)
        #expect(BacklogEstimate.nights(seconds: 50 * 3600, window: QuietHours(startMinute: 0, endMinute: 0)) == 3)
    }

    @Test func overnightDescriptionUsesTheWindowAndNights() {
        let w = QuietHours(startMinute: 23 * 60, endMinute: 6 * 60)
        #expect(BacklogEstimate.overnightDescription(window: w, estimatedSeconds: 34 * 3600)
                == "Runs 11 pm to 6 am, about 5 nights. Your Mac stays quick during the day.")
        #expect(BacklogEstimate.overnightDescription(window: w, estimatedSeconds: 3600)
                == "Runs 11 pm to 6 am, done in one night. Your Mac stays quick during the day.")
        let half = QuietHours(startMinute: 22 * 60 + 30, endMinute: 6 * 60 + 5)
        #expect(BacklogEstimate.overnightDescription(window: half, estimatedSeconds: 3600).hasPrefix("Runs 10:30 pm to 6:05 am"))
    }
}

@Suite struct BacklogSetupTextTests {
    @Test func footersAndRows() {
        #expect(BacklogSetupText.mailboxFooter(mailboxCount: 2, emailCount: 3_630) == "2 mailboxes · 3,630 emails")
        #expect(BacklogSetupText.mailboxFooter(mailboxCount: 1, emailCount: 1) == "1 mailbox · 1 email")
        #expect(BacklogSetupText.mailboxFooter(mailboxCount: 0, emailCount: 0) == "No mailboxes selected")
        #expect(BacklogSetupText.readFooter(toProcess: 374) == "374 emails to read · 8 batches")
        #expect(BacklogSetupText.readFooter(toProcess: 50) == "50 emails to read · 1 batch")
        #expect(BacklogSetupText.readFooter(toProcess: 51, deferredByLimit: 9) == "51 emails to read · 2 batches · 9 held back")
        #expect(BacklogSetupText.readFooter(toProcess: 0) == "Nothing to read in this range")
        #expect(BacklogSetupText.emailsRow(toProcess: 374, alreadyProcessed: 38) == "374 to read · 38 already processed")
        #expect(BacklogSetupText.emailsRow(toProcess: 10, alreadyProcessed: 0, deferredByLimit: 5).hasSuffix("5 held back by the run limit"))
        #expect(BacklogSetupText.estimateRow(seconds: 36 * 3600, toProcess: 374) == "About 36 hours · 8 batches of 50")
        #expect(BacklogSetupText.mailboxList([MailboxRef(account: "iCloud", name: "INBOX"), MailboxRef(account: "Outlook", name: "Inbox")])
                == "iCloud Inbox, Outlook Inbox")
    }
}

@Suite struct VolumeHistogramTests {
    private let now = at(2026, 11, 9, 20)

    @Test func windowRunsFromTwoWeeksBeforeTheRangeToToday() {
        let range = BacklogDateRange(from: at(2026, 10, 1, 0), to: at(2026, 10, 31, 23, 59))
        let w = VolumeHistogram.window(range: range, now: now, calendar: cal)
        #expect(w.from == at(2026, 9, 17, 0) && w.to == at(2026, 11, 10, 0))
    }

    @Test func binsAreZeroFilledAndFlagTheRange() {
        let range = BacklogDateRange(from: at(2026, 11, 7, 0), to: now)
        let counts = [DayCount(day: DigestDay(year: 2026, month: 11, day: 8), count: 5),
                      DayCount(day: DigestDay(year: 2026, month: 10, day: 30), count: 2)]
        let bins = VolumeHistogram.bins(counts, range: range, now: now, calendar: cal)
        #expect(bins.count == 14 + 3)
        #expect(bins.first?.date == at(2026, 10, 24, 0) && bins.last?.date == at(2026, 11, 9, 0))
        #expect(bins.filter(\.isInRange).map(\.count) == [0, 5, 0])
        #expect(VolumeHistogram.total(bins) == 5)
        #expect(bins.first { $0.date == at(2026, 10, 30, 0) }?.count == 2)
    }

    @Test func accessibilitySummaryNamesTheTotalAndBusiestDay() {
        let range = BacklogDateRange(from: at(2026, 11, 8, 0), to: now)
        let bins = VolumeHistogram.bins([DayCount(day: DigestDay(year: 2026, month: 11, day: 9), count: 7)],
                                        range: range, now: now, calendar: cal)
        let text = VolumeHistogram.accessibilitySummary(bins, calendar: cal)
        #expect(text.contains("7 emails in the chosen range") && text.contains("busiest day 9 November with 7"))
        #expect(VolumeHistogram.accessibilitySummary([], calendar: cal) == "No volume data")
    }
}

@Suite struct ConfirmedPreviewTests {
    private func header(_ id: String, sender: String, at t: Double) -> MessageHeader {
        MessageHeader(id: id, account: "iCloud", mailbox: "Inbox", sender: sender, subject: id,
                      receivedAt: Date(timeIntervalSince1970: t), sourceReference: nil)
    }

    private func preview(limit: Int? = nil) -> (JobPreviewBuilder, JobPreview) {
        let ref = MailboxRef(account: "iCloud", name: "Inbox")
        let builder = JobPreviewBuilder(filter: MailFilter(ignoredSenders: ["spam@x.com"]))
        let plan = JobPlan(kind: limit == nil ? .backlog : .daily, mailboxes: [ref], from: .distantPast, to: .distantFuture,
                           excludedMessageIDs: [])
        let headers = [header("a", sender: "A <a@x.com>", at: 3), header("b", sender: "Spam <SPAM@x.com>", at: 2),
                       header("c", sender: "c@x.com", at: 1)]
        return (builder, builder.build(plan: plan, headers: [ref: headers], isProcessedOrQueued: ["c"],
                                       averageSecondsPerEmail: nil, limit: limit))
    }

    @Test func skippingIgnoredSendersDropsThemFromTheQueuedSet() {
        let (builder, p) = preview()
        #expect(p.toProcess.map(\.id) == ["a", "b"] && p.alreadyProcessed == 1)
        let on = builder.confirmed(p, excluded: [], skipIgnoredSenders: true, secondsPerEmail: 360)
        #expect(on.toProcess.map(\.id) == ["a"] && on.plan.confirmedMessageIDs == ["a"])
        #expect(on.plan.excludedMessageIDs == ["b"] && on.estimatedSeconds == 360)
        let off = builder.confirmed(p, excluded: [], skipIgnoredSenders: false, secondsPerEmail: 100)
        #expect(off.toProcess.map(\.id) == ["a", "b"] && off.estimatedSeconds == 200)
    }

    @Test func dailyLimitReportsTheDeferredCount() {
        let (_, p) = preview(limit: 1)
        #expect(p.toProcess.count == 1 && p.deferredByLimit == 1)
        #expect(preview().1.deferredByLimit == 0)
    }
}

@Suite struct DigestlessBacklogTests {
    private func backlog(_ state: JobState, queued: Int = 5, done: Int = 0, at: Date, overnight: Bool = false,
                         reason: PauseReason? = nil) -> Job {
        Job(id: UUID(), kind: .backlog, mailboxes: [MailboxRef(account: "iCloud", name: "Inbox")], scopeFrom: at, scopeTo: at,
            state: state, createdAt: at, totals: JobTotals(queued: queued, done: done, failed: 0, skipped: 0),
            autoPaused: reason != nil, pauseReason: reason, name: "October Backlog", overnightOnly: overnight)
    }

    @Test func aJobWithoutADigestIsListedNewestFirst() {
        let withDigest = DigestSummary(id: UUID(), createdAt: at(2026, 11, 1), kind: .backlog, emailCount: 3, pendingCount: 2, failedCount: 0)
        let scheduled = backlog(.paused, at: at(2026, 11, 8), overnight: true, reason: .quietHours)
        let archive = DigestArchive(summaries: [withDigest], backlogJobs: [scheduled], now: at(2026, 11, 9), calendar: cal)
        #expect(archive.backlogs.map(\.id) == [scheduled.id, withDigest.id])
        #expect(archive.backlogs[0].hasDigest == false && archive.backlogs[1].hasDigest)
        #expect(archive.hasBacklog(scheduled.id))
        // Its (zero) badge adds nothing to the Review Queue count.
        #expect(archive.reviewQueueCount == 2)
    }

    @Test func aJobWithADigestIsNotListedTwiceAndAnEmptyFailureStaysOut() {
        let digestJob = backlog(.running, at: at(2026, 11, 8))
        let summary = DigestSummary(id: digestJob.id, createdAt: digestJob.createdAt, kind: .backlog, emailCount: 1, pendingCount: 1, failedCount: 0)
        let failedEmpty = backlog(.failed, queued: 0, at: at(2026, 11, 7))
        let failedWithWork = backlog(.failed, queued: 3, at: at(2026, 11, 6))
        let daily = Job(id: UUID(), kind: .daily, mailboxes: [], scopeFrom: .now, scopeTo: .now, state: .paused, createdAt: .now,
                        totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        let archive = DigestArchive(summaries: [summary], backlogJobs: [digestJob, failedEmpty, failedWithWork, daily],
                                    now: at(2026, 11, 9), calendar: cal)
        #expect(archive.backlogs.map(\.id) == [digestJob.id, failedWithWork.id])
    }

    @Test func scheduledSubtitleOnlyForAnOvernightJobWaitingForItsWindow() {
        let waiting = backlog(.paused, at: .now, overnight: true, reason: .quietHours)
        #expect(BacklogRowText.isScheduled(waiting))
        #expect(!BacklogRowText.isScheduled(backlog(.paused, at: .now, overnight: true, reason: .battery)))
        #expect(!BacklogRowText.isScheduled(backlog(.paused, at: .now, overnight: true, reason: nil)))
        #expect(!BacklogRowText.isScheduled(backlog(.stopped, at: .now, overnight: true, reason: .quietHours)))
        #expect(!BacklogRowText.isScheduled(backlog(.paused, at: .now, overnight: false, reason: .quietHours)))
    }

    @Test func olderStoredJobsDecodeWithoutTheOvernightFlag() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(backlog(.paused, at: .now, overnight: true))) as? [String: Any])
        #expect(object["overnightOnly"] as? Bool == true)
        object["overnightOnly"] = nil
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.overnightOnly == false && decoded.name == "October Backlog")
    }
}

@Suite struct OvernightPolicyTests {
    private let window = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    private let policy: ResourcePolicy

    init() {
        policy = ResourcePolicy(pauseBacklogOnBattery: false, quietHours: nil, timeZone: brisbane, overnightWindow: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60))
    }

    @Test func overnightJobsWaitForTheWindowEvenWhenQuietHoursIsOff() {
        let day = at(2026, 11, 9, 14), night = at(2026, 11, 9, 23)
        #expect(policy.blockingReason(for: .backlog, conditions: ResourceConditions(), now: day) == nil)
        #expect(policy.overnightBlockingReason(conditions: ResourceConditions(), now: day) == .quietHours)
        #expect(policy.overnightBlockingReason(conditions: ResourceConditions(), now: night) == nil)
    }

    @Test func overnightJobsNeverRunOnBatteryEvenIfPauseOnBatteryIsOff() {
        let night = at(2026, 11, 9, 23)
        let onBattery = ResourceConditions(onBattery: true)
        #expect(policy.blockingReason(for: .backlog, conditions: onBattery, now: night) == nil)
        #expect(policy.overnightBlockingReason(conditions: onBattery, now: night) == .battery)
    }

    @Test func settingsPassTheConfiguredWindowEvenWhileTheToggleIsOff() {
        var settings = DigestSettings()
        settings.quietHoursEnabled = false
        settings.quietHoursStartMinute = 23 * 60
        settings.quietHoursEndMinute = 6 * 60
        let p = settings.resourcePolicy()
        #expect(p.quietHours == nil)
        #expect(p.overnightWindow == QuietHours(startMinute: 23 * 60, endMinute: 6 * 60))
    }
}
