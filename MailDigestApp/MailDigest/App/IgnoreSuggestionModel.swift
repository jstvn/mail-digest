import Foundation
import MailDigestCore
import Observation

/// The learned-ignore-rule notice (Q36): offers to ignore a sender the user keeps dismissing. Shared by the
/// latest-digest panel and the cross-digest coordinator so there is one notice and one snooze list.
@MainActor @Observable
final class IgnoreSuggestionModel {
    /// A sender the user keeps dismissing, offered as an Ignored sender. One at a time.
    private(set) var suggestion: IgnoreSuggestion?
    /// The ignore-rule notice reads and writes the sender lists here.
    @ObservationIgnored var settingsStore: SettingsStore?

    /// Addresses the user chose "Not Now" for; forgotten at relaunch.
    @ObservationIgnored private var snoozed: Set<String> = []
    /// Display names seen for addresses, so the notice can say "Ray White" instead of an address.
    @ObservationIgnored private var names: [String: String] = [:]

    init(suggestion: IgnoreSuggestion? = nil) { self.suggestion = suggestion }

    /// Checks these senders' dismissals and shows the first match, unless a notice is already showing.
    func evaluate(senders: Set<String>, store: any DigestStore) async {
        guard let settings = settingsStore?.settings, suggestion == nil else { return }
        for sender in senders { names[MailFilter.address(from: sender)] = ReviewPresentation.senderName(sender) }
        for address in Set(senders.map(MailFilter.address(from:))).subtracting(snoozed).sorted() {
            guard let decisions = try? await store.decisions(for: address),
                  let found = IgnoreRuleSuggester.suggestion(for: address, decisions: decisions, settings: settings)
            else { continue }
            suggestion = found
            return
        }
    }

    /// A name for the suggested sender: the display name when one was seen, otherwise the address.
    var displayName: String? {
        guard let suggestion else { return nil }
        return names[suggestion.sender] ?? suggestion.sender
    }

    /// "Ignore Sender": the only path that adds to the Ignored list.
    func accept() {
        guard let suggestion, let store = settingsStore else { return }
        // The same call as Settings > Senders and the card context menus.
        var settings = store.settings
        if settings.add(sender: suggestion.sender, to: .ignored) { store.settings = settings }
        self.suggestion = nil
    }

    /// "Not Now": hides the notice until the app is relaunched.
    func snooze() {
        if let suggestion { snoozed.insert(suggestion.sender) }
        suggestion = nil
    }

    /// "Don't Ask Again": remembers the sender so it is never suggested again.
    func decline() {
        guard let suggestion, let store = settingsStore else { return }
        if !store.settings.declinedIgnoreSuggestions.contains(suggestion.sender) {
            store.settings.declinedIgnoreSuggestions.append(suggestion.sender)
        }
        self.suggestion = nil
    }
}
