import Foundation
import Testing
@testable import MailDigestCore

private let us = Locale(identifier: "en_US")
private var brisbane: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = PreviewFixtures.timeZone
    return c
}

private func sug(_ n: Int, confidence: Double, status: SuggestionStatus = .pending) -> Suggestion {
    Suggestion(id: UUID(), emailID: "e\(n)", title: "Task \(n)", due: nil, dueHasTime: false, priority: .medium,
               evidence: "x", confidence: confidence, preselected: confidence >= 0.75, flags: [], status: status,
               reminderID: nil)
}

@Suite struct SuggestionPageTests {
    @Test func dailyShowsTop25ByConfidenceInOrderAndCountsRest() {
        let all = (0..<30).map { sug($0, confidence: Double($0) / 100 + 0.4) } // confidence rises with index
        let page = ReviewPresentation.page(all, limit: 25, showAll: false)
        #expect(page.visible.count == 25)
        #expect(page.hiddenCount == 5)
        #expect(page.visible.map(\.id) == all.suffix(25).map(\.id)) // lowest five hidden, order kept
        let everything = ReviewPresentation.page(all, limit: 25, showAll: true)
        #expect(everything.visible.count == 30 && everything.hiddenCount == 0)
        // Backlog has no cap.
        #expect(ReviewPresentation.page(all, limit: nil, showAll: false).visible.count == 30)
        #expect(ReviewPresentation.page(Array(all.prefix(25)), limit: 25, showAll: false).hiddenCount == 0)
    }

    @Test func actionableAndPendingCount() {
        let d = Digest(id: UUID(), createdAt: PreviewFixtures.now, headline: "", emailCount: 4,
                       suggestions: [sug(1, confidence: 0.9), sug(2, confidence: 0.9, status: .failed),
                                     sug(3, confidence: 0.9, status: .approved), sug(4, confidence: 0.9, status: .dismissed)],
                       info: [], skipped: [])
        #expect(ReviewPresentation.actionable(d.suggestions).count == 2)
        #expect(ReviewPresentation.pendingCount(d) == 1)
        #expect(ReviewPresentation.pendingCount(nil) == 0)
    }

    @Test func refreshKeepsChoicesAndSelectsNewPreselected() {
        let a = sug(1, confidence: 0.9), b = sug(2, confidence: 0.9)
        var old = ReviewState(digest: Digest(id: UUID(), createdAt: PreviewFixtures.now, headline: "", emailCount: 2,
                                             suggestions: [a, b], info: [], skipped: []))
        old = ReviewActions.toggle(b.id, in: old) // user unticks b
        let c = sug(3, confidence: 0.9), d = sug(4, confidence: 0.5)
        var bDone = b; bDone.status = .dismissed
        var digest = old.digest
        digest.suggestions = [a, bDone, c, d]
        let next = old.refreshed(with: digest)
        #expect(next.selection == [a.id, c.id])
    }
}

@Suite struct InfoGroupTests {
    @Test func groupsSortByHighestImportanceAndCollapseNewsletters() {
        let groups = ReviewPresentation.infoGroups(PreviewFixtures.digest.info)
        #expect(groups.map(\.category) == [.uni, .finance, .deliveries, .newsletters])
        #expect(groups.map(\.collapsedByDefault) == [false, false, false, true])
        #expect(groups[0].items.map(\.importance) == [4, 3, 2])
        #expect(groups[3].items.count == 9)
    }
}

@Suite struct ProgressFormattingTests {
    @Test func countsLine() {
        #expect(ReviewPresentation.counts(PreviewFixtures.runningProgress, locale: us)
            == "412 of 1,081 · 6 failed · about 3 h 50 min left")
        var p = PreviewFixtures.runningProgress
        p.failed = 0; p.eta = 4 * 60
        #expect(ReviewPresentation.counts(p, locale: us) == "412 of 1,081 · about 4 min left")
        p.eta = 30
        #expect(ReviewPresentation.counts(p, locale: us) == "412 of 1,081")
        p.eta = 7200
        #expect(ReviewPresentation.etaText(p.eta!) == "about 2 h left")
    }

    @Test func readingSummaryAndNowLine() {
        #expect(ReviewPresentation.readingSummary(PreviewFixtures.dailyRunningProgress, locale: us)
            == "Reading 12 of 23 emails · about 4 min left")
        #expect(ReviewPresentation.nowLine(PreviewFixtures.runningProgress)
            == "Summarising · Ray White · Rent due Friday · Outlook Inbox")
        #expect(ReviewPresentation.nowLine(PreviewFixtures.pausedProgress) == nil)
    }

    @Test func pausedText() {
        #expect(ReviewPresentation.pausedText(PreviewFixtures.pausedProgress, locale: us)
            == "Paused after #412 · Ray White · Rent due Friday. Next: #413 · QUT Canvas · Assessment 2 reminder")
        #expect(ReviewPresentation.pausedText(PreviewFixtures.pausedProgress, reason: "battery power", locale: us)
            .hasSuffix("Assessment 2 reminder (battery power)"))
        var p = PreviewFixtures.pausedProgress
        p.lastFinished = nil; p.done = 412; p.total = 2_960
        #expect(ReviewPresentation.pausedText(p, locale: us) == "Paused · 412 of 2,960")
    }

    @Test func headerAndNames() {
        let d = PreviewFixtures.digest
        #expect(ReviewPresentation.headerTitle(d, now: PreviewFixtures.now, calendar: brisbane, locale: us)
            == "Today · Wed 4 Nov · 23 emails")
        let tomorrow = PreviewFixtures.now.addingTimeInterval(86_400)
        #expect(ReviewPresentation.headerTitle(d, now: tomorrow, calendar: brisbane, locale: us)
            .hasPrefix("Last digest · Wed 4 Nov"))
        #expect(ReviewPresentation.senderName("\"Ray White\" <a@b.com>") == "Ray White")
        #expect(ReviewPresentation.senderName("Bob@Example.com") == "bob@example.com")
        #expect(ReviewPresentation.senderName("<x@y.com>") == "x@y.com")
        #expect(ReviewPresentation.flagDescription("money-new-sender") == "Payment request from a new sender")
        #expect(ReviewPresentation.jobName(.daily) == "Daily digest")
    }

    @Test func fixturesCoverTheSpecCases() {
        let d = PreviewFixtures.digest
        let scam = d.suggestions.first { $0.id == PreviewFixtures.ID.scam }
        #expect(scam?.preselected == false && scam?.flags.isEmpty == false)
        #expect(d.suggestions.contains { $0.due == nil })
        #expect(!d.skipped.isEmpty)
        #expect(ReviewState(digest: d).selection.count == 2)
    }
}
