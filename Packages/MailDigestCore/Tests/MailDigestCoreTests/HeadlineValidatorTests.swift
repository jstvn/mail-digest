import Testing
@testable import MailDigestCore

@Suite struct HeadlineValidatorTests {
    @Test func acceptsNormalSentenceTrimmed() {
        #expect(HeadlineValidator.validated("  Assessment due Monday.  ") == "Assessment due Monday.")
    }

    @Test func rejectsEmptyMultilineAndTooLong() {
        #expect(HeadlineValidator.validated("  \n ") == nil)
        #expect(HeadlineValidator.validated("One.\nTwo.") == nil)
        #expect(HeadlineValidator.validated(String(repeating: "a", count: 281)) == nil)
        #expect(HeadlineValidator.validated(String(repeating: "a", count: 280)) != nil)
    }
}
