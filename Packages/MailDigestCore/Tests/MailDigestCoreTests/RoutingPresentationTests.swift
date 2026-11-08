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
            (.private, .systemOne, "Sensitive · System One"),
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

    @Test func routeTextsAndRiskRow() {
        func a(_ m: AssessmentMethod, _ t: TriageTrigger?, signal: String? = nil) -> PrivacyAssessment {
            var x = Self.assessment(.public, m); x.triageTrigger = t; x.riskSignal = signal; return x
        }
        #expect(RoutingPresentation.routeText(a(.trustedSender, nil)) == "Trusted public sender · System One not required")
        #expect(RoutingPresentation.routeText(a(.systemOne, .trustedSenderRisk))
                == "Trusted public sender · Selective System One assessment")
        #expect(RoutingPresentation.routeText(a(.systemOne, .ambiguousSender)) == "Ambiguous sender · System One assessment")
        #expect(RoutingPresentation.routeText(a(.systemOne, .sensitiveSender))
                == "Sensitive sender domain · System One assessment")
        #expect(RoutingPresentation.routeText(a(.rule, nil)) == "Strong private match · System One not required")
        #expect(RoutingPresentation.routeText(a(.systemOne, nil)) == nil)
        #expect(RoutingPresentation.routeText(a(.inspection, nil)) == nil)

        let selective = RoutingProvenance(assessment: a(.systemOne, .trustedSenderRisk, signal: "risk.embedded.conversation"))
        let lines = RoutingPresentation.details(selective)
        #expect(lines.first?.label == "Route")
        #expect(lines.map(\.label).firstIndex(of: "Route")! < lines.map(\.label).firstIndex(of: "Privacy")!)
        #expect(lines.first { $0.label == "Risk signal" }?.value == "Embedded conversation")
        #expect(RoutingPresentation.riskSignalLabel("risk.unknown") == "risk.unknown")
        // Old rows (no trigger) have no Route or Risk signal rows.
        let old = RoutingPresentation.details(RoutingProvenance(assessment: Self.assessment(.uncertain, .systemOne)))
        #expect(!old.contains { $0.label == "Route" || $0.label == "Risk signal" })
        let trusted = RoutingProvenance(assessment: a(.trustedSender, nil))
        #expect(RoutingPresentation.routingExplanation(for: trusted) == "Trusted public sender · System One not required")
    }

    @Test func systemOneSensitiveIsItsOwnBucket() {
        func local(_ reason: LocalReason, _ a: PrivacyAssessment) -> RoutingProvenance {
            RoutingProvenance(assessment: a, execution: Self.exec(.local, "qwen3:4b", reason: reason))
        }
        let items: [RoutingProvenance?] = [
            local(.privateContent, Self.assessment(.private, .systemOne)),
            local(.privateContent, Self.assessment(.private, .systemOne)),
            local(.privateContent, Self.assessment(.private, .rule, rule: "kw.otp")),
            local(.privateContent, Self.assessment(.private, .rule, rule: "kw.financial")),
            local(.notEligible, Self.assessment(.uncertain, .systemOne)),
        ]
        let counts = RoutingPresentation.localReasonSummary(items)
        #expect(counts.contains(.init(bucket: .systemOneSensitive, count: 2)))
        #expect(counts.contains(.init(bucket: .privateRule, count: 2)))
        #expect(counts.contains(.init(bucket: .systemOneLowConfidence, count: 1)))
        #expect(RoutingPresentation.localReasonSummaryText(items)?.contains("2 classified sensitive") == true)
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
                == "Content not fully inspected, so it stayed on this Mac.")
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

    // MARK: Inspection gap

    @Test func oldAssessmentJSONWithoutGapDecodesAndShowsGenericLabel() throws {
        let json = #"{"verdict":"notAssessed","method":"inspection","assessedAt":0}"#
        let a = try JSONDecoder().decode(PrivacyAssessment.self, from: Data(json.utf8))
        #expect(a.inspectionGap == nil)
        #expect(RoutingPresentation.privacyBadge(a).text == "Local only · Content not fully inspected")
        let round = try JSONDecoder().decode(PrivacyAssessment.self, from: JSONEncoder().encode(
            PrivacyAssessment(verdict: .notAssessed, method: .inspection, assessedAt: Self.t0, inspectionGap: .attachment)))
        #expect(round.inspectionGap == .attachment)
    }

    @Test func emailMessageGapRoundTripsAndDefaultsToNil() throws {
        var e = EmailMessage(id: "i", account: "a", mailbox: "m", sender: "s", subject: "x", receivedAt: Self.t0,
                             body: "b", headers: [:])
        #expect(e.inspectionGap == nil)
        e.inspectionGap = .nonTextPart
        #expect(try JSONDecoder().decode(EmailMessage.self, from: JSONEncoder().encode(e)).inspectionGap == .nonTextPart)
    }

    @Test func gapLabelsAndExplanations() {
        let labels: [(InspectionGap?, String)] = [
            (.attachment, "Local only · Attachment not inspected"),
            (.nonTextPart, "Local only · Non-text content not inspected"),
            (.structureUnavailable, "Local only · Message structure unavailable"),
            (.undecodablePart, "Local only · Content not fully inspected"),
            (.partialMessage, "Local only · Content not fully inspected"),
            (nil, "Local only · Content not fully inspected"),
        ]
        for (gap, text) in labels {
            let a = PrivacyAssessment(verdict: .notAssessed, method: .inspection, assessedAt: Self.t0, inspectionGap: gap)
            #expect(RoutingPresentation.privacyBadge(a).text == text)
        }
        let base = "This email was processed locally because Mail Digest could not fully inspect all of its content, "
            + "such as attachments or non-text message parts. To protect your privacy, it was not sent to a cloud provider."
        #expect(RoutingPresentation.inspectionExplanation(nil) == base)
        #expect(RoutingPresentation.inspectionExplanation(.attachment)
                == base + " It has an attachment that Mail Digest doesn't read.")
        #expect(RoutingPresentation.inspectionExplanation(.nonTextPart)
                == base + " It contains non-text content, such as images or calendar data, that Mail Digest doesn't read.")
        #expect(RoutingPresentation.inspectionExplanation(.undecodablePart) == base + " Part of its text couldn't be decoded.")
        #expect(RoutingPresentation.inspectionExplanation(.partialMessage)
                == base + " Only part of this message was downloaded to this Mac.")
        #expect(RoutingPresentation.inspectionExplanation(.structureUnavailable).hasPrefix(
            "This email was processed locally because the email source didn't expose enough information"))
    }

    @Test func detailsSeparateInspectionFromPrivacy() {
        let r = RoutingProvenance(
            assessment: PrivacyAssessment(verdict: .notAssessed, method: .inspection, assessedAt: Self.t0,
                                          inspectionGap: .attachment),
            execution: Self.exec(.local, "qwen3:4b", reason: .contentNotInspected))
        let lines = RoutingPresentation.details(r)
        #expect(lines.first { $0.label == "Inspection" }?.value == "Attachment not inspected")
        #expect(lines.first { $0.label == "Privacy" }?.value == "Not classified")
        #expect(RoutingPresentation.inspectionExplanation(for: r)?.contains("attachment") == true)
        let rule = RoutingProvenance(assessment: Self.assessment(.private, .rule, rule: "kw.otp"))
        #expect(RoutingPresentation.inspectionExplanation(for: rule) == nil)
        #expect(!RoutingPresentation.details(rule).contains { $0.label == "Inspection" })
    }

    @Test func localReasonSummaryBuckets() {
        func local(_ reason: LocalReason?, _ a: PrivacyAssessment) -> RoutingProvenance {
            RoutingProvenance(assessment: a, execution: Self.exec(.local, "qwen3:4b", reason: reason))
        }
        func scores(_ p: Double) -> TriageScores {
            TriageScores(model: "m", pSensitive: p, pNonSensitive: 1 - p, categoryProbabilities: [:],
                         threshold: 0.9, publicFloor: 0.85)
        }
        let insp = Self.assessment(.notAssessed, .inspection)
        let items: [RoutingProvenance?] = [
            local(.contentNotInspected, insp), local(.contentNotInspected, insp), local(.contentNotInspected, insp),
            local(.privateContent, Self.assessment(.private, .rule, rule: "kw.otp")),
            local(.privateContent, Self.assessment(.private, .rule, rule: "kw.otp")),
            local(.notEligible, Self.assessment(.uncertain, .systemOne, triage: scores(0.6))),
            local(.notEligible, Self.assessment(.uncertain, .systemOne, triage: scores(0.2))),
            local(.notEligible, Self.assessment(.uncertain, .systemOne)),
            local(.cloudDisabled, Self.assessment(.notAssessed, .cloudOff)),
            local(.noCredential, Self.assessment(.notAssessed, .cloudOff)),
            local(.acknowledgementRequired, Self.assessment(.notAssessed, .cloudOff)),
            local(.cloudFailed, Self.assessment(.public, .systemOne)),
            local(.triageUnavailable, Self.assessment(.uncertain, .systemOne, failure: .timedOut)),
            local(nil, Self.assessment(.private, .rule)),
            // Cloud items never count; nil provenance is "not recorded".
            RoutingProvenance(assessment: Self.assessment(.public, .systemOne), execution: Self.exec(.cloud, "gemini-3.5-flash-lite")),
            nil,
        ]
        let summary = RoutingPresentation.localReasonSummary(items)
        func count(_ b: RoutingPresentation.LocalBucket) -> Int { summary.first { $0.bucket == b }?.count ?? 0 }
        #expect(count(.contentNotInspected) == 3)
        #expect(count(.privateRule) == 2)
        #expect(count(.systemOneSensitive) == 1)
        #expect(count(.systemOneLowConfidence) == 2)
        #expect(count(.cloudDisabled) == 1 && count(.noCredential) == 1 && count(.acknowledgementRequired) == 1)
        #expect(count(.cloudFailed) == 1 && count(.triageUnavailable) == 1)
        #expect(count(.notRecorded) == 2)
        #expect(summary.reduce(0) { $0 + $1.count } == 15)
        #expect(summary.first?.bucket == .contentNotInspected)

        #expect(RoutingPresentation.localReasonSummaryText([insp, insp].map { local(.contentNotInspected, $0) } +
                [local(.privateContent, Self.assessment(.private, .rule)), local(.notEligible, Self.assessment(.uncertain, .systemOne))])
                == "Local: 2 not fully inspected · 1 private rule · 1 low confidence")
        #expect(RoutingPresentation.localReasonSummaryText([]) == nil)
    }
}
