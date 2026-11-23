import AppKit

/// Starts the Ollama app for the menu's "Start Ollama". A thin adapter: it neither waits for the server
/// nor retries the job, and it leaves the menu bar panel open.
@MainActor
enum OllamaLauncher {
    private static let bundleID = "com.electron.ollama"
    private static let downloadURL = URL(string: "https://ollama.com/download")!

    /// Whether the Ollama app is installed on this Mac.
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// Opens ollama.com/download in the browser.
    static func openDownloadPage() { NSWorkspace.shared.open(downloadURL) }

    static func start() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // Not installed: send the user to the download page.
            openDownloadPage()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Ollama lives in the menu bar; keep focus where the user is.
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
    }
}
