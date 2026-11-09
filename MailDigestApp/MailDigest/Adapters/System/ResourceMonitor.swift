import AppKit
import Foundation
import IOKit.ps
import MailDigestCore

/// Watches power source, Low Power Mode, thermal state and quiet-hour boundaries and reports changes.
/// It only gathers facts; `ResourcePolicy` (core) decides what they mean for a job.
@MainActor
final class ResourceMonitor {
    private(set) var conditions = ResourceConditions()
    /// Called after any watched value changed, on the main actor.
    var onChange: (() -> Void)?
    /// Called after the Mac woke or a boundary timer fired. Unlike `onChange` it fires even when the
    /// readings look the same, because a timer due during sleep may never have fired.
    var onTimeMayHaveChanged: (() -> Void)?

    private var powerSource: CFRunLoopSource?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var boundaryTimer: Timer?

    init() {
        conditions = Self.read()
    }

    /// Starts watching. Safe to call once; the monitor lives as long as the app.
    func start() {
        guard powerSource == nil else { return }
        // IOKit tells us when the power source changes (plug, unplug). The callback is a C function, so it
        // gets `self` through the context pointer and hops to the main actor, where the run loop source runs.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<ResourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange)
        observe(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification)
        // A wake can cross a quiet-hours boundary the timer slept through.
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onTimeMayHaveChanged?()
            }
        }
        observers.append((NSWorkspace.shared.notificationCenter, wake))
        refresh()
    }

    /// Re-reads everything and reports a change if any value differs.
    func refresh() {
        let latest = Self.read()
        guard latest != conditions else { return }
        conditions = latest
        onChange?()
    }

    /// Arms a one-shot timer for the next quiet-hours boundary (or cancels it when nil).
    func scheduleBoundary(at date: Date?) {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onTimeMayHaveChanged?() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append((center, token))
    }

    private static func read() -> ResourceConditions {
        ResourceConditions(onBattery: isOnBattery(),
                           lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: level(ProcessInfo.processInfo.thermalState))
    }

    /// Desktop Macs report "AC Power", so they are never on battery.
    private static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    private static func level(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
