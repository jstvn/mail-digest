import Foundation
import Testing
@testable import MailDigestCore

@Suite struct RoutingPresentationTests {
    static let t0 = Date(timeIntervalSince1970: 1_793_737_800)

    static func item(_ state: JobItemState, routing: RoutingProvenance? = nil) -> JobItem {
        JobItem(id: UUID(), jobID: UUID(), messageID: "m", mailbox: MailboxRef(account: "a", name: "Inbox"),
                sender: "s", subject: "x", receivedAt: t0, position: 1, state: state, outcome: nil, seconds: nil,
                attempts: 0, lastError: nil, routing: routing)
    }

    static func assessment(_ v: PrivacyVerdict, _ m: AssessmentMethod, rule: String? = nil,
                           triage: TriageScores? = nil, failure: TriageFailure? = nil) -> PrivacyAssessment {
        PrivacyAssessment(verdict: v, method: m, ruleID: rule, triage: triage, triageFailure: failure, assessedAt: t0)
    }

    static func exec(_ p: ExecutionProvider, _ model: String, attempted: Bool = false,
                     reason: LocalReason? = nil, failure: String? = nil) -> ExecutionRecord {
        ExecutionRecord(provider: p, model: model, cloudAttempted: attempted, localReason: reason,
                        cloudFailure: failure, startedAt: t0, finishedAt: t0)
    }

    @Test func privacyLabels() {
        let cases: [(PrivacyVerdict, AssessmentMethod, String)] = [
            (.private, .rule, "Private · Rule"),
            (.public, .trustedSender, "Public · Trusted Sender"),
            (.public, .systemOne, "Public · System One"),
            (.uncertain, .systemOne, "Uncertain · System One"),
            (.notAssessed, .inspection, "Local only · Content not fully inspected"),
            (.notAssessed, .cloudOff, "Not assessed · Cloud off"),
        ]
        for (v, m, text) in cases {
            #expect(RoutingPresentation.privacyBadge(Self.assessment(v, m)).text == text)
        }
        #expect(RoutingPresentation.privacyBadge(Self.assessment(.private, .rule)).tone == .private)
        #expect(RoutingPresentation.privacyBadge(Self.assessment(.public, .systemOne)).tone == .public)
        #expect(RoutingPresentation.privacyBadge(Self.assessment(.uncertain, .systemOne)).tone == .uncertain)
        // An unexpected combination still reads sensibly.
        #expect(RoutingPresentation.privacyBadge(Self.assessment(.private, .cloudOff)).text == "Private · Cloud off")
    }

    @Test func executionLabels() {
        #expect(RoutingPresentation.executionBadge(Self.exec(.local, "qwen3:4b")).text == "Local · Qwen3 4B")
        #expect(RoutingPresentation.executionBadge(Self.exec(.cloud, "gemini-3.5-flash-lite", attempted: true)).text
                == "Cloud · Gemini 3.5 Flash-Lite")
        let fb = RoutingPresentation.executionBadge(Self.exec(.local, "qwen3:4b", attempted: true))
        #expect(fb.text == "Gemini failed → Local Qwen3 4B" && fb.tone == .fallback)
    }

    @Test func modelNames() {
        #expect(RoutingPresentation.modelDisplayName("qwen3:4b") == "Qwen3 4B")
        #expect(RoutingPresentation.modelDisplayName("qwen3:8b") == "Qwen3 8B")
        #expect(RoutingPresentation.modelDisplayName("gemini-3.5-flash-lite") == "Gemini 3.5 Flash-Lite")
        #expect(RoutingPresentation.modelDisplayName("gemini-2.5-pro") == "Gemini 2.5 Pro")
        #expect(RoutingPresentation.modelDisplayName("llama3:8b") == "llama3:8b")
        #expect(RoutingPresentation.modelDisplayName("gemini-2.5-flash-preview-05-20") == "gemini-2.5-flash-preview-05-20")
        #expect(RoutingPresentation.modelDisplayName("qwen3:4b-instruct-q4") == "qwen3:4b-instruct-q4")
    }

    @Test func itemBadgesForMissingRouting() {
        #expect(RoutingPresentation.privacyBadge(for: Self.item(.done))?.text == "Not recorded")
        #expect(RoutingPresentation.executionBadge(for: Self.item(.failed))?.text == "Not recorded")
        // Skipped, queued and processing items without routing show no badge.
        for s in [JobItemState.skipped, .queued, .processing] {
            #expect(RoutingPresentation.privacyBadge(for: Self.item(s)) == nil)
            #expect(RoutingPresentation.executionBadge(for: Self.item(s)) == nil)
        }
        let r = RoutingProvenance(assessment: Self.assessment(.private, .rule, rule: "kw.otp"),
                                  execution: Self.exec(.local, "qwen3:4b"))
        #expect(RoutingPresentation.privacyBadge(for: Self.item(.done, routing: r))?.text == "Private · Rule")
        #expect(RoutingPresentation.executionBadge(for: Self.item(.done, routing: r))?.text == "Local · Qwen3 4B")
        // Assessed but still running: privacy shows, execution does not.
        let pending = RoutingProvenance(assessment: Self.assessment(.private, .rule, rule: "kw.otp"))
        #expect(RoutingPresentation.privacyBadge(for: Self.item(.processing, routing: pending)) != nil)
        #expect(RoutingPresentation.executionBadge(for: Self.item(.processing, routing: pending)) == nil)
    }

    @Test func detailLines() {
        let scores = TriageScores(model: "kev:0.8b-q8_0", pSensitive: 0.04, pNonSensitive: 0.96,
                                  categoryProbabilities: [SystemOneSpec.publicCategory: 0.874], threshold: 0.9, publicFloor: 0.85)
        let r = RoutingProvenance(assessment: Self.assessment(.public, .systemOne, triage: scores),
                                  execution: Self.exec(.cloud, "gemini-3.5-flash-lite", attempted: true))
        let lines = RoutingPresentation.details(r)
        func value(_ label: String) -> String? { lines.first { $0.label == label }?.value }
        #expect(value("Triage model") == "kev:0.8b-q8_0")
        #expect(value("Non-sensitive confidence") == "96%")
        #expect(value("Public confidence") == "87%")
        #expect(value("Threshold") == "90%")
        #expect(value("Public floor") == "85%")
        #expect(value("Processed by") == "Cloud · Gemini 3.5 Flash-Lite")
        #expect(RoutingPresentation.showsScores(r))

        // Deterministic results list the rule and no scores.
        let rule = RoutingProvenance(assessment: Self.assessment(.private, .rule, rule: "kw.otp"),
                                     execution: Self.exec(.local, "qwen3:4b", reason: .privateContent))
        let ruleLines = RoutingPresentation.details(rule)
        #expect(ruleLines.first { $0.label == "Rule" }?.value == "kw.otp")
        #expect(!ruleLines.contains { $0.value.hasSuffix("%") })
        #expect(!RoutingPresentation.showsScores(rule))

        let failed = RoutingProvenance(
            assessment: Self.assessment(.uncertain, .systemOne, failure: .timedOut),
            execution: Self.exec(.local, "qwen3:4b", attempted: true, reason: .cloudFailed, failure: "rateLimited"))
        let fl = RoutingPresentation.details(failed)
        #expect(fl.first { $0.label == "Triage" }?.value == "The triage request timed out.")
        #expect(fl.first { $0.label == "Gemini error" }?.value == "Gemini rate limit reached.")
        #expect(fl.first { $0.label == "Why local" }?.value == "Gemini could not process it, so this Mac did.")
    }

    @Test func everyReasonAndFailureHasText() {
        for r in [LocalReason.cloudDisabled, .acknowledgementRequired, .noCredential, .contentNotInspected,
                  .privateContent, .notEligible, .triageUnavailable, .cloudFailed] {
            #expect(RoutingPresentation.localReasonText(r).hasSuffix("."))
        }
        #expect(RoutingPresentation.localReasonText(.contentNotInspected)
                == "Content not fully inspected (attachments or non-text parts), so it stayed on this Mac.")
        for f in [TriageFailure.unreachable, .versionTooOld, .versionUnknown, .modelMissing, .httpError, .timedOut,
                  .malformedResponse, .unsupportedModel] {
            #expect(!RoutingPresentation.triageFailureText(f).isEmpty)
        }
        for code in ["invalidCredential", "rateLimited", "modelUnavailable", "server503", "timedOut", "network",
                     "blocked", "malformedResponse", "unknown"] {
            #expect(!RoutingPresentation.cloudFailureText(code).isEmpty)
        }
        #expect(RoutingPresentation.cloudFailureText("server503") == "Gemini server error (503).")
    }
}
