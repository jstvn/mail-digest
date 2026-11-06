import Foundation

/// Suggestion records of one calendar day (by their digest's creation), for the Review Queue sections.
public struct RecordGroup: Sendable, Equatable, Identifiable {
    public var day: DigestDay
    public var records: [SuggestionRecord]
    public var id: DigestDay { day }
}

/// The records a canvas shows first plus how many more are behind "Show all" (Q16).
public struct RecordPage: Sendable, Equatable {
    public var visible: [SuggestionRecord]
    public var hiddenCount: Int
}

/// Pure grouping and filtering behind the review canvases, so the app models stay thin.
public enum ReviewCanvasLogic {
    /// Groups records by the day their digest was created in `calendar`'s time zone. Groups and the records
    /// inside them keep the order of first appearance, so a newest-first page stays newest first.
    public static func groupByDay(_ records: [SuggestionRecord], calendar: Calendar) -> [RecordGroup] {
        var order: [DigestDay] = []
        var byDay: [DigestDay: [SuggestionRecord]] = [:]
        for r in records {
            let d = DigestDay(r.digestCreatedAt, calendar: calendar)
            if byDay[d] == nil { order.append(d) }
            byDay[d, default: []].append(r)
        }
        return order.map { RecordGroup(day: $0, records: byDay[$0] ?? []) }
    }

    /// The Q16 presentation limit over records: the highest-confidence ones stay (in their own order),
    /// the rest are counted. A nil limit or `showAll` shows everything.
    public static func page(_ records: [SuggestionRecord], limit: Int?, showAll: Bool) -> RecordPage {
        let page = ReviewPresentation.page(records.map(\.suggestion), limit: limit, showAll: showAll)
        guard page.hiddenCount > 0 else { return RecordPage(visible: records, hiddenCount: 0) }
        let keep = Set(page.visible.map(\.id))
        return RecordPage(visible: records.filter { keep.contains($0.id) }, hiddenCount: page.hiddenCount)
    }

    /// Pinned info that carries into a canvas: from digests the canvas does not show, and not for an email the
    /// canvas already lists (it shows there instead).
    public static func carriedPins(_ pins: [PinnedInfo], excludingDigests shown: Set<UUID>,
                                   shownEmailIDs: Set<String>) -> [PinnedInfo] {
        pins.filter { !shown.contains($0.digestID) && !shownEmailIDs.contains($0.item.emailID) }
    }
}
