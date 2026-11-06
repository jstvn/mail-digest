import Foundation
import MailDigestCore
import Observation

/// Holds `DigestSettings` and saves them as one JSON blob in UserDefaults on every change.
@MainActor @Observable
final class SettingsStore {
    private static let key = "digestSettings"

    var settings: DigestSettings {
        didSet { if settings != oldValue { save(); onChange?() } }
    }

    /// Called after every change, so the run model can re-check the power rules.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(DigestSettings.self, from: data) {
            settings = saved
        } else {
            settings = DigestSettings()
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
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
