import AppKit
import CoreServices
import Foundation
import MailDigestCore
import OSLog

/// Probes Full Disk Access and Mail Automation without prompting (except `requestAutomation`).
struct MailPermissionProbe: Sendable {
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "permissions")
    private static let mailBundleID = "com.apple.mail"

    /// Actually opens Mail's store, because there is no public API to query Full Disk Access.
    func fullDiskAccess() -> FullDiskAccessState {
        do {
            _ = try MailStoreLocator().locate()
            return .granted
        } catch {
            switch MailStoreError.from(error) {
            case .permissionDenied: return .denied
            case .notFound: return .mailDataMissing
            case .unsupportedSchema: return .unsupportedStore
            case .busy: return .busy
            case .other: return .unknown
            }
        }
    }

    /// Asks the system for Automation consent state without showing the prompt. Blocking.
    func automation() -> AutomationState {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailBundleID).isEmpty
        guard running else { return .mailNotRunning }
        let bundleID = Array(Self.mailBundleID.utf8CString)
        var target = AEAddressDesc()
        let created = bundleID.withUnsafeBufferPointer { buf in
            AECreateDesc(DescType(typeApplicationBundleID), buf.baseAddress, buf.count - 1, &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .mailNotRunning
        default: return .unknown
        }
    }

    /// Probes both permissions off the main actor and logs the result.
    func status() async -> MailAccessStatus {
        let result = await Task.detached(priority: .userInitiated) {
            MailAccessStatus(fullDiskAccess: self.fullDiskAccess(), automation: self.automation())
        }.value
        Self.logProbe(result)
        return result
    }

    /// Triggers the Automation prompt with the harmless `CheckMail.js`, then re-probes.
    func requestAutomation() async -> AutomationState {
        do {
            try await AppleScriptMailSource().checkForNewMail()
        } catch OsascriptError.automationDenied {
            Self.log.notice("requestAutomation result=denied")
            return .denied
        } catch {
            Self.log.notice("requestAutomation failed")
        }
        return await status().automation
    }

    private static func logProbe(_ s: MailAccessStatus) {
        let ppid = getppid()
        let parent = NSRunningApplication(processIdentifier: ppid)?.bundleIdentifier ?? parentProcessName(ppid)
        let app = Bundle.main.bundleURL.lastPathComponent
        log.notice("probe fda=\(s.fullDiskAccess.rawValue, privacy: .public) automation=\(s.automation.rawValue, privacy: .public) mode=\(String(describing: s.mode), privacy: .public) launchedFrom=\(parent, privacy: .public) app=\(app, privacy: .public)")
    }

    private static func parentProcessName(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &name, UInt32(name.count))
        guard n > 0 else { return "unknown" }
        return String(decoding: name.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
