import Foundation
import Testing
@testable import MailDigestCore

private let today = FixtureLoader.today
private let tz = FixtureLoader.timeZone

private func pipeline(_ llm: StubLLMClient, filter: MailFilter = MailFilter()) -> DigestPipeline {
    DigestPipeline(llm: llm, filter: filter, timeZone: tz)
}

private func run(_ p: DigestPipeline, _ email: EmailMessage) async throws -> EmailOutcome {
    try await p.process(email, today: today, recentSuggestions: [], senderHasApprovedDecision: false)
}

private func fixture(_ prefix: String) throws -> EmailMessage {
    try #require(try FixtureLoader.loadEmails().first { $0.id.hasPrefix(prefix) })
}

@Suite struct DigestPipelineTests {
    @Test func bodyEmptyAfterCleaningSkipsWithoutModelCall() async throws {
        let llm = StubLLMClient(results: try FixtureLoader.loadResultsByEmailID())
        var email = try fixture("bill-rent-04")
        email.body = " \n\n \t"
        let out = try await run(pipeline(llm), email)
        #expect(out.tier == .skip)
        #expect(out.info == nil && out.suggestions.isEmpty)
        #expect(out.skipped?.reason == "no readable body")
        #expect(await llm.extractCalls.isEmpty)
    }

    @Test func fullTierProducesInfoAndSuggestion() async throws {
        let llm = StubLLMClient(results: try FixtureLoader.loadResultsByEmailID())
        let out = try await run(pipeline(llm), fixture("bill-rent-04"))
        #expect(out.tier == .full)
        #expect(out.info?.id == out.info?.emailID)
        #expect(out.info?.pinned == false)
        #expect(out.suggestions.map(\.title) == ["Pay rent $420"])
        #expect(out.summaryText == "1 reminder, info")
    }

    @Test func infoOnlyTierHasNoSuggestions() async throws {
        let llm = StubLLMClient(results: try FixtureLoader.loadResultsByEmailID())
        let out = try await run(pipeline(llm), fixture("news-tech-09"))
        #expect(out.tier == .infoOnly)
        #expect(out.info != nil)
        #expect(out.suggestions.isEmpty)
        #expect(out.summaryText == "info only")
    }

    @Test func trustedNewsletterGetsTasksUpToEight() async throws {
        let email = try fixture("news-tech-09")
        let evidence = try #require(email.body.split(separator: "\n").map(String.init)
            .first { $0.trimmingCharacters(in: .whitespaces).count > 10 })
        let tasks = (0..<10).map {
            ExtractedTask(title: "Newsletter task \($0)", due: nil, dueHasTime: false, priority: .medium,
                          evidence: evidence, confidence: 0.9)
        }
        let result = ExtractionResult(summary: "News.", category: .newsletters, importance: 2, keyFacts: [], tasks: tasks)
        let llm = StubLLMClient(results: [email.id: result])

        // Ordinary newsletter: summary only, model told nothing special.
        let ordinary = try await run(pipeline(llm), email)
        #expect(ordinary.tier == .infoOnly && ordinary.info != nil && ordinary.suggestions.isEmpty)

        // Trusted: summary plus up to 8 validated suggestions, and the model is told.
        let filter = MailFilter(trustedNewsletterSenders: [MailFilter.address(from: email.sender)])
        let trusted = try await run(pipeline(llm, filter: filter), email)
        #expect(trusted.tier == .full && trusted.info != nil)
        #expect(trusted.suggestions.count == 8)
        let calls = await llm.extractCalls
        #expect(calls.map(\.trustedNewsletter) == [false, true])
        #expect(calls.map(\.tier) == [.infoOnly, .full])
    }

    @Test func ordinaryFullMailStaysAtThree() async throws {
        let email = try fixture("bill-rent-04")
        let evidence = try #require(email.body.split(separator: "\n").map(String.init)
            .first { $0.trimmingCharacters(in: .whitespaces).count > 10 })
        let tasks = (0..<6).map {
            ExtractedTask(title: "Rent task \($0)", due: nil, dueHasTime: false, priority: .medium,
                          evidence: evidence, confidence: 0.9)
        }
        let llm = StubLLMClient(results: [email.id: ExtractionResult(
            summary: "Rent.", category: .finance, importance: 3, keyFacts: [], tasks: tasks)])
        let out = try await run(pipeline(llm), email)
        #expect(out.suggestions.count == 3)
        #expect(await llm.extractCalls.map(\.trustedNewsletter) == [false])
    }

    @Test func blockedSenderSkipsWithoutModelCall() async throws {
        let llm = StubLLMClient()
        let email = try fixture("work-13")
        let filter = MailFilter(blockedSenders: [MailFilter.address(from: email.sender)])
        let out = try await run(pipeline(llm, filter: filter), email)
        #expect(out.tier == .skip)
        #expect(out.info == nil && out.suggestions.isEmpty)
        #expect(out.skipped?.reason == "blocked sender")
        #expect(out.summaryText == "skipped: blocked sender")
        #expect(await llm.extractCalls.isEmpty)
    }

    @Test func importanceClampedAndFactsTrimmed() async throws {
        let result = ExtractionResult(summary: "S", category: .work, importance: 9,
                                      keyFacts: ["a", "b", "c", "d", "e", "f"], tasks: [])
        let llm = StubLLMClient(defaultResult: result)
        let out = try await run(pipeline(llm), fixture("work-13"))
        #expect(out.info?.importance == 5)
        #expect(out.info?.keyFacts == ["a", "b", "c", "d"])
        let low = StubLLMClient(defaultResult: ExtractionResult(summary: "S", category: .work, importance: -3, keyFacts: [], tasks: []))
        #expect(try await run(pipeline(low), fixture("work-13")).info?.importance == 1)
    }

    @Test func modelErrorPropagates() async throws {
        let email = try fixture("work-13")
        let llm = StubLLMClient(failures: [email.id: 1])
        await #expect(throws: StubLLMError.self) { _ = try await run(pipeline(llm), email) }
    }

    @Test func headlineUsesModelAndFallsBack() async throws {
        let llm = StubLLMClient(headlineText: "  A calm day.  ")
        let p = pipeline(llm)
        let info = InfoItem(id: "a", emailID: "a", category: .other, importance: 1, summary: "s", keyFacts: [], pinned: false)
        let sug = Suggestion(id: UUID(), emailID: "a", title: "T", due: nil, dueHasTime: false, priority: .low,
                             evidence: "e", confidence: 0.9, preselected: true, flags: [], status: .pending, reminderID: nil)
        let digest = Digest(id: UUID(), createdAt: today, headline: "", emailCount: 23, suggestions: [sug], info: [info], skipped: [])
        #expect(await p.headline(for: digest) == "A calm day.")

        // Fallback when the model has nothing usable.
        await llm.setHeadlineText("   ")
        #expect(await p.headline(for: digest) == "23 emails, 1 suggestion.")
    }

    @Test func headlineFallsBackWhenModelThrows() async {
        struct Failing: LLMClient {
            func healthCheck() async throws {}
            func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool, today: Date,
                         timeZone: TimeZone) async throws -> ExtractionResult { throw StubLLMError.malformed }
            func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String { throw StubLLMError.malformed }
        }
        let p = DigestPipeline(llm: Failing(), filter: MailFilter(), timeZone: tz)
        let info = InfoItem(id: "a", emailID: "a", category: .other, importance: 1, summary: "s", keyFacts: [], pinned: false)
        let digest = Digest(id: UUID(), createdAt: today, headline: "", emailCount: 23, suggestions: [], info: [info], skipped: [])
        #expect(await p.headline(for: digest) == "23 emails, 0 suggestions.")
    }
}
