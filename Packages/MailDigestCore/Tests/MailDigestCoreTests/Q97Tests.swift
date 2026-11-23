import Foundation
import Testing
@testable import MailDigestCore

private let filter = PrivacyPreFilter()
private let unsub = ["List-Unsubscribe": "<https://example.com/u?id=1>"]

private func input(_ sender: String, subject: String, body: String = "Thanks for signing up.",
                   headers: [String: String] = unsub) -> PrivacyInput {
    PrivacyInput(sender: sender, subject: subject, body: body, headers: headers, inspection: .complete)
}

@Suite struct Q97AccountVerificationTests {
    @Test(arguments: [
        "Confirm your email address to join Tanda Hackathon 2026",
        "Please verify your email",
        "Verify your account to continue",
        "Confirm your account",
        "Activate your account today",
        "Email verification required",
    ])
    func verificationLanguageIsPrivate(subject: String) {
        // Even an allowlisted bulk sender stays local: a strong indicator always wins.
        #expect(filter.classify(input("Glassdoor <noreply@glassdoor.com>", subject: subject)) == .private("kw.credentials"))
    }

    @Test func ordinaryNewsletterIsUnaffected() {
        let v = filter.classify(input("Glassdoor <noreply@glassdoor.com>", subject: "10 more jobs in Brisbane",
                                      body: "Your email preferences can be changed anytime."))
        #expect(v == .public("allowlist.glassdoor"))
    }

    @Test func openAIMarketingHostIsAllowlistedButNotOtherOpenAIHosts() {
        #expect(filter.classify(input("ChatGPT <noreply@email.openai.com>", subject: "Turn work notes into a usable doc"))
                == .public("allowlist.openai.marketing"))
        #expect(filter.classify(input("OpenAI <noreply@tm.openai.com>", subject: "Turn work notes into a usable doc"))
                == .needsTriage(.ambiguousSender, signal: nil))
    }
}
