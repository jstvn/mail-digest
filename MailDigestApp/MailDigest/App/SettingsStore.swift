import Foundation
import MailDigestCore
import Observation

/// Holds `DigestSettings` and saves them as one JSON blob in UserDefaults on every change.
@MainActor @Observable
final class SettingsStore {
    private static let key = "digestSettings"

    /// The settings; every change is saved and reported through `onChange`.
    var settings: DigestSettings {
        get { stored }
        set {
            // Stamp here, not in an observer: under @Observable, mutating the property inside its own
            // didSet re-enters the setter and recursed without end, hanging the app on any settings change.
            var next = newValue
            next.stampAutoFile(previous: stored, now: .now)
            guard next != stored else { return }
            stored = next
            save()
            onChange?()
        }
    }
    /// Backing storage; observation tracks it, so views reading `settings` still update.
    private var stored: DigestSettings

    /// Called after every change, so the run model can re-check the power rules.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(DigestSettings.self, from: data) {
            var loaded = saved
            // Saved before auto-file kept a start time (Q42): start counting from now, so nothing older is swept.
            loaded.stampAutoFile(previous: saved, now: .now)
            stored = loaded
            // Keep that stamp, so the start time doesn't move forward on every launch.
            if loaded != saved { save() }
        } else {
            stored = DigestSettings()
        }
    }

    /// The daily run time as a date today, for an hour-and-minute `DatePicker`. Only the hour and minute
    /// are stored; the scheduler reads them as wall-clock time in the runner's time zone.
    var runTime: Date {
        get {
            Calendar.current.date(bySettingHour: settings.runHour, minute: settings.runMinute, second: 0, of: .now) ?? .now
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            settings.runHour = parts.hour ?? 6
            settings.runMinute = parts.minute ?? 30
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}
