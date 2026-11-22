import Foundation

/// How a badge should be coloured and which symbol it carries; the UI maps tones to system colours.
public enum RoutingBadgeTone: String, Sendable, Equatable {
    case `private`, `public`, uncertain, local, cloud, fallback, neutral
}

/// Text and tone of one capsule badge.
public struct RoutingBadge: Sendable, Equatable {
    public var text: String
    public var tone: RoutingBadgeTone
}

/// A label and value shown in the routing popover.
public struct RoutingDetailLine: Sendable, Equatable {
    public var label: String
    public var value: String
}

/// Privacy and execution badges and detail lines for one `job_item`. Pure text; nothing is back-filled.
public enum RoutingPresentation {
    /// Shown under the scores, so they are never read as accuracy.
    public static let scoreNote = "Scores are the triage model's confidence, not a guarantee of accuracy."
    public static let notRecorded = "Not recorded"
    /// Shown instead of badges when no model ran.
    public static let noModelText = "No model · Skipped"

    /// The privacy badge; nil when nothing applies (skipped, queued or running without an assessment).
    public static func privacyBadge(for item: JobItem) -> RoutingBadge? {
        if let routing = item.routing { return privacyBadge(routing.assessment) }
        return isFinal(item) ? RoutingBadge(text: notRecorded, tone: .neutral) : nil
    }

    /// The execution badge; nil when no model ran or the item is not finished.
    public static func executionBadge(for item: JobItem) -> RoutingBadge? {
        if let execution = item.routing?.execution { return executionBadge(execution) }
        return isFinal(item) ? RoutingBadge(text: notRecorded, tone: .neutral) : nil
    }

    /// Done and failed items ran (or tried to run) a model; skipped ones never reach one.
    private static func isFinal(_ item: JobItem) -> Bool { item.state == .done || item.state == .failed }

    public static func privacyBadge(_ a: PrivacyAssessment) -> RoutingBadge {
        switch (a.verdict, a.method) {
        case (.private, .rule): return RoutingBadge(text: "Private · Rule", tone: .private)
        case (.public, .trustedSender): return RoutingBadge(text: "Public · Trusted Sender", tone: .public)
        case (.public, .systemOne): return RoutingBadge(text: "Public · System One", tone: .public)
        case (.private, .systemOne): return RoutingBadge(text: "Sensitive · System One", tone: .private)
        case (.uncertain, .systemOne): return RoutingBadge(text: "Uncertain · System One", tone: .uncertain)
        case (.notAssessed, .inspection):
            return RoutingBadge(text: "Local only · \(inspectionTitle(a.inspectionGap))", tone: .uncertain)
        case (.notAssessed, .cloudOff): return RoutingBadge(text: "Not assessed · Cloud off", tone: .neutral)
        default:
            let tone: RoutingBadgeTone = a.verdict == .private ? .private : a.verdict == .public ? .public
                : a.verdict == .uncertain ? .uncertain : .neutral
            return RoutingBadge(text: "\(verdictTitle(a.verdict)) · \(methodTitle(a.method))", tone: tone)
        }
    }

    public static func executionBadge(_ e: ExecutionRecord) -> RoutingBadge {
        let model = modelDisplayName(e.model)
        switch e.provider {
        case .cloud: return RoutingBadge(text: "Cloud · \(model)", tone: .cloud)
        case .local where e.cloudAttempted:
            return RoutingBadge(text: "\((e.cloudProvider ?? .gemini).displayName) failed → Local \(model)", tone: .fallback)
        case .local: return RoutingBadge(text: "Local · \(model)", tone: .local)
        }
    }

    /// "qwen3:4b" becomes "Qwen3 4B", "gemini-3.5-flash-lite" becomes "Gemini 3.5 Flash-Lite"; anything else is the raw id.
    public static func modelDisplayName(_ id: String) -> String {
        let lower = id.lowercased()
        if lower.hasPrefix("qwen3:") {
            let tag = String(lower.dropFirst(6))
            if tag.count >= 2, tag.hasSuffix("b"), Double(tag.dropLast()) != nil { return "Qwen3 \(tag.uppercased())" }
        }
        if lower.hasPrefix("gemini-") {
            let parts = lower.split(separator: "-").map(String.init)
            if parts.count >= 2, Double(parts[1]) != nil,
               parts.dropFirst(2).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) {
                let rest = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
                return rest.isEmpty ? "Gemini \(parts[1])" : "Gemini \(parts[1]) \(rest)"
            }
        }
        if lower.hasPrefix("claude-") {
            // "claude-haiku-5-5" becomes "Claude Haiku 5.5"; a trailing date stamp or odd shape stays raw.
            let parts = lower.split(separator: "-").map(String.init)
            if parts.count >= 3, parts[1].allSatisfy(\.isLetter),
               parts.dropFirst(2).allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }) {
                let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
                return "Claude \(family) \(parts.dropFirst(2).joined(separator: "."))"
            }
        }
        return id
    }

    /// Popover lines for one item's routing, in reading order. Deterministic results list the rule, never a score.
    public static func details(_ routing: RoutingProvenance) -> [RoutingDetailLine] {
        var lines: [RoutingDetailLine] = []
        let a = routing.assessment
        if let route = routeText(a) { lines.append(RoutingDetailLine(label: "Route", value: route)) }
        if let id = a.riskSignal {
            lines.append(RoutingDetailLine(label: "Risk signal", value: riskSignalLabel(id)))
        }
        if a.method == .inspection {
            // Inspection status is not a privacy classification, so it gets its own row.
            lines.append(RoutingDetailLine(label: "Privacy", value: "Not classified"))
            lines.append(RoutingDetailLine(label: "Inspection", value: inspectionTitle(a.inspectionGap)))
        } else {
            lines.append(RoutingDetailLine(label: "Privacy", value: privacyBadge(a).text))
        }
        if let rule = a.ruleID { lines.append(RoutingDetailLine(label: "Rule", value: rule)) }
        if let t = a.triage {
            lines.append(RoutingDetailLine(label: "Triage model", value: t.model))
            if let p = t.pNonSensitive { lines.append(RoutingDetailLine(label: "Non-sensitive confidence", value: percent(p))) }
            if let p = t.categoryProbabilities[SystemOneSpec.publicCategory] {
                lines.append(RoutingDetailLine(label: "Public confidence", value: percent(p)))
            }
            lines.append(RoutingDetailLine(label: "Threshold", value: percent(t.threshold)))
            lines.append(RoutingDetailLine(label: "Public floor", value: percent(t.publicFloor)))
        }
        if let c = a.triageCoverage, c.totalChunks > 1 {
            lines.append(RoutingDetailLine(label: "Text assessed",
                                           value: "\(c.assessedChunks) of \(c.totalChunks) sections"))
        }
        if let f = a.triageFailure { lines.append(RoutingDetailLine(label: "Triage", value: triageFailureText(f))) }
        if let e = routing.execution {
            lines.append(RoutingDetailLine(label: "Processed by", value: executionBadge(e).text))
            if let r = e.localReason { lines.append(RoutingDetailLine(label: "Why local", value: localReasonText(r))) }
            if let c = e.cloudFailure { lines.append(RoutingDetailLine(label: "\((e.cloudProvider ?? .gemini).displayName) error",
                                                           value: cloudFailureText(c, provider: e.cloudProvider ?? .gemini))) }
        }
        return lines
    }

    /// How the email reached its privacy decision; nil for old rows and cases with nothing to add.
    public static func routeText(_ a: PrivacyAssessment) -> String? {
        switch (a.method, a.triageTrigger) {
        case (.trustedSender, _): return "Trusted public sender · System One not required"
        case (.systemOne, .trustedSenderRisk?): return "Trusted public sender · Selective System One assessment"
        case (.systemOne, .ambiguousSender?): return "Ambiguous sender · System One assessment"
        case (.systemOne, .sensitiveSender?): return "Sensitive sender domain · System One assessment"
        case (.rule, _): return "Strong private match · System One not required"
        default: return nil
        }
    }

    /// Friendly name for a risk signal id; unknown ids are shown as-is. Never includes matched text.
    public static func riskSignalLabel(_ id: String) -> String {
        switch id {
        case "risk.embedded.conversation": return "Embedded conversation"
        case "risk.medical.identifiable": return "Medical details with identifying information"
        case "risk.identifiable.sensitive": return "Sensitive personal matter with identifying information"
        case "risk.financial.personal": return "Personal financial wording"
        case "risk.medical.personal": return "Personal medical wording"
        default: return id
        }
    }

    /// Tooltip text for the privacy badge: the inspection explanation, else the route for a trusted direct send.
    public static func routingExplanation(for routing: RoutingProvenance) -> String? {
        if let e = inspectionExplanation(for: routing) { return e }
        return routing.assessment.method == .trustedSender ? routeText(routing.assessment) : nil
    }

    /// Short inspection status; the generic text covers an unknown or non-specific gap.
    public static func inspectionTitle(_ gap: InspectionGap?) -> String {
        switch gap {
        case .attachment: return "Attachment not inspected"
        case .nonTextPart: return "Non-text content not inspected"
        case .structureUnavailable: return "Message structure unavailable"
        case .undecodablePart, .partialMessage, nil: return "Content not fully inspected"
        }
    }

    /// Plain-language explanation of an incomplete inspection (an inspection status, not a privacy
    /// classification). A nil gap (old records, unknown reason) gets the generic text.
    public static func inspectionExplanation(_ gap: InspectionGap?) -> String {
        let base = "This email was processed locally because Mail Digest could not fully inspect all of its "
            + "content, such as attachments or non-text message parts. To protect your privacy, it was not "
            + "sent to a cloud provider."
        switch gap {
        case .attachment: return base + " It has an attachment that Mail Digest doesn't read."
        case .nonTextPart:
            return base + " It contains non-text content, such as images or calendar data, that Mail Digest doesn't read."
        case .undecodablePart: return base + " Part of its text couldn't be decoded."
        case .partialMessage: return base + " Only part of this message was downloaded to this Mac."
        case .structureUnavailable:
            return "This email was processed locally because the email source didn't expose enough information "
                + "to verify the complete message structure. To protect your privacy, it was not sent to a "
                + "cloud provider."
        case nil: return base
        }
    }

    /// The explanation for an item's routing when inspection decided it; otherwise nil.
    public static func inspectionExplanation(for routing: RoutingProvenance) -> String? {
        let a = routing.assessment
        guard a.method == .inspection else { return nil }
        return inspectionExplanation(a.inspectionGap)
    }

    /// Why an email ran on this Mac, bucketed from persisted provenance only.
    public enum LocalBucket: String, Sendable, Equatable, CaseIterable {
        case contentNotInspected, privateRule, systemOneSensitive, systemOneLowConfidence
        case cloudDisabled, noCredential, providerUnavailable, acknowledgementRequired, cloudFailed, triageUnavailable
        case notRecorded

        public var label: String {
            switch self {
            case .contentNotInspected: return "not fully inspected"
            case .privateRule: return "private rule"
            case .systemOneSensitive: return "classified sensitive"
            case .systemOneLowConfidence: return "low confidence"
            case .cloudDisabled: return "cloud off"
            case .noCredential: return "no API key"
            case .providerUnavailable: return "provider unavailable"
            case .acknowledgementRequired: return "notice not accepted"
            case .cloudFailed: return "Gemini failed"
            case .triageUnavailable: return "privacy check unavailable"
            case .notRecorded: return "reason not recorded"
            }
        }
    }

    public struct LocalReasonCount: Sendable, Equatable {
        public var bucket: LocalBucket
        public var count: Int
    }

    /// Counts the items that ran locally by reason, largest first (ties in `LocalBucket` order).
    /// Pass only items that finished; a nil entry or one without an execution counts as not recorded.
    /// Cloud items are ignored. System One sensitive results (and old uncertain rows with `pSensitive >= 0.5`) are "classified sensitive".
    public static func localReasonSummary(_ items: [RoutingProvenance?]) -> [LocalReasonCount] {
        var counts: [LocalBucket: Int] = [:]
        for item in items {
            guard let routing = item else { counts[.notRecorded, default: 0] += 1; continue }
            guard let e = routing.execution else { counts[.notRecorded, default: 0] += 1; continue }
            guard e.provider == .local else { continue }
            counts[bucket(for: e.localReason, routing.assessment), default: 0] += 1
        }
        let order = LocalBucket.allCases
        return counts.map { LocalReasonCount(bucket: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count
                : order.firstIndex(of: $0.bucket)! < order.firstIndex(of: $1.bucket)! }
    }

    private static func bucket(for reason: LocalReason?, _ a: PrivacyAssessment) -> LocalBucket {
        switch reason {
        case .cloudDisabled: return .cloudDisabled
        case .acknowledgementRequired: return .acknowledgementRequired
        case .noCredential: return .noCredential
        case .providerUnavailable: return .providerUnavailable
        case .contentNotInspected: return .contentNotInspected
        case .privateContent: return a.method == .systemOne ? .systemOneSensitive : .privateRule
        case .triageUnavailable: return .triageUnavailable
        case .cloudFailed: return .cloudFailed
        case .notEligible:
            guard a.method == .systemOne else { return .notRecorded }
            if let p = a.triage?.pSensitive, p >= 0.5 { return .systemOneSensitive }
            return .systemOneLowConfidence
        case nil: return .notRecorded
        }
    }

    /// "Local: 4 not fully inspected · 2 private rule"; nil when nothing ran locally.
    public static func localReasonSummaryText(_ items: [RoutingProvenance?]) -> String? {
        let parts = localReasonSummary(items).map { "\($0.count) \($0.bucket.label)" }
        return parts.isEmpty ? nil : "Local: " + parts.joined(separator: " · ")
    }

    /// True when `details` shows model scores, so the popover adds `scoreNote`.
    public static func showsScores(_ routing: RoutingProvenance) -> Bool { routing.assessment.triage != nil }

    /// "97%", rounded to a whole percent.
    public static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    public static func localReasonText(_ r: LocalReason) -> String {
        switch r {
        case .cloudDisabled: return "Cloud Digest is off, so it stayed on this Mac."
        case .acknowledgementRequired: return "The Cloud Digest privacy notice has not been accepted, so it stayed on this Mac."
        case .noCredential: return "No Gemini API key is saved, so it stayed on this Mac."
        case .providerUnavailable: return "The cloud provider was unavailable, so it stayed on this Mac."
        case .contentNotInspected:
            return "Content not fully inspected, so it stayed on this Mac."
        case .privateContent: return "It looks private, so it stayed on this Mac."
        case .notEligible: return "It was not confidently public, so it stayed on this Mac."
        case .triageUnavailable: return "The privacy check was unavailable, so it stayed on this Mac."
        case .cloudFailed: return "Gemini could not process it, so this Mac did."
        }
    }

    public static func triageFailureText(_ f: TriageFailure) -> String {
        switch f {
        case .unreachable: return "Ollama was not reachable."
        case .versionTooOld: return "Ollama is too old for System One."
        case .versionUnknown: return "The Ollama version could not be read."
        case .modelMissing: return "The triage model is not installed."
        case .httpError: return "The triage request returned an error."
        case .timedOut: return "The triage request timed out."
        case .malformedResponse: return "The triage response could not be read."
        case .unsupportedModel: return "The triage model is not supported."
        case .contentTooLong: return "Too long to assess completely"
        }
    }

    public static func cloudFailureText(_ code: String, provider: CloudProvider) -> String {
        guard provider == .claudeCode else { return cloudFailureText(code) }
        switch code {
        case "notSignedIn": return "Claude Code is not signed in."
        case "timedOut": return "Claude Code timed out."
        case "malformedResponse": return "Claude Code returned an unreadable response."
        case "launchFailed": return "Claude Code could not be started."
        case "processFailed": return "Claude Code reported an error."
        default: return "Claude Code failed."
        }
    }

    public static func cloudFailureText(_ code: String) -> String {
        switch code {
        case "invalidCredential": return "The API key was rejected."
        case "rateLimited": return "Gemini rate limit reached."
        case "modelUnavailable": return "The Gemini model is unavailable."
        case "timedOut": return "Gemini timed out."
        case "network": return "Network error reaching Gemini."
        case "blocked": return "Gemini blocked the request."
        case "malformedResponse": return "Gemini returned an unreadable response."
        case _ where code.hasPrefix("server"): return "Gemini server error (\(code.dropFirst(6)))."
        default: return "Gemini failed."
        }
    }

    private static func verdictTitle(_ v: PrivacyVerdict) -> String {
        switch v {
        case .private: return "Private"
        case .public: return "Public"
        case .uncertain: return "Uncertain"
        case .notAssessed: return "Not assessed"
        }
    }

    private static func methodTitle(_ m: AssessmentMethod) -> String {
        switch m {
        case .rule: return "Rule"
        case .trustedSender: return "Trusted Sender"
        case .systemOne: return "System One"
        case .inspection: return "Inspection"
        case .cloudOff: return "Cloud off"
        }
    }
}
