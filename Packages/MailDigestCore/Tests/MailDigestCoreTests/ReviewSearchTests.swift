import Foundation
import Testing
@testable import MailDigestCore

@Suite struct ReviewSearchTests {
    @Test func blankQueryMatchesEverything() {
        #expect(ReviewSearch.matches("", fields: ["x"]))
        #expect(ReviewSearch.matches("   ", fields: []))
    }

    @Test func everyTermMustMatchSomeFieldIgnoringCaseAndAccents() {
        let fields = ["Attend Tanda AI Hackathon", "Philip Fraser", "You have registered for café night"]
        #expect(ReviewSearch.matches("tanda philip", fields: fields))
        #expect(ReviewSearch.matches("CAFE", fields: fields))
        #expect(!ReviewSearch.matches("tanda rent", fields: fields))
    }

    @Test func recordFieldsCoverTitleSenderAndEvidence() {
        let record = SuggestionRecord.records(from: PreviewFixtures.digest, kind: .daily, emails: PreviewFixtures.emails)[0]
        let fields = ReviewSearch.fields(for: record)
        #expect(ReviewSearch.matches("pay rent", fields: fields))
        #expect(ReviewSearch.matches("due this friday", fields: fields))
        #expect(ReviewSearch.matches("raywhite", fields: fields))
        #expect(!ReviewSearch.matches("hackathon", fields: fields))
    }
}

@Suite struct SuggestionAccessibilityTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return c
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10))!

    static func record(status: SuggestionStatus = .pending, due: Date?, hasTime: Bool, flags: [String] = []) -> SuggestionRecord {
        let s = Suggestion(id: UUID(), emailID: "e", title: "Attend Tanda AI Hackathon", due: due, dueHasTime: hasTime,
                           priority: .high, evidence: "q", confidence: 0.9, preselected: true, flags: flags, status: status,
                           reminderID: nil, category: .events)
        let email = EmailContext(sender: "Philip Fraser <p@x.example>", subject: "s", mailbox: MailboxRef(account: "a", name: "Inbox"))
        return SuggestionRecord(suggestion: s, digestID: UUID(), digestCreatedAt: now, kind: .daily, category: .events, email: email)
    }

    @Test func spokenLabelMatchesTheDesignSpec() {
        let due = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 17, minute: 30))!
        let text = SuggestionAccessibility.label(for: Self.record(due: due, hasTime: true), isSelected: true,
                                                 now: Self.now, calendar: Self.calendar)
        #expect(text == "Attend Tanda AI Hackathon. High priority. Due in 11 days, Friday 20 November at 5:30 pm. From Philip Fraser. Selected.")
    }

    @Test func spokenLabelIncludesSteps() {
        var r = Self.record(due: nil, hasTime: false)
        r.suggestion.steps = ["Note meeting ID", "Save passcode"]
        let text = SuggestionAccessibility.label(for: r, isSelected: false, now: Self.now, calendar: Self.calendar)
        #expect(text.hasPrefix("Attend Tanda AI Hackathon. Steps: Note meeting ID, Save passcode. High priority."))
        #expect(ReviewPresentation.stepCountText(0) == nil)
        #expect(ReviewPresentation.stepCountText(1) == "1 step")
        #expect(ReviewPresentation.stepCountText(3) == "3 steps")
    }

    @Test func noDateReviewAndStatuses() {
        let r = Self.record(due: nil, hasTime: false, flags: ["money-new-sender"])
        let text = SuggestionAccessibility.label(for: r, isSelected: false, now: Self.now, calendar: Self.calendar)
        #expect(text.contains("Needs review"))
        #expect(text.contains("No date"))
        #expect(text.hasSuffix("Not selected."))
        let added = SuggestionAccessibility.label(for: Self.record(status: .approved, due: nil, hasTime: false), isSelected: false,
                                                  now: Self.now, calendar: Self.calendar)
        #expect(added.hasSuffix("Added to Reminders."))
    }
}
