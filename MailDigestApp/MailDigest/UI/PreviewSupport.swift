#if DEBUG
import MailDigestCore
import SwiftUI

/// Builders for SwiftUI previews. Everything comes from the core sample fixtures; nothing reads Mail,
/// Ollama or the database.
@MainActor
enum PreviewSupport {
    static let sampleState = ReviewState(digest: PreviewFixtures.digest)

    static func review(_ state: ReviewState? = sampleState, writer: (any ReminderWriter)? = RecordingReminderWriter()) -> ReviewViewModel {
        ReviewViewModel(preview: state, emails: PreviewFixtures.emails, writer: writer)
    }

    static func run(review: ReviewViewModel = review(), progress: JobProgress? = nil, banner: String? = nil,
                    failedJobID: UUID? = nil, foundNothing: Bool = false) -> DigestRunModel {
        DigestRunModel(preview: SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
                       review: review, progress: progress, banner: banner, failedJobID: failedJobID,
                       lastRunAt: PreviewFixtures.now, lastRunFoundNothing: foundNothing,
                       lastRunSummary: "Last run 6:45 AM · 4 suggestions · 23 emails")
    }

    static let fastLocal = MailAccessStatus(fullDiskAccess: .granted, automation: .granted)
    static let fallback = MailAccessStatus(fullDiskAccess: .denied, automation: .granted)
    static let automationDenied = MailAccessStatus(fullDiskAccess: .denied, automation: .denied)
}

@MainActor private func panel(_ run: DigestRunModel, status: MailAccessStatus = PreviewSupport.fastLocal) -> some View {
    ReviewPanelView(run: run, access: MailAccessModel(preview: status))
        .frame(width: 720, height: 640)
}

#Preview("Panel · digest") { panel(PreviewSupport.run()) }

#Preview("Panel · running") {
    panel(PreviewSupport.run(progress: PreviewFixtures.runningProgress))
}

#Preview("Panel · paused") {
    panel(PreviewSupport.run(progress: PreviewFixtures.pausedProgress))
}

#Preview("Panel · Ollama down") {
    panel(PreviewSupport.run(banner: "Ollama isn't running. Start Ollama, or run `ollama pull qwen3:4b`.",
                             failedJobID: PreviewFixtures.jobID))
}

#Preview("Panel · Full Disk Access unavailable") {
    panel(PreviewSupport.run(), status: PreviewSupport.fallback)
}

#Preview("Panel · Mail Automation denied") {
    panel(PreviewSupport.run(), status: PreviewSupport.automationDenied)
}

#Preview("Panel · Reminders unavailable") {
    panel(PreviewSupport.run(review: PreviewSupport.review(writer: nil)))
}

#Preview("Panel · no new mail") {
    let review = PreviewSupport.review(ReviewState(digest: PreviewFixtures.emptyDigest))
    return panel(PreviewSupport.run(review: review, foundNothing: true))
}

#Preview("Panel · partial failure") {
    // The sample digest already lists a failed email under Skipped with its reason.
    panel(PreviewSupport.run())
}

#Preview("Menu bar") {
    MenuBarView(run: PreviewSupport.run(progress: PreviewFixtures.runningProgress),
                access: MailAccessModel(preview: PreviewSupport.fastLocal))
}

#Preview("Settings") {
    SettingsView(run: PreviewSupport.run())
}
#endif
