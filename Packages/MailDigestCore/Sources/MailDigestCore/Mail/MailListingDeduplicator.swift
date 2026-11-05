import Foundation

/// Collapses a listing to one header per canonical Message-ID (Q32).
public enum MailListingDeduplicator {
    /// Keeps the newest `receivedAt` per id. On equal timestamps the greater `storeRowID` wins when
    /// both have one, otherwise the earlier input entry. Output is newest first; ties are ordered by
    /// greater `storeRowID`, then input order.
    public static func deduplicate(_ headers: [MessageHeader]) -> [MessageHeader] {
        var best: [String: (index: Int, header: MessageHeader)] = [:]
        for (i, h) in headers.enumerated() {
            guard let current = best[h.id] else { best[h.id] = (i, h); continue }
            if wins(h, over: current.header) { best[h.id] = (i, h) }
        }
        return best.values.sorted { a, b in
            if a.header.receivedAt != b.header.receivedAt { return a.header.receivedAt > b.header.receivedAt }
            let ra = a.header.sourceReference.storeRowID ?? -1
            let rb = b.header.sourceReference.storeRowID ?? -1
            if ra != rb { return ra > rb }
            return a.index < b.index
        }.map(\.header)
    }

    /// Whether `candidate` (a later occurrence) should replace `incumbent`.
    private static func wins(_ candidate: MessageHeader, over incumbent: MessageHeader) -> Bool {
        if candidate.receivedAt != incumbent.receivedAt { return candidate.receivedAt > incumbent.receivedAt }
        if let c = candidate.sourceReference.storeRowID, let i = incumbent.sourceReference.storeRowID { return c > i }
        return false
    }
}
