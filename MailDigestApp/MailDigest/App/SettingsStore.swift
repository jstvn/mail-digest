import Foundation
import MailDigestCore
import Observation

/// Holds `DigestSettings` and saves them as one JSON blob in UserDefaults on every change.
@MainActor @Observable
final class SettingsStore {
    private static let key = "digestSettings"

    var settings: DigestSettings {
        didSet { if settings != oldValue { save() } }
    }

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

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
