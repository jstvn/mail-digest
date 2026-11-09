import Foundation
import Testing
@testable import MailDigestCore

@Suite struct MenuPanelPresentationTests {
    private let au = Locale(identifier: "en_AU")
    private let us = Locale(identifier: "en_US")
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return c
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Titles

    @Test func dailyTitleIsFixed() {
        #expect(MenuPanelPresentation.jobTitle(kind: .daily, from: date(11, 8), to: date(11, 9), calendar: cal, locale: au)
            == "Daily Digest")
    }

    @Test func backlogTitleForOneDayAndSeveralDays() {
        // `to` is the exclusive start of the next day, so the last included day is 12 Nov.
        #expect(MenuPanelPresentation.jobTitle(kind: .backlog, from: date(11, 12), to: date(11, 13), calendar: cal, locale: au)
            == "Backlog · 12 Nov")
        #expect(MenuPanelPresentation.jobTitle(kind: .backlog, from: date(10, 10), to: date(11, 13), calendar: cal, locale: au)
            == "Backlog · 10 Oct \u{2013} 12 Nov")
    }

    @Test func backlogTitleUsesLastIncludedDayWhenToIsMidDay() {
        // The preview's `to` can be "now", partway through the last day.
        #expect(MenuPanelPresentation.jobTitle(kind: .backlog, from: date(10, 10), to: date(11, 12, 9, 30), calendar: cal,
                                               locale: au) == "Backlog · 10 Oct \u{2013} 12 Nov")
    }

    @Test func backlogTitleForEverythingScope() {
        #expect(MenuPanelPresentation.jobTitle(kind: .backlog, from: Date(timeIntervalSince1970: 0), to: date(11, 13),
                                               calendar: cal, locale: au) == "Backlog · Up to 12 Nov")
    }

    // MARK: Status line

    @Test func statusLineKeepsFailedCount() {
        var p = PreviewFixtures.dailyRunningProgress
        #expect(MenuPanelPresentation.statusLine(p, locale: us) == "Reading 12 of 23 emails · about 4 min left")
        p.failed = 2
        #expect(MenuPanelPresentation.statusLine(p, locale: us) == "Reading 12 of 23 emails · 2 failed · about 4 min left")
        p.state = .stopping
        #expect(MenuPanelPresentation.statusLine(p, locale: us) == "Stopping…")
        p.state = .listing
        #expect(MenuPanelPresentation.statusLine(p, locale: us) == "Looking for new mail…")
        p.state = .paused
        #expect(MenuPanelPresentation.statusLine(p, pauseReason: "battery power", locale: us).hasSuffix("(battery power)"))
    }

    // MARK: Suggestions row

    private func summary(created: Date, emails: Int = 8, pending: Int = 2, failed: Int = 1) -> DigestSummary {
        DigestSummary(id: UUID(), createdAt: created, kind: .daily, emailCount: emails, pendingCount: pending,
                      failedCount: failed)
    }

    @Test func rowWordingForEveryTimePhrase() {
        let now = date(11, 9, 11, 42)
        func row(_ d: Date, emails: Int = 8, pending: Int = 2, failed: Int = 1) -> MenuSuggestionsRow {
            MenuPanelPresentation.suggestionsRow(summary(created: d, emails: emails, pending: pending, failed: failed),
                                                 now: now, calendar: cal, locale: us)
        }
        let morning = row(date(11, 9, 7, 28))
        #expect(morning.title == "3 suggestions from this morning")
        #expect(morning.subtitle == "8 emails · finished 7:28 am")
        #expect(row(date(11, 9, 13, 5)).title == "3 suggestions from today")
        #expect(row(date(11, 8, 22, 0)).title == "3 suggestions from yesterday")
        #expect(MenuPanelPresentation.suggestionsRow(summary(created: date(11, 7, 18, 5)), now: now, calendar: cal,
                                                     locale: au).title == "3 suggestions from 7 Nov")
        #expect(row(date(11, 9, 7, 28), pending: 0, failed: 0).title == "No suggestions from this morning")
    }

    @Test func rowUsesSingularForms() {
        let row = MenuPanelPresentation.suggestionsRow(summary(created: date(11, 9, 19, 5), emails: 1, pending: 1, failed: 0),
                                                       now: date(11, 9, 20), calendar: cal, locale: us)
        #expect(row.title == "1 suggestion from today")
        #expect(row.subtitle == "1 email · finished 7:05 pm")
    }

    // MARK: Attention

    @Test func attentionSubtitleVariants() {
        let started = date(11, 9, 6, 30)
        #expect(MenuPanelPresentation.attentionSubtitle(startedAt: started, done: 0, total: 23, calendar: cal, locale: us)
            == "Started 6:30 am · stopped before reading any emails")
        #expect(MenuPanelPresentation.attentionSubtitle(startedAt: started, done: 12, total: 23, calendar: cal, locale: us)
            == "Started 6:30 am · stopped after 12 of 23 emails")
        #expect(MenuPanelPresentation.attentionSubtitle(startedAt: nil, done: 0, total: 0, calendar: cal, locale: us)
            == "Stopped before reading any emails")
        #expect(MenuPanelPresentation.attentionSubtitle(startedAt: nil, done: 3, total: 9, calendar: cal, locale: us)
            == "Stopped after 3 of 9 emails")
    }

    @Test func attentionCardByKind() {
        let down = MenuPanelPresentation.attentionCard(kind: .ollamaUnreachable, jobTitle: "Daily Digest",
                                                       message: "x", model: "qwen3:4b")
        #expect(down.title == "Ollama Isn\u{2019}t Running" && down.offersStartOllama)
        let missing = MenuPanelPresentation.attentionCard(kind: .modelMissing, jobTitle: "Daily Digest",
                                                          message: "x", model: "qwen3:4b")
        #expect(missing.title == "Model Isn\u{2019}t Installed" && !missing.offersStartOllama)
        #expect(missing.message == "Run `ollama pull qwen3:4b` in Terminal, then try again.")
        for kind in [JobFailureKind.other, nil] {
            let other = MenuPanelPresentation.attentionCard(kind: kind, jobTitle: "Daily Digest", message: "Mail failed.",
                                                            model: "qwen3:4b")
            #expect(other.title == "Daily Digest Couldn\u{2019}t Finish" && other.message == "Mail failed.")
            #expect(!other.offersStartOllama)
        }
        #expect(MenuPanelPresentation.attentionCard(kind: nil, jobTitle: nil, message: "m", model: "q").title
            == "Needs Attention")
    }

    // MARK: Failure kind

    @Test func failureKindMapsFromLLMErrors() {
        #expect(JobFailureKind(LLMError.unreachable("down")) == .ollamaUnreachable)
        #expect(JobFailureKind(LLMError.modelMissing("qwen3:4b")) == .modelMissing)
        #expect(JobFailureKind(LLMError.timedOut) == .other)
        #expect(JobFailureKind(LLMError.http(status: 500)) == .other)
        #expect(JobFailureKind(CancellationError()) == .other)
    }

    @Test func jobWithoutFailureKindDecodesFromLegacyJSON() throws {
        let job = Job(id: UUID(), kind: .daily, mailboxes: [], scopeFrom: Date(timeIntervalSince1970: 1),
                      scopeTo: Date(timeIntervalSince1970: 2), state: .failed, createdAt: Date(timeIntervalSince1970: 1),
                      totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false,
                      failureKind: .modelMissing)
        let data = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(Job.self, from: data).failureKind == .modelMissing)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["failureKind"] = nil
        let old = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(Job.self, from: old).failureKind == nil)
    }

    @Test func archiveLatestDailyIgnoresBacklog() {
        let daily = summary(created: date(11, 8, 7, 0))
        let backlog = DigestSummary(id: UUID(), createdAt: date(11, 9, 8, 0), kind: .backlog, emailCount: 3,
                                    pendingCount: 1, failedCount: 0)
        let archive = DigestArchive(summaries: [backlog, daily], now: date(11, 9, 9), calendar: cal)
        #expect(archive.latestDaily?.id == daily.id)
        #expect(DigestArchive(summaries: [backlog], now: date(11, 9, 9), calendar: cal).latestDaily == nil)
    }
}

@Suite struct HaltedLineTests {
    @Test func pausedAndStoppedReadTheSameWay() {
        let en = Locale(identifier: "en_AU")
        #expect(MenuPanelPresentation.haltedLine(jobTitle: "Daily Digest", state: .stopped, done: 12, total: 40, locale: en)
                == "Daily Digest · Stopped at 12 of 40")
        #expect(MenuPanelPresentation.haltedLine(jobTitle: "Oct 2026", state: .paused, done: 1_200, total: 2_960, locale: en)
                == "Oct 2026 · Paused at 1,200 of 2,960")
        #expect(MenuPanelPresentation.haltedLine(jobTitle: "Daily Digest", state: .paused, done: 2, total: 9,
                                                 reason: "battery power", locale: en)
                == "Daily Digest · Paused at 2 of 9 (battery power)")
        #expect(MenuPanelPresentation.haltedLine(jobTitle: "x", state: .running, done: 1, total: 2) == nil)
        #expect(MenuPanelPresentation.haltedLine(jobTitle: "x", state: .failed, done: 1, total: 2) == nil)
    }

    @Test func doneCountsDoneFailedAndSkippedAndTotalAddsQueued() {
        let job = Job(id: UUID(), kind: .backlog, mailboxes: [], scopeFrom: .now, scopeTo: .now, state: .stopped,
                      createdAt: .now, totals: JobTotals(queued: 5, done: 3, failed: 1, skipped: 2), autoPaused: false)
        #expect(MenuPanelPresentation.haltedLine(job, jobTitle: "Backlog", locale: Locale(identifier: "en_AU"))
                == "Backlog · Stopped at 6 of 11")
    }
}
