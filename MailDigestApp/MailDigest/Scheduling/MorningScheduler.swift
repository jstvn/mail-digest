import AppKit
import Foundation

/// Fires the morning run. A 15-minute `NSBackgroundActivityScheduler` check (plus one at launch and on wake)
/// asks the core rule whether the Daily run is due; the rule lives in `MorningSchedule` so it is unit tested.
@MainActor
final class MorningScheduler {
    private let run: DigestRunModel
    private var activity: NSBackgroundActivityScheduler?
    private var wakeObserver: NSObjectProtocol?

    init(run: DigestRunModel) { self.run = run }

    /// Starts checking. Safe to call more than once.
    func start() {
        guard activity == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.pages.justinwang.maildigest.morning")
        scheduler.interval = 15 * 60
        scheduler.tolerance = 5 * 60
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        let run = self.run
        scheduler.schedule { completion in
            // Run on the main actor, where DigestRunModel lives, and report back when done.
            Task { @MainActor in
                await run.runIfDue()
                completion(.finished)
            }
        }
        activity = scheduler

        // Catch up promptly after sleep instead of waiting for the next tolerance window.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await run.runIfDue() }
        }
        Task { await run.runIfDue() }
    }
}
