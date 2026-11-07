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
        case (.uncertain, .systemOne): return RoutingBadge(text: "Uncertain · System One", tone: .uncertain)
        case (.notAssessed, .inspection):
            return RoutingBadge(text: "Local only · Content not fully inspected", tone: .uncertain)
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
            return RoutingBadge(text: "Gemini failed → Local \(model)", tone: .fallback)
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
        return id
    }

    /// Popover lines for one item's routing, in reading order. Deterministic results list the rule, never a score.
    public static func details(_ routing: RoutingProvenance) -> [RoutingDetailLine] {
        var lines: [RoutingDetailLine] = []
        let a = routing.assessment
        lines.append(RoutingDetailLine(label: "Privacy", value: privacyBadge(a).text))
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
        if let f = a.triageFailure { lines.append(RoutingDetailLine(label: "Triage", value: triageFailureText(f))) }
        if let e = routing.execution {
            lines.append(RoutingDetailLine(label: "Processed by", value: executionBadge(e).text))
            if let r = e.localReason { lines.append(RoutingDetailLine(label: "Why local", value: localReasonText(r))) }
            if let c = e.cloudFailure { lines.append(RoutingDetailLine(label: "Gemini error", value: cloudFailureText(c))) }
        }
        return lines
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
        case .contentNotInspected:
            return "Content not fully inspected (attachments or non-text parts), so it stayed on this Mac."
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
