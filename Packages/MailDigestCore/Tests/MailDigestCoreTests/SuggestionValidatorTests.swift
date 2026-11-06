import Foundation
import Testing
@testable import MailDigestCore

private let brisbane = TimeZone(identifier: "Australia/Brisbane")!
private let today = FixtureLoader.today // 2026-11-04 06:30 Brisbane

private func email(_ body: String, id: String = "e1") -> EmailMessage {
    EmailMessage(id: id, account: "iCloud", mailbox: "Inbox", sender: "a@b.c", subject: "s",
                 receivedAt: today, body: body, headers: [:])
}

private func task(_ title: String = "Send the report", due: String? = nil, evidence: String,
                  confidence: Double = 0.9) -> ExtractedTask {
    ExtractedTask(title: title, due: due, dueHasTime: false, priority: .medium,
                  evidence: evidence, confidence: confidence)
}

private func context(recent: [Suggestion] = [], approved: Bool = false, max: Int = 3) -> ValidationContext {
    ValidationContext(today: today, recentSuggestions: recent, senderHasApprovedDecision: approved, maxSuggestions: max)
}

private func suggestion(_ title: String, due: Date? = nil, status: SuggestionStatus = .pending,
                        confidence: Double = 0.9) -> Suggestion {
    Suggestion(id: UUID(), emailID: "old", title: title, due: due, dueHasTime: false, priority: .medium,
               evidence: "x", confidence: confidence, preselected: false, flags: [], status: status,
               reminderID: nil)
}

private let validator = SuggestionValidator(timeZone: brisbane)

@Suite struct SuggestionValidatorTests {
    @Test func lowConfidenceDropped() {
        let body = "Please send the report."
        let low = validator.validate([task(evidence: body, confidence: 0.39)], email: email(body), context: context())
        #expect(low.isEmpty)
        let edge = validator.validate([task(evidence: body, confidence: 0.4)], email: email(body), context: context())
        #expect(edge.count == 1)
    }

    @Test func evidenceMustAppearInBody() {
        let body = "Please send the report."
        #expect(validator.validate([task(evidence: "Please send the budget.")], email: email(body), context: context()).isEmpty)
        #expect(validator.validate([task(evidence: "")], email: email(body), context: context()).isEmpty)
        #expect(validator.validate([task(evidence: "   \n ")], email: email(body), context: context()).isEmpty)
    }

    @Test func evidenceIgnoresCaseAndWhitespace() {
        let body = "Hello,\n\nPlease   send\tthe\nreport   soon."
        let out = validator.validate([task(evidence: "please send the REPORT soon.")], email: email(body), context: context())
        #expect(out.count == 1)
        // The original evidence is kept on the suggestion.
        #expect(out[0].evidence == "please send the REPORT soon.")
    }

    @Test func titleLengthAndTrim() {
        let body = "Please send the report."
        func run(_ title: String) -> [Suggestion] {
            validator.validate([task(title, evidence: body)], email: email(body), context: context())
        }
        #expect(run("ab").isEmpty)
        #expect(run("  abc  ").first?.title == "abc")
        #expect(run(String(repeating: "a", count: 80)).count == 1)
        #expect(run(String(repeating: "a", count: 81)).isEmpty)
        #expect(run("   ").isEmpty)
    }

    @Test func urlTitlesDropped() {
        let body = "Please send the report."
        for title in ["Visit http://x.co now", "Open HTTPS://x.co", "Go to www.example.com"] {
            #expect(validator.validate([task(title, evidence: body)], email: email(body), context: context()).isEmpty, "\(title)")
        }
    }

    @Test func outOfRangeDueClearsDateButKeepsTask() {
        let body = "Send the report by Friday 5pm."
        let past = validator.validate([task(due: "2026-11-03", evidence: body)], email: email(body), context: context())
        #expect(past.count == 1 && past[0].due == nil && !past[0].dueHasTime)
        let far = validator.validate([task(due: "2030-01-01", evidence: body)], email: email(body), context: context())
        #expect(far.count == 1 && far[0].due == nil)
        let junk = validator.validate([task(due: "soon", evidence: body)], email: email(body), context: context())
        #expect(junk.count == 1 && junk[0].due == nil)
    }

    @Test func validDueIsResolved() throws {
        let body = "Send the report by Monday 9 November at 5pm."
        let out = validator.validate([task(due: "2026-11-09T17:00", evidence: body)], email: email(body), context: context())
        let s = try #require(out.first)
        #expect(s.due == Date(timeIntervalSince1970: 1_794_207_600)) // 2026-11-09T07:00Z
        #expect(s.dueHasTime)
        #expect(s.status == .pending && s.reminderID == nil && s.emailID == "e1")
    }

    @Test func dueClearedWithoutDateWordsInEvidence() {
        let body = "Please send the report."
        let out = validator.validate([task(due: "2026-11-09", evidence: body)], email: email(body), context: context())
        #expect(out.count == 1 && out[0].due == nil)
    }

    @Test func dateWordsAreRecognised() {
        func keeps(_ evidence: String) -> Bool {
            let out = validator.validate([task(due: "2026-11-09", evidence: evidence)], email: email(evidence), context: context())
            return out.first?.due != nil
        }
        for e in ["Send it Monday", "Send it on Fri", "Send it in November", "Send it by 9 Nov",
                  "Send it today", "Send it tonight", "Send it by EOD", "Send it by 5pm",
                  "Send it by 5 pm", "Send it by 5:30", "Send it by 17:00", "Send it by 9am",
                  "Send it on 9/11", "Send it on 09/11/2026", "Send it on 2026-11-09",
                  "Send it by the 9th", "Send it by 5 May", "Send it by May 5", "Send it next week",
                  "Send it this weekend", "Send it this morning", "Send it at noon"] {
            #expect(keeps(e), "\(e)")
        }
        for e in ["You may send it", "Send it soon", "Send it asap", "Send it, thanks"] {
            #expect(!keeps(e), "\(e)")
        }
    }

    @Test func moneyFlagForNewSender() {
        let body = "Please pay the invoice for the course."
        let out = validator.validate([task("Pay course invoice", evidence: body)], email: email(body), context: context())
        #expect(out[0].flags == ["money-new-sender"])
        #expect(!out[0].preselected)
    }

    @Test func moneyFlagClearedByApprovedDecision() {
        let body = "Please pay the invoice for the course."
        let out = validator.validate([task("Pay course invoice", evidence: body)], email: email(body), context: context(approved: true))
        #expect(out[0].flags.isEmpty)
        #expect(out[0].preselected)
    }

    @Test func moneyWordsMatchAtWordStart() {
        func flagged(_ title: String, _ evidence: String) -> Bool {
            validator.validate([task(title, evidence: evidence)], email: email(evidence), context: context())
                .first?.flags.isEmpty == false
        }
        #expect(flagged("Do the thing", "Your payment is overdue"))
        #expect(flagged("Do the thing", "Visit your Bank today"))
        #expect(flagged("Buy gift cards", "Buy them"))
        #expect(flagged("Do the thing", "Get a gift card now"))
        #expect(!flagged("Do the thing", "Pick up the prepaid parcel"))
        #expect(!flagged("Do the thing", "A gift for you"))
    }

    @Test func preselectionThresholdIsExact() {
        let body = "Please send the report."
        func pre(_ c: Double) -> Bool {
            validator.validate([task(evidence: body, confidence: c)], email: email(body), context: context())[0].preselected
        }
        #expect(pre(0.75))
        #expect(!pre(0.7499))
        #expect(pre(1.0))
    }

    @Test func dedupeAgainstRecentPendingAndApproved() throws {
        let body = "Please send the report."
        let run = { (recent: [Suggestion]) in
            validator.validate([task("Send the report!", evidence: body)], email: email(body), context: context(recent: recent))
        }
        #expect(run([suggestion("send  the REPORT")]).isEmpty)
        #expect(run([suggestion("Send the report", status: .approved)]).isEmpty)
        #expect(run([suggestion("Send the report", status: .dismissed)]).count == 1)
        #expect(run([suggestion("Send the report", status: .failed)]).count == 1)
        #expect(run([suggestion("Send a different report")]).count == 1)
    }

    @Test func dedupeRequiresSameDueDay() {
        let body = "Send the report on Monday."
        let monday = Date(timeIntervalSince1970: 1_794_146_400) // 2026-11-09 00:00 Brisbane
        let t = task(due: "2026-11-09", evidence: body)
        // Same day, different time of day.
        let sameDay = suggestion("Send the report", due: monday.addingTimeInterval(3600 * 9))
        #expect(validator.validate([t], email: email(body), context: context(recent: [sameDay])).isEmpty)
        let otherDay = suggestion("Send the report", due: monday.addingTimeInterval(86400))
        #expect(validator.validate([t], email: email(body), context: context(recent: [otherDay])).count == 1)
        let noDue = suggestion("Send the report", due: nil)
        #expect(validator.validate([t], email: email(body), context: context(recent: [noDue])).count == 1)
    }

    @Test func dedupeWithinEmailKeepsBestCopy() {
        let body = "Please send the report."
        let out = validator.validate(
            [task("Send report", evidence: body, confidence: 0.6), task("send report.", evidence: body, confidence: 0.9)],
            email: email(body), context: context())
        #expect(out.count == 1)
        #expect(out[0].confidence == 0.9)
    }

    @Test func atMostThreePerEmailBestFirst() {
        let body = "Please do all of these things."
        let tasks = [0.5, 0.9, 0.6, 0.8, 0.9].enumerated().map { i, c in
            task("Task number \(i)", evidence: body, confidence: c)
        }
        let out = validator.validate(tasks, email: email(body), context: context())
        #expect(out.map(\.title) == ["Task number 1", "Task number 4", "Task number 3"])
    }

    @Test func trustedNewsletterKeepsUpToEight() {
        let body = "Please do all of these things."
        let tasks = (0..<10).map { task("Task number \($0)", evidence: body, confidence: 0.9 - Double($0) * 0.01) }
        #expect(validator.validate(tasks, email: email(body), context: context(max: 8)).count == 8)
        #expect(validator.validate(tasks, email: email(body), context: context()).count == 3)
        // The limit can never exceed the schema maximum.
        #expect(context(max: 50).maxSuggestions == 8)
    }

    @Test func makeIDIsUsed() {
        let fixed = UUID()
        let v = SuggestionValidator(timeZone: brisbane, makeID: { fixed })
        let body = "Please send the report."
        #expect(v.validate([task(evidence: body)], email: email(body), context: context())[0].id == fixed)
    }

    @Test func capDigestKeepsTopTwentyFiveInOrder() {
        let all = (0..<30).map { i in suggestion("Item \(i)", confidence: i < 5 ? 0.41 : 0.5 + Double(i) / 100) }
        let capped = validator.capDigest(all)
        #expect(capped.count == 25)
        // The five lowest (indexes 0 to 4) go, the rest keep their order.
        #expect(capped.map(\.id) == all.dropFirst(5).map(\.id))
        #expect(validator.capDigest(Array(all.prefix(3))).count == 3)
        #expect(validator.capDigest(all, limit: 2).count == 2)
    }

    @Test func fixtureEmailsBehaveAsDesigned() throws {
        let emails = try FixtureLoader.loadEmails()
        let results = try FixtureLoader.loadResultsByEmailID()
        let ctx = ValidationContext(today: FixtureLoader.today, recentSuggestions: [], senderHasApprovedDecision: false)
        let v = SuggestionValidator(timeZone: FixtureLoader.timeZone)
        var seen = Set<String>()
        for e in emails {
            let tasks = try #require(results[e.id]).tasks
            let out = v.validate(tasks, email: e, context: ctx)
            #expect(out.count <= 3)
            if e.id.hasPrefix("inject-16") {
                #expect(out.isEmpty)
                seen.insert("inject")
            } else if e.id.hasPrefix("scam-15") {
                let s = try #require(out.first)
                #expect(s.flags == ["money-new-sender"])
                #expect(!s.preselected)
                seen.insert("scam")
            } else if e.id.hasPrefix("uni-assessment-01") {
                let s = try #require(out.first)
                let parts = Calendar(identifier: .gregorian).dateComponents(in: FixtureLoader.timeZone, from: try #require(s.due))
                #expect(parts.month == 11 && parts.day == 9)
                seen.insert("uni")
            }
        }
        #expect(seen == ["inject", "scam", "uni"])
    }
}
