import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func info(_ id: String, pinned: Bool = false) -> InfoItem {
    InfoItem(id: id, emailID: id, category: .work, importance: 2, summary: "Summary \(id)", keyFacts: ["k"], pinned: pinned)
}

@Suite struct PinnedInfoTests {
    @Test func pinAndUnpinPersistOneItemOnly() async throws {
        let store = InMemoryDigestStore()
        let d = Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 0, suggestions: [],
                       info: [info("a"), info("b")], skipped: [])
        try await store.save(d)
        try await store.setPinned(true, infoID: "a", digestID: d.id)
        #expect(try await store.digest(id: d.id)?.info.map(\.pinned) == [true, false])
        try await store.setPinned(false, infoID: "a", digestID: d.id)
        #expect(try await store.pinnedInfo().isEmpty)
        // Unknown digest or item is ignored.
        try await store.setPinned(true, infoID: "nope", digestID: d.id)
        try await store.setPinned(true, infoID: "a", digestID: UUID())
        #expect(try await store.pinnedInfo().isEmpty)
    }

    @Test func pinnedInfoSpansDigestsNewestFirst() async throws {
        let store = InMemoryDigestStore()
        let old = Digest(id: UUID(), createdAt: t0.addingTimeInterval(-86_400), headline: "old", emailCount: 0,
                         suggestions: [], info: [info("o", pinned: true), info("x")], skipped: [])
        let new = Digest(id: UUID(), createdAt: t0, headline: "new", emailCount: 0, suggestions: [],
                         info: [info("n1"), info("n2", pinned: true)], skipped: [])
        try await store.save(new)
        try await store.save(old)
        let pinned = try await store.pinnedInfo()
        #expect(pinned.map(\.item.emailID) == ["n2", "o"])
        #expect(pinned.map(\.digestID) == [new.id, old.id])
        #expect(pinned.map(\.digestCreatedAt) == [t0, t0.addingTimeInterval(-86_400)])
    }
}
