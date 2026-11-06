import Foundation
import Testing
@testable import MailDigestCore

private func box(_ account: String, _ name: String, _ kind: MailboxKind, count: Int = 1) -> MailboxInfo {
    MailboxInfo(ref: MailboxRef(account: account, name: name), messageCount: count, unreadCount: 0, kind: kind)
}

@Suite struct MailboxTreeTests {
    private let boxes = [
        box("Outlook", "Sent Items", .sent), box("Outlook", "Inbox", .inbox, count: 253),
        box("iCloud", "Archive", .archive), box("iCloud", "Projects/2026", .custom),
        box("iCloud", "Inbox", .inbox, count: 828), box("iCloud", "Projects", .custom),
        box("iCloud", "Trash", .trash), box("On My Mac", "Local", .custom),
    ]

    @Test func groupsByAccountWithInboxFirstAndNestedFoldersIndented() {
        let accounts = MailboxTree.accounts(boxes, showAll: false)
        #expect(accounts.map(\.account) == ["iCloud", "On My Mac", "Outlook"])
        let icloud = accounts[0].rows
        #expect(icloud.map(\.title) == ["Inbox", "Archive", "Projects", "2026"])
        #expect(icloud.map(\.depth) == [0, 0, 0, 1])
        #expect(icloud[0].info.messageCount == 828)
    }

    @Test func hidesSentDraftsJunkTrashUntilShowAll() {
        let hidden = MailboxTree.accounts(boxes, showAll: false).flatMap(\.rows).map(\.title)
        #expect(!hidden.contains("Trash") && !hidden.contains("Sent Items"))
        let all = MailboxTree.accounts(boxes, showAll: true).flatMap(\.rows).map(\.title)
        #expect(all.contains("Trash") && all.contains("Sent Items"))
    }

    @Test func allInboxesShortcutListsEachAccountsInbox() {
        let refs = MailboxTree.inboxes(boxes)
        #expect(Set(refs.map(\.account)) == ["iCloud", "Outlook"] && refs.count == 2)
    }
}
