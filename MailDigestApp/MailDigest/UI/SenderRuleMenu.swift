import MailDigestCore
import SwiftUI

/// Adds a sender to a Settings > Senders list. The review window provides it in the environment, so a card's
/// context menu and the Senders tab edit the same lists through `DigestSettings.add(sender:to:)`.
struct SenderRuleActions {
    let store: SettingsStore

    @MainActor func contains(_ sender: String, in list: SenderList) -> Bool {
        store.settings.contains(sender: sender, in: list)
    }

    @MainActor func add(_ sender: String, to list: SenderList) {
        var settings = store.settings
        if settings.add(sender: sender, to: list) { store.settings = settings }
    }
}

extension EnvironmentValues {
    @Entry var senderRules: SenderRuleActions?
}

/// Add Sender to VIP, Block Sender, Ignore Sender and Trust as Newsletter, for a card's context menu. An item is
/// dimmed when the sender is already on that list. Shows nothing without a usable sender address.
struct SenderRuleMenuItems: View {
    let sender: String?
    @Environment(\.senderRules) private var rules

    var body: some View {
        if let rules, let sender, DigestSettings.isMatchableAddress(sender) {
            Divider()
            ForEach(SenderList.allCases) { list in
                Button(list.menuTitle) { rules.add(sender, to: list) }
                    .disabled(rules.contains(sender, in: list))
            }
        }
    }
}
