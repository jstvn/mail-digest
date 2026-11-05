import Foundation
import MailDigestCore
import Observation
import OSLog

/// Drives "Run Now" and the mailbox list. UI state lives here on the main actor;
/// mail, model and store work happens in the Core types, off the main actor.
@MainActor @Observable
final class DigestRunModel {
    private(set) var mailboxes: [MailboxInfo] = []
    private(set) var isLoadingMailboxes = false
    private(set) var mailboxError: String?

    private(set) var isRunning = false
    private(set) var progressText: String?
    private(set) var lastRunSummary: String?
    private(set) var banner: String?

    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "run")

    @ObservationIgnored private let source = AppleMailSource()
    @ObservationIgnored private let llm = OllamaClient()
    /// Interim in-memory store; T12 replaces it with the GRDB store, so results are lost on quit.
    @ObservationIgnored private let store = InMemoryDigestStore()
    @ObservationIgnored private let notifier = LogNotifier()
    @ObservationIgnored private let clock = SystemClock()
    @ObservationIgnored private var runner: JobRunner?
    @ObservationIgnored private var runnerInboxes: Set<MailboxRef> = []
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    /// Daily runs read every inbox.
    var inboxCount: Int { mailboxes.filter { $0.kind == .inbox }.count }

    func loadMailboxes() async {
        guard !isLoadingMailboxes else { return }
        isLoadingMailboxes = true
        mailboxError = nil
        defer { isLoadingMailboxes = false }
        do {
            mailboxes = try await source.listMailboxes()
        } catch {
            mailboxError = Self.message(for: error)
        }
    }

    func runNow() async {
        guard !isRunning else { return }
        isRunning = true
        banner = nil
        progressText = "Starting…"
        defer { isRunning = false; progressText = nil }

        // Check Ollama first so a down server doesn't cost a mail listing (Q25).
        do {
            try await llm.healthCheck()
        } catch let error as LLMError {
            banner = error.userMessage
            return
        } catch {
            banner = "Ollama is not reachable. Start Ollama, or run `ollama pull qwen3:4b`."
            return
        }

        if mailboxes.isEmpty { await loadMailboxes() }
        if let mailboxError {
            banner = mailboxError
            return
        }
        let inboxes = mailboxes.filter { $0.kind == .inbox }.map(\.ref)
        guard !inboxes.isEmpty else {
            banner = "No inboxes found in Mail."
            return
        }

        let runner = runner(for: inboxes)
        do {
            try await runner.startDaily()
            await runner.waitUntilIdle()
        } catch {
            banner = Self.message(for: error)
            return
        }
        await summariseLastRun()
    }

    // MARK: Helpers

    /// Creates the runner once and only recreates it when the inbox set changes.
    private func runner(for inboxes: [MailboxRef]) -> JobRunner {
        let set = Set(inboxes)
        if let runner, set == runnerInboxes { return runner }
        progressTask?.cancel()
        let new = JobRunner(source: source, llm: llm, store: store, notifier: notifier, clock: clock,
                            settings: RunnerSettings(dailyMailboxes: inboxes))
        runner = new
        runnerInboxes = set
        progressTask = Task { [weak self] in
            for await update in new.progress {
                self?.apply(update)
            }
        }
        return new
    }

    private func apply(_ update: JobProgress) {
        guard isRunning else { return }
        switch update.state {
        case .listing:
            progressText = "Looking for new mail…"
        case .running, .pausing, .paused, .stopping:
            var text = "Reading \(min(update.done + 1, max(update.total, 1))) of \(update.total) emails"
            if let eta = update.eta, eta >= 60 {
                text += " · about \(Int((eta / 60).rounded(.up))) min left"
            }
            progressText = text
        default:
            break
        }
    }

    private func summariseLastRun() async {
        do {
            guard let digest = try await store.latestDigest() else {
                lastRunSummary = "Inbox zero for today"
                Self.log.notice("run finished: no digest")
                return
            }
            let time = digest.createdAt.formatted(date: .omitted, time: .shortened)
            if digest.emailCount == 0 {
                lastRunSummary = "Inbox zero for today · last run \(time)"
            } else {
                lastRunSummary = "Last run \(time) · \(digest.suggestions.count) suggestions · \(digest.emailCount) emails"
            }

            // Counts only: no subjects, senders, bodies or IDs go to the log.
            let items = try await store.items(job: digest.id)
            let queued = Set(items.map(\.messageID))
            let failed = items.filter { $0.state == .failed }.count
            let canonical = digest.info.allSatisfy { queued.contains($0.emailID) }
                && digest.suggestions.allSatisfy { queued.contains($0.emailID) }
            Self.log.notice("run finished: emails=\(digest.emailCount, privacy: .public) info=\(digest.info.count, privacy: .public) suggestions=\(digest.suggestions.count, privacy: .public) skipped=\(digest.skipped.count, privacy: .public) failed=\(failed, privacy: .public) idsCanonical=\(canonical, privacy: .public)")
        } catch {
            banner = "Could not read the run result."
        }
    }

    private static func message(for error: Error) -> String {
        if case OsascriptError.automationDenied = error {
            return "Mail automation is off. Open Mail Access to allow it."
        }
        return "Could not read Mail. Open Mail Access to check permissions."
    }
}
