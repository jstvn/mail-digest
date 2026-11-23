import Foundation

/// Everything the router needs to know about cloud routing for one email. Built by the app
/// (which owns credentials and caches clients per job); Core never reads credentials.
public struct CloudRoutingConfig: Sendable {
    /// The selected provider's extractor. `nil` means effective cloud off (toggle off, no acknowledgement,
    /// or the provider is not ready).
    public var cloudExtractor: (any EmailExtractor)?
    /// Fallback model label when the extractor does not report which model answered.
    public var cloudModel: String
    /// Which provider `cloudExtractor` talks to; recorded so fallback labels name it.
    public var cloudProvider: CloudProvider
    /// Why cloud is off; used as the local reason. Ignored when `cloudExtractor` is set.
    public var offReason: LocalReason?
    /// System One client; `nil` while cloud is on means triage is unavailable.
    public var triage: (any SystemOneClient)?
    public var triageModel: String
    public var privacyThreshold: Double

    public init(cloudExtractor: (any EmailExtractor)?, cloudModel: String, offReason: LocalReason?,
                triage: (any SystemOneClient)?, triageModel: String, privacyThreshold: Double,
                cloudProvider: CloudProvider = .gemini) {
        self.cloudProvider = cloudProvider
        self.cloudExtractor = cloudExtractor
        self.cloudModel = cloudModel
        self.offReason = offReason
        self.triage = triage
        self.triageModel = triageModel
        self.privacyThreshold = privacyThreshold
    }

    /// Cloud effectively off; every email stays local.
    public static func localOnly(reason: LocalReason) -> CloudRoutingConfig {
        CloudRoutingConfig(cloudExtractor: nil, cloudModel: "", offReason: reason, triage: nil,
                           triageModel: "", privacyThreshold: SystemOneSpec.thresholdRange.upperBound)
    }
}

/// Thrown when the final (local) extraction fails. Carries the provenance of the failed attempt so the
/// runner can persist it; `underlying` keeps the original error semantics.
public struct RoutedExecutionFailure: Error, Sendable {
    public var underlying: any Error
    public var execution: ExecutionRecord

    public init(underlying: any Error, execution: ExecutionRecord) {
        self.underlying = underlying
        self.execution = execution
    }
}

/// Decides, per email, whether Gemini or local Qwen3 runs the extraction. Fails closed: Gemini is used
/// only for fully inspected mail with an explicit `public` verdict.
public struct DigestRouter: Sendable {
    public let clock: any Clock
    private let preFilter = PrivacyPreFilter()

    public init(clock: any Clock) { self.clock = clock }

    /// Step 1: the privacy assessment. Throws only `CancellationError`.
    public func assess(_ email: EmailMessage, stored: PrivacyAssessment?,
                       config: CloudRoutingConfig) async throws -> PrivacyAssessment {
        try Task.checkCancellation()
        let now = clock.now()
        // Pre-filter sees the full uncleaned text. It is cheap and deterministic, so it always runs:
        // a private rule wins even over a stored decision (for example after the rule list grows).
        let input = PrivacyInput(sender: email.sender, subject: email.subject, body: email.body,
                                 headers: email.headers, inspection: email.contentInspection)
        let verdict = preFilter.classify(input)
        if case .private(let id) = verdict {
            if let stored, stored.verdict == .private, stored.method == .rule, stored.ruleID == id { return stored }
            return PrivacyAssessment(verdict: .private, method: .rule, ruleID: id, assessedAt: now)
        }
        // Reuse a stored decision on resume/retry (no re-triage); a cloud-off placeholder is re-assessed.
        // A stored trusted-sender result never bypasses a risk signal that fires today.
        if let stored, stored.method != .cloudOff {
            var isPublic = false
            if case .public = verdict { isPublic = true }
            // A stored System One "public" made under the old truncated-input policy (no or partial
            // coverage) is not trusted; it is assessed again over the whole text.
            let truncatedPublic = stored.method == .systemOne && stored.verdict == .public
                && stored.triageCoverage?.isComplete != true
            if !(stored.method == .trustedSender && !isPublic) && !truncatedPublic { return stored }
        }
        if config.cloudExtractor == nil {
            if case .public(let id) = verdict {
                return PrivacyAssessment(verdict: .public, method: .trustedSender, ruleID: id, assessedAt: now)
            }
            return PrivacyAssessment(verdict: .notAssessed, method: .cloudOff, assessedAt: now)
        }
        guard email.contentInspection == .complete else {
            return PrivacyAssessment(verdict: .notAssessed, method: .inspection, assessedAt: now,
                                    inspectionGap: email.inspectionGap)
        }
        if case .public(let id) = verdict {
            return PrivacyAssessment(verdict: .public, method: .trustedSender, ruleID: id, assessedAt: now)
        }
        var trigger: TriageTrigger?
        var signal: String?
        if case .needsTriage(let t, let s) = verdict { trigger = t; signal = s }
        func uncertain(_ failure: TriageFailure?, coverage: TriageCoverage? = nil) -> PrivacyAssessment {
            PrivacyAssessment(verdict: .uncertain, method: .systemOne, triageFailure: failure, assessedAt: now,
                              triageTrigger: trigger, riskSignal: signal, triageCoverage: coverage)
        }
        guard let triage = config.triage else { return uncertain(.unreachable) }
        // Plan once: every chunk of the text is assessed, or none is (nothing is silently truncated).
        let plan = TriageInputBuilder().plan(email)
        guard plan.isWithinBudget else {
            return uncertain(.contentTooLong, coverage: TriageCoverage(assessedChunks: 0, totalChunks: plan.totalChunks))
        }
        let total = plan.totalChunks
        var finished = 0
        do {
            if let failure = try await triage.preflight(model: config.triageModel) {
                return uncertain(failure, coverage: TriageCoverage(assessedChunks: 0, totalChunks: total))
            }
            let evaluator = TriageEvaluator()
            // Q95/Q96: only an unknown sender with no risk signal and bulk evidence (List-Unsubscribe, or a
            // verified Hide My Email relay that is not a reply) is bulk mail.
            let waiver: PublicFloorWaiver? = trigger == .ambiguousSender && signal == nil
                ? PrivacyPreFilter.bulkEvidence(sender: email.sender, subject: email.subject, headers: email.headers)
                : nil
            var worst: PrivacyAssessment?
            for input in plan.inputs {
                try Task.checkCancellation()
                let scores = try await triage.assess(input, model: config.triageModel)
                var result = evaluator.evaluate(scores, model: config.triageModel,
                                                threshold: config.privacyThreshold, publicFloorWaiver: waiver,
                                                assessedAt: clock.now())
                finished += 1
                result.triageTrigger = trigger
                result.riskSignal = signal
                result.triageCoverage = TriageCoverage(assessedChunks: finished, totalChunks: total)
                // The first chunk that is not confidently public decides; later chunks need not be read.
                if result.verdict != .public { return result }
                if worst == nil || (result.triage?.pNonSensitive ?? 0) < (worst?.triage?.pNonSensitive ?? 0) {
                    worst = result
                }
            }
            // Fail closed: "public" is only ever returned for a fully assessed message.
            guard var final = worst, finished == total else {
                return uncertain(nil, coverage: TriageCoverage(assessedChunks: finished, totalChunks: total))
            }
            final.triageCoverage = TriageCoverage(assessedChunks: finished, totalChunks: total)
            return final
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TriageFailure {
            return uncertain(failure, coverage: TriageCoverage(assessedChunks: finished, totalChunks: total))
        } catch {
            return uncertain(.unreachable, coverage: TriageCoverage(assessedChunks: finished, totalChunks: total))
        }
    }

    /// Step 2: run the extraction. `email` is the cleaned message. Gemini is re-checked here
    /// independently of how the assessment was produced.
    public func execute(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool, today: Date,
                        timeZone: TimeZone, assessment: PrivacyAssessment, config: CloudRoutingConfig,
                        local: any LLMClient, localModel: String) async throws -> (ExtractionResult, ExecutionRecord) {
        let started = clock.now()
        var cloudAttempted = false
        var cloudFailure: String?
        var reason: LocalReason

        if let cloud = config.cloudExtractor {
            if email.contentInspection != .complete {
                reason = .contentNotInspected
            } else {
                switch assessment.verdict {
                case .public:
                    reason = .cloudFailed // only used if the call below fails
                    cloudAttempted = true
                    do {
                        let result: ExtractionResult
                        var reported: String?
                        if let c = cloud as? any ReportedModelExtractor {
                            (result, reported) = try await c.extractReportingModel(
                                email, tier: tier, trustedNewsletter: trustedNewsletter, today: today, timeZone: timeZone)
                        } else {
                            result = try await cloud.extract(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                                             today: today, timeZone: timeZone)
                        }
                        return (result, ExecutionRecord(provider: .cloud, model: reported ?? config.cloudModel,
                                                        cloudAttempted: true, cloudProvider: config.cloudProvider,
                                                        startedAt: started, finishedAt: clock.now()))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        cloudFailure = (error as? GeminiError)?.code ?? (error as? ClaudeCodeError)?.code ?? "unknown"
                    }
                case .private: reason = .privateContent
                case .uncertain: reason = assessment.triageFailure != nil ? .triageUnavailable : .notEligible
                case .notAssessed: reason = .notEligible
                }
            }
        } else {
            reason = config.offReason ?? .cloudDisabled
        }

        func record() -> ExecutionRecord {
            ExecutionRecord(provider: .local, model: localModel, cloudAttempted: cloudAttempted,
                            localReason: reason, cloudFailure: cloudFailure,
                            cloudProvider: cloudAttempted ? config.cloudProvider : nil, startedAt: started,
                            finishedAt: clock.now())
        }
        do {
            let result = try await local.extract(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                                 today: today, timeZone: timeZone)
            return (result, record())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RoutedExecutionFailure(underlying: error, execution: record())
        }
    }
}
