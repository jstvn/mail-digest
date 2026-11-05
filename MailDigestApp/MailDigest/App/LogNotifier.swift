import MailDigestCore
import OSLog

/// Placeholder notifier until user notifications are built. Logs only that a post happened,
/// never the text, because it can contain email subjects.
struct LogNotifier: Notifier {
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "run")

    func post(_ message: String) async {
        Self.log.notice("notification would be posted")
    }
}
