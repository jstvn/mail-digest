import Foundation

/// A currency amount found in an info item's key facts.
public struct Money: Sendable, Hashable {
    /// An ISO code ("AUD") when the fact names one, otherwise the symbol ("$").
    public var currency: String
    public var value: Decimal

    public init(currency: String, value: Decimal) {
        self.currency = currency
        self.value = value
    }

    /// "$51.35" for a symbol, "AUD 51.35" for a code.
    public var text: String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let number = f.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
        return currency.count == 1 ? "\(currency)\(number)" : "\(currency) \(number)"
    }
}

/// Finds currency amounts in short fact strings. Only amounts that carry a currency symbol or a known ISO
/// code count, so "18 NOV" or "5 pm" are never read as money.
public enum MoneyParser {
    private static let codes = "AUD|USD|EUR|GBP|NZD|CAD|JPY|SGD"
    private static let number = #"(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?"#
    private static let suffixed = try! NSRegularExpression(pattern: number + #"\s?(\#(codes))\b"#)
    private static let withSymbol = try! NSRegularExpression(pattern: #"(?:\b(\#(codes))\s?)?([$€£¥])\s?"# + number)
    private static let withCode = try! NSRegularExpression(pattern: #"\b(\#(codes))\s?"# + number)

    /// Every amount in `text`, in order.
    public static func amounts(in text: String) -> [Money] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [(Int, Money)] = []
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func decimal(_ whole: String?, _ fraction: String?) -> Decimal? {
            guard let whole else { return nil }
            return Decimal(string: whole.replacingOccurrences(of: ",", with: "") + (fraction ?? ""),
                           locale: Locale(identifier: "en_US_POSIX"))
        }
        var taken: [NSRange] = []
        // A symbol amount, optionally with a code in front.
        for m in withSymbol.matches(in: text, range: full) {
            guard let currency = group(m, 1) ?? group(m, 2), let v = decimal(group(m, 3), group(m, 4)) else { continue }
            out.append((m.range.location, Money(currency: currency, value: v)))
            taken.append(m.range)
        }
        // "AUD 51.35" and "51.35 AUD" where no symbol was present.
        for m in withCode.matches(in: text, range: full) where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            guard let code = group(m, 1), let v = decimal(group(m, 2), group(m, 3)) else { continue }
            out.append((m.range.location, Money(currency: code, value: v)))
            taken.append(m.range)
        }
        for m in suffixed.matches(in: text, range: full) where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            guard let code = group(m, 3), let v = decimal(group(m, 1), group(m, 2)) else { continue }
            out.append((m.range.location, Money(currency: code, value: v)))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// One card of Worth Knowing: a single info item, or several from one sender on one digest day.
public struct InfoCluster: Sendable, Equatable, Identifiable {
    /// The id of the first item.
    public var id: String
    /// Highest importance first; the first item leads the card.
    public var items: [InfoItem]
    /// The sender's display name; nil when no email context was available.
    public var senderName: String?
    /// The sum of the items' amounts; nil unless every item has exactly one clear amount in one currency.
    public var total: Money?
    /// "receipts", "delivery updates", "emails", and so on, after a count.
    public var noun: String

    public init(id: String, items: [InfoItem], senderName: String?, total: Money?, noun: String) {
        self.id = id
        self.items = items
        self.senderName = senderName
        self.total = total
        self.noun = noun
    }

    public var lead: InfoItem { items[0] }
    public var category: Category { lead.category }
    public var isGroup: Bool { items.count > 1 }
    public var importance: Int { items.map(\.importance).max() ?? 0 }
    /// "3 receipts".
    public var countText: String { "\(items.count) \(noun)" }
}

public enum InfoClustering {
    /// Collapses items with the same sender address on the same digest day. A single item, an item without
    /// email context and an item without a day stay alone. Clusters are ordered by importance, then input order.
    public static func clusters(_ items: [InfoItem], emails: [String: EmailContext],
                                day: (InfoItem) -> DigestDay?) -> [InfoCluster] {
        var order: [String] = []
        var buckets: [String: [InfoItem]] = [:]
        for item in items {
            var key = "item:\(item.id)"
            if let sender = emails[item.emailID]?.sender, let d = day(item) {
                let address = MailFilter.address(from: sender)
                if !address.isEmpty { key = "sender:\(address)|\(d.year)-\(d.month)-\(d.day)" }
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        let built = order.enumerated().map { offset, key -> (Int, InfoCluster) in
            let sorted = buckets[key, default: []].enumerated()
                .sorted { $0.element.importance != $1.element.importance
                    ? $0.element.importance > $1.element.importance : $0.offset < $1.offset }
                .map(\.element)
            let total = sorted.count > 1 ? total(of: sorted) : nil
            let name = emails[sorted[0].emailID].map { ReviewPresentation.senderName($0.sender) }
            return (offset, InfoCluster(id: sorted[0].id, items: sorted, senderName: name, total: total,
                                        noun: noun(for: sorted, hasTotal: total != nil)))
        }
        return built.sorted { $0.1.importance != $1.1.importance ? $0.1.importance > $1.1.importance : $0.0 < $1.0 }
            .map(\.1)
    }

    /// The one amount of an item: the only distinct amount in its facts, else the only one in facts that say
    /// "total". Nil when it has none or cannot be told apart.
    public static func amount(of item: InfoItem) -> Money? {
        let all = Set(item.keyFacts.flatMap(MoneyParser.amounts(in:)))
        if all.count == 1 { return all.first }
        let totals = Set(item.keyFacts.filter { $0.localizedCaseInsensitiveContains("total") }.flatMap(MoneyParser.amounts(in:)))
        return totals.count == 1 ? totals.first : nil
    }

    /// Sums every item's amount, but only when all items have one and they share a currency.
    public static func total(of items: [InfoItem]) -> Money? {
        let amounts = items.compactMap(amount(of:))
        guard amounts.count == items.count, let currency = amounts.first?.currency,
              amounts.allSatisfy({ $0.currency == currency }) else { return nil }
        return Money(currency: currency, value: amounts.reduce(Decimal(0)) { $0 + $1.value })
    }

    private static let billWords = ["due", "invoice", "bill", "statement", "overdue", "payable", "owing"]

    /// A noun that reads correctly after a count. "receipts" only when there is a total and nothing reads like
    /// a bill; otherwise a noun for the category, else "emails".
    static func noun(for items: [InfoItem], hasTotal: Bool) -> String {
        if hasTotal {
            let text = items.flatMap { [$0.summary] + $0.keyFacts }
            if !text.contains(where: { t in billWords.contains { t.localizedCaseInsensitiveContains($0) } }) { return "receipts" }
        }
        switch items[0].category {
        case .deliveries: return "delivery updates"
        case .events: return "event updates"
        case .newsletters: return "newsletters"
        default: return "emails"
        }
    }
}
