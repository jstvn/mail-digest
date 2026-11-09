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

@Suite struct CanvasHeaderTextTests {
    @Test func countsSubtitleHandlesPluralsAndZero() {
        #expect(ReviewPresentation.countsSubtitle(emailCount: 8, suggestionCount: 2) == "8 emails processed · 2 suggestions")
        #expect(ReviewPresentation.countsSubtitle(emailCount: 1, suggestionCount: 1) == "1 email processed · 1 suggestion")
        #expect(ReviewPresentation.countsSubtitle(emailCount: 8, suggestionCount: 0) == "8 emails processed")
    }

    @Test func countOnlyHeadlineMatchesThePipelineFallback() {
        for (e, s) in [(0, 0), (1, 1), (1, 2), (23, 0), (1081, 7)] {
            #expect(ReviewPresentation.isCountOnlyHeadline(DigestPipeline.fallbackHeadline(emails: e, suggestions: s)))
        }
        #expect(ReviewPresentation.isCountOnlyHeadline("  3 emails, 1 suggestion.\n"))
    }

    @Test func realHeadlinesAreNotCountOnly() {
        #expect(!ReviewPresentation.isCountOnlyHeadline("Rent is due Friday and 3 emails need a reply."))
        #expect(!ReviewPresentation.isCountOnlyHeadline("3 emails, 1 suggestion. Rent is due."))
        #expect(!ReviewPresentation.isCountOnlyHeadline("1 emails, 2 suggestion."))
        #expect(!ReviewPresentation.isCountOnlyHeadline(""))
    }
}

@Suite struct DisplayFactsTests {
    private func facts(_ input: [String], sender: String? = "Ray White <ray@whitere.example>",
                       users: [String] = ["Justin Wang"]) -> [String] {
        ReviewPresentation.displayFacts(input, sender: sender, userNames: users)
    }

    @Test func dropsSenderAndAddress() {
        #expect(facts(["Ray White", "ray@whitere.example", "• RAY WHITE.", "Ray White Realty"]) == ["Ray White Realty"])
    }

    @Test func dropsUserFullNameAndSingleTokens() {
        #expect(facts(["Justin Wang", "justin", "Wang,", "Justin Wang's lease"]) == ["Justin Wang's lease"])
    }

    @Test func dropsBareISODatesOnly() {
        #expect(facts(["2026-12-01", "2026-12-01T17:00", "2026-12-01T17:00:00+10:00", "- 2026-12-01.",
                       "Due 2026-12-01", "Total $17.45", "Brisbane"]) == ["Due 2026-12-01", "Total $17.45", "Brisbane"])
    }

    @Test func dropsSenderVariantsWithCorporateSuffixes() {
        #expect(facts(["Letterboxd HQ", "Letterboxd Pro", "Letterboxd Team"], sender: "Letterboxd <hi@letterboxd.example>", users: [])
                == ["Letterboxd Pro"])
        #expect(facts(["Letterboxd", "Letterboxd Pro"], sender: "Letterboxd HQ <hi@letterboxd.example>", users: [])
                == ["Letterboxd Pro"])
        #expect(facts(["Acme Support", "Acme Rewards"], sender: "Acme Inc <a@acme.example>", users: []) == ["Acme Rewards"])
    }

    @Test func dropsBareReadableDatesOnly() {
        let dropped = ["8 Nov, 2026 at 10:36 am", "8 Nov 2026", "Nov 8, 2026", "November 8 2026 10:36 AM",
                       "Sunday, 8 November 2026", "Sun 8 Nov 2026 at 10:36 am", "8th Nov 2026"]
        #expect(facts(dropped, sender: nil, users: []).isEmpty)
        #expect(facts(["Order completed 8 Nov 2026", "Due 2026-12-01", "8 Nov"], sender: nil, users: [])
                == ["Order completed 8 Nov 2026", "Due 2026-12-01", "8 Nov"])
    }

    @Test func keepsEverythingWithNoSenderOrNames() {
        #expect(facts(["A", "B"], sender: nil, users: []) == ["A", "B"])
        #expect(facts(["", "  "], sender: nil, users: []).isEmpty)
    }
}

struct CompactAgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [(30, "now"), (-30, "now"), (300, "5m ago"), (75_600, "21h ago"), (259_200, "3d ago"), (1_209_600, "2w ago")])
    func formatsAges(seconds: Int, expected: String) {
        #expect(ReviewPresentation.compactAge(of: now.addingTimeInterval(-Double(seconds)), now: now) == expected)
    }
}
