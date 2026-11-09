import Foundation
import Testing
@testable import MailDigestCore

@Suite struct MailAccessPresentationTests {
    @Test func headerStates() {
        func header(_ f: FullDiskAccessState, _ a: AutomationState) -> MailAccessPresentation.Header {
            MailAccessPresentation(MailAccessStatus(fullDiskAccess: f, automation: a)).header
        }
        #expect(header(.granted, .granted) == .ready)
        #expect(header(.denied, .granted) == .slowerMode)
        #expect(header(.denied, .notDetermined) == .slowerMode)
        #expect(header(.granted, .denied) == .automationOff)
        #expect(header(.denied, .denied) == .unavailable)
        #expect(MailAccessPresentation.Header.ready.symbol == "checkmark.shield")
        #expect(MailAccessPresentation.Header.slowerMode.title == "Running in Slower Mode")
    }

    @Test func rowsAndFootnote() {
        let ready = MailAccessPresentation(MailAccessStatus(fullDiskAccess: .granted, automation: .granted))
        #expect(ready.fullDiskAccessText == "On" && ready.automationText == "Allowed")
        #expect(!ready.showsGrantAccess && !ready.showsPermissionFootnote)
        #expect(ready.automationAction == .none)
        let off = MailAccessPresentation(MailAccessStatus(fullDiskAccess: .denied, automation: .denied))
        #expect(off.fullDiskAccessText == "Off" && off.showsGrantAccess && off.showsPermissionFootnote)
        #expect(off.automationText == "Not Allowed" && off.automationAction == .openSettings)
        let fresh = MailAccessPresentation(MailAccessStatus(fullDiskAccess: .mailDataMissing, automation: .notDetermined))
        #expect(!fresh.showsGrantAccess && fresh.automationAction == .request)
    }

    // MARK: Daily selection

    static func box(_ account: String, _ name: String, _ kind: MailboxKind, _ count: Int = 10) -> MailboxInfo {
        MailboxInfo(ref: MailboxRef(account: account, name: name), messageCount: count, unreadCount: 0, kind: kind)
    }
    static let icloud = box("iCloud", "INBOX", .inbox)
    static let outlook = box("Outlook", "Inbox", .inbox)
    static let archive = box("iCloud", "Archive", .archive)
    static let available = [icloud, outlook, archive]

    @Test func noStoredChoiceTicksEveryInbox() {
        let set = DailyMailboxSelection.effective(stored: [], available: Self.available)
        #expect(set == [Self.icloud.ref, Self.outlook.ref])
    }

    @Test func explicitChoiceIsKept() {
        let set = DailyMailboxSelection.effective(stored: [Self.archive.ref], available: Self.available)
        #expect(set == [Self.archive.ref])
    }

    @Test func missingStoredMailboxIsIgnored() {
        let gone = MailboxRef(account: "Old", name: "Inbox")
        #expect(DailyMailboxSelection.effective(stored: [gone, Self.outlook.ref], available: Self.available) == [Self.outlook.ref])
        // Nothing stored exists any more: fall back to the default.
        #expect(DailyMailboxSelection.effective(stored: [gone], available: Self.available) == [Self.icloud.ref, Self.outlook.ref])
    }

    @Test func untickingOneInboxStoresTheRest() {
        let stored = DailyMailboxSelection.toggled(Self.icloud.ref, on: false, stored: [], available: Self.available)
        #expect(stored == [Self.outlook.ref])
    }

    @Test func tickingBackAllInboxesReturnsToDefault() {
        let stored = DailyMailboxSelection.toggled(Self.icloud.ref, on: true, stored: [Self.outlook.ref], available: Self.available)
        #expect(stored.isEmpty)
    }

    @Test func lastMailboxCannotBeUnticked() {
        let stored = [Self.outlook.ref]
        #expect(DailyMailboxSelection.toggled(Self.outlook.ref, on: false, stored: stored, available: Self.available) == stored)
        #expect(!DailyMailboxSelection.canUntick(Self.outlook.ref, stored: stored, available: Self.available))
        #expect(DailyMailboxSelection.canUntick(Self.outlook.ref, stored: [], available: Self.available))
    }

    @Test func extraMailboxIsAddedInListOrder() {
        let stored = DailyMailboxSelection.toggled(Self.archive.ref, on: true, stored: [], available: Self.available)
        #expect(stored == [Self.icloud.ref, Self.outlook.ref, Self.archive.ref])
    }

    @Test func rowsHideNoise() {
        let boxes = Self.available + [Self.box("iCloud", "Sent", .sent), Self.box("iCloud", "Empty", .custom, 0),
                                      Self.box("Outlook", "Notes", .custom, 4), Self.box("Outlook", "Receipts", .custom, 3)]
        let rows = DailyMailboxSelection.rows(boxes)
        #expect(rows.inboxes.map(\.info.ref) == [Self.icloud.ref, Self.outlook.ref])
        #expect(rows.otherCount == 2)
        #expect(DailyMailboxSelection.label(rows.inboxes[0]) == "Inbox · iCloud")
    }

    // MARK: Checked text

    @Test func checkedText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        func date(_ d: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
        }
        let now = date(9, 20, 10)
        #expect(MailAccessCheckedText.text(checkedAt: nil, now: now, calendar: cal) == "Not checked yet")
        #expect(MailAccessCheckedText.text(checkedAt: now.addingTimeInterval(-30), now: now, calendar: cal) == "Checked just now")
        #expect(MailAccessCheckedText.text(checkedAt: date(9, 20, 5), now: now, calendar: cal) == "Checked 8:05 pm")
        #expect(MailAccessCheckedText.text(checkedAt: date(9, 0, 7), now: now, calendar: cal) == "Checked 12:07 am")
        #expect(MailAccessCheckedText.text(checkedAt: date(9, 12, 0), now: now, calendar: cal) == "Checked 12:00 pm")
        #expect(MailAccessCheckedText.text(checkedAt: date(8, 17, 30), now: now, calendar: cal) == "Checked 8 Nov, 5:30 pm")
    }
}
