import Foundation
import Testing
@testable import MailDigestCore

@Suite struct InfoClusteringTests {
    static let box = MailboxRef(account: "iCloud", name: "Inbox")
    static let monday = DigestDay(year: 2026, month: 11, day: 9)
    static let sunday = DigestDay(year: 2026, month: 11, day: 8)

    static func item(_ id: String, _ facts: [String], category: Category = .personal, importance: Int = 2,
                     summary: String = "An order.") -> InfoItem {
        InfoItem(id: id, emailID: id, category: category, importance: importance, summary: summary, keyFacts: facts, pinned: false)
    }

    static func emails(_ pairs: [(String, String)]) -> [String: EmailContext] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, EmailContext(sender: $0.1, subject: "Order", mailbox: box)) })
    }

    static let coles = "Coles <orders@coles.example>"

    // MARK: Money parsing

    @Test func parsesSymbolAndCodeAmounts() {
        #expect(MoneyParser.amounts(in: "Total $17.45") == [Money(currency: "$", value: Decimal(string: "17.45")!)])
        #expect(MoneyParser.amounts(in: "AUD 1,200.50 charged") == [Money(currency: "AUD", value: Decimal(string: "1200.50")!)])
        #expect(MoneyParser.amounts(in: "12 EUR") == [Money(currency: "EUR", value: 12)])
        #expect(MoneyParser.amounts(in: "€5") == [Money(currency: "€", value: 5)])
    }

    @Test func ignoresNumbersWithoutACurrency() {
        #expect(MoneyParser.amounts(in: "Due 18 NOV at 5pm, room 301").isEmpty)
        #expect(MoneyParser.amounts(in: "Tracking 1234567").isEmpty)
    }

    @Test func moneyText() {
        #expect(Money(currency: "$", value: Decimal(string: "51.35")!).text == "$51.35")
        #expect(Money(currency: "AUD", value: 1200).text == "AUD 1,200.00")
    }

    // MARK: Grouping

    @Test func sameSenderSameDayCollapsesWithSummedTotal() {
        let items = [Self.item("a", ["Total $17.45"]), Self.item("b", ["$20.00"]), Self.item("c", ["Total $13.90", "5 items"])]
        let emails = Self.emails([("a", Self.coles), ("b", Self.coles), ("c", Self.coles)])
        let clusters = InfoClustering.clusters(items, emails: emails) { _ in Self.monday }
        #expect(clusters.count == 1)
        let c = clusters[0]
        #expect(c.items.map(\.id) == ["a", "b", "c"])
        #expect(c.isGroup)
        #expect(c.total == Money(currency: "$", value: Decimal(string: "51.35")!))
        #expect(c.countText == "3 receipts")
        #expect(c.senderName == "Coles")
    }

    @Test func singleItemStaysUngrouped() {
        let clusters = InfoClustering.clusters([Self.item("a", ["$5.00"])], emails: Self.emails([("a", Self.coles)])) { _ in Self.monday }
        #expect(clusters.count == 1)
        #expect(!clusters[0].isGroup)
        #expect(clusters[0].total == nil)
    }

    @Test func differentDaysOrSendersStaySeparate() {
        let items = [Self.item("a", []), Self.item("b", []), Self.item("c", [])]
        let emails = Self.emails([("a", Self.coles), ("b", Self.coles), ("c", "Woolworths <hi@woolies.example>")])
        let clusters = InfoClustering.clusters(items, emails: emails) { $0.id == "b" ? Self.sunday : Self.monday }
        #expect(clusters.count == 3)
    }

    @Test func itemsWithoutEmailContextAreNotGrouped() {
        let clusters = InfoClustering.clusters([Self.item("a", []), Self.item("b", [])], emails: [:]) { _ in Self.monday }
        #expect(clusters.count == 2)
    }

    @Test func mixedCurrenciesGiveNoTotal() {
        let items = [Self.item("a", ["$10.00"]), Self.item("b", ["AUD 5.00"])]
        let c = InfoClustering.clusters(items, emails: Self.emails([("a", Self.coles), ("b", Self.coles)])) { _ in Self.monday }
        #expect(c.count == 1)
        #expect(c[0].total == nil)
        #expect(c[0].countText == "2 emails")
    }

    @Test func aMissingAmountGivesNoTotal() {
        let items = [Self.item("a", ["$10.00"]), Self.item("b", ["Delivered"])]
        let c = InfoClustering.clusters(items, emails: Self.emails([("a", Self.coles), ("b", Self.coles)])) { _ in Self.monday }
        #expect(c[0].total == nil)
    }

    @Test func ambiguousAmountsInOneItemAreNotGuessed() {
        // Two different amounts and none marked "total": which one is the order value is unknown.
        let item = Self.item("a", ["Delivery $5.00", "Items $40.00"])
        #expect(InfoClustering.amount(of: item) == nil)
        // A fact that says "total" disambiguates.
        let marked = Self.item("b", ["Delivery $5.00", "Total $45.00"])
        #expect(InfoClustering.amount(of: marked) == Money(currency: "$", value: 45))
    }

    @Test func billLikeGroupsAreNotCalledReceipts() {
        let items = [Self.item("a", ["$10.00 due Friday"]), Self.item("b", ["$20.00"])]
        let c = InfoClustering.clusters(items, emails: Self.emails([("a", Self.coles), ("b", Self.coles)])) { _ in Self.monday }
        #expect(c[0].total != nil)
        #expect(c[0].noun == "emails")
    }

    @Test func categoryNounWithoutTotals() {
        let items = [Self.item("a", [], category: .deliveries), Self.item("b", [], category: .deliveries)]
        let c = InfoClustering.clusters(items, emails: Self.emails([("a", Self.coles), ("b", Self.coles)])) { _ in Self.monday }
        #expect(c[0].countText == "2 delivery updates")
    }

    @Test func clustersAreOrderedByImportanceThenInputOrder() {
        let items = [Self.item("a", [], importance: 1), Self.item("b", [], importance: 4), Self.item("c", [], importance: 4)]
        let c = InfoClustering.clusters(items, emails: [:]) { _ in Self.monday }
        #expect(c.map(\.id) == ["b", "c", "a"])
    }

    @Test func senderAddressMatchIgnoresDisplayNameAndCase() {
        let items = [Self.item("a", []), Self.item("b", [])]
        let emails = Self.emails([("a", "Coles <Orders@Coles.example>"), ("b", "Coles Online <orders@coles.example>")])
        #expect(InfoClustering.clusters(items, emails: emails) { _ in Self.monday }.count == 1)
    }
}
