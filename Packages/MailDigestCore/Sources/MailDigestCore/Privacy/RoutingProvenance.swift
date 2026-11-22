import Foundation

/// Outcome of the privacy assessment for one email.
public enum PrivacyVerdict: String, Codable, Sendable, Equatable {
    case `private`, `public`, uncertain, notAssessed
}

/// What produced the verdict.
public enum AssessmentMethod: String, Codable, Sendable, Equatable {
    case rule, trustedSender, systemOne, inspection, cloudOff
}

/// Why System One triage did not yield scores. Codes only, never message text.
/// Below-threshold scores are a valid `uncertain` outcome, not a failure.
public enum TriageFailure: String, Codable, Sendable, Equatable, Error {
    case unreachable, versionTooOld, versionUnknown, modelMissing, httpError, timedOut
    case malformedResponse, unsupportedModel
    /// The text needs more chunks than the triage budget allows, so it could not be assessed completely.
    case contentTooLong
}

/// Raw System One scores plus the thresholds in force at decision time.
public struct TriageScores: Codable, Sendable, Equatable {
    public var model: String
    public var pSensitive: Double?
    public var pNonSensitive: Double?
    public var categoryProbabilities: [String: Double]
    public var threshold: Double
    public var publicFloor: Double

    public init(model: String, pSensitive: Double?, pNonSensitive: Double?,
                categoryProbabilities: [String: Double], threshold: Double, publicFloor: Double) {
        self.model = model
        self.pSensitive = pSensitive
        self.pNonSensitive = pNonSensitive
        self.categoryProbabilities = categoryProbabilities
        self.threshold = threshold
        self.publicFloor = publicFloor
    }
}

/// How much of the message text System One assessed. Counts only, never text.
public struct TriageCoverage: Codable, Sendable, Equatable {
    public var assessedChunks: Int
    public var totalChunks: Int
    public var isComplete: Bool { totalChunks > 0 && assessedChunks == totalChunks }

    public init(assessedChunks: Int, totalChunks: Int) {
        self.assessedChunks = assessedChunks
        self.totalChunks = totalChunks
    }
}

/// The privacy decision, persisted as soon as it is made (before generation).
public struct PrivacyAssessment: Codable, Sendable, Equatable {
    public var verdict: PrivacyVerdict
    public var method: AssessmentMethod
    /// Stable rule id such as `kw.otp`; never the matched text.
    public var ruleID: String?
    public var triage: TriageScores?
    public var triageFailure: TriageFailure?
    public var assessedAt: Date
    /// Why content was not fully inspected; set only for `.inspection` assessments. Old records decode as nil.
    public var inspectionGap: InspectionGap?
    /// Why System One was consulted (or, for a trusted sender, not needed). Old records decode as nil.
    public var triageTrigger: TriageTrigger?
    /// Contextual risk signal id (for example `risk.medical.identifiable`); never matched text.
    public var riskSignal: String?
    /// How much of the text System One read. Old records decode as nil (assessed from truncated input).
    public var triageCoverage: TriageCoverage?

    public init(verdict: PrivacyVerdict, method: AssessmentMethod, ruleID: String? = nil,
                triage: TriageScores? = nil, triageFailure: TriageFailure? = nil, assessedAt: Date,
                inspectionGap: InspectionGap? = nil, triageTrigger: TriageTrigger? = nil,
                riskSignal: String? = nil, triageCoverage: TriageCoverage? = nil) {
        self.triageCoverage = triageCoverage
        self.triageTrigger = triageTrigger
        self.riskSignal = riskSignal
        self.inspectionGap = inspectionGap
        self.verdict = verdict
        self.method = method
        self.ruleID = ruleID
        self.triage = triage
        self.triageFailure = triageFailure
        self.assessedAt = assessedAt
    }
}

public enum ExecutionProvider: String, Codable, Sendable, Equatable {
    case local, cloud
}

/// Why an email was processed locally rather than by Gemini.
public enum LocalReason: String, Codable, Sendable, Equatable {
    case cloudDisabled, acknowledgementRequired, noCredential, contentNotInspected
    /// The selected provider's tool is missing, signed out or too old (Q93).
    case providerUnavailable
    case privateContent, notEligible, triageUnavailable, cloudFailed
}

/// The final executor for an email.
public struct ExecutionRecord: Codable, Sendable, Equatable {
    public var provider: ExecutionProvider
    public var model: String
    public var cloudAttempted: Bool
    public var localReason: LocalReason?
    /// Error class code only (for example `rateLimited`), never message text.
    public var cloudFailure: String?
    /// The provider that was tried; nil on rows written before Q93, which were always Gemini.
    public var cloudProvider: CloudProvider?
    public var startedAt: Date
    public var finishedAt: Date

    public init(provider: ExecutionProvider, model: String, cloudAttempted: Bool, localReason: LocalReason? = nil,
                cloudFailure: String? = nil, cloudProvider: CloudProvider? = nil,
                startedAt: Date, finishedAt: Date) {
        self.cloudProvider = cloudProvider
        self.provider = provider
        self.model = model
        self.cloudAttempted = cloudAttempted
        self.localReason = localReason
        self.cloudFailure = cloudFailure
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Persisted as `job_item.routing` JSON.
public struct RoutingProvenance: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var assessment: PrivacyAssessment
    public var execution: ExecutionRecord?

    public init(schemaVersion: Int = RoutingProvenance.currentSchemaVersion,
                assessment: PrivacyAssessment, execution: ExecutionRecord? = nil) {
        self.schemaVersion = schemaVersion
        self.assessment = assessment
        self.execution = execution
    }
}
