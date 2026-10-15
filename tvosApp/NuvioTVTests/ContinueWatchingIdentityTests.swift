import XCTest
@testable import NuvioTV

final class ContinueWatchingIdentityTests: XCTestCase {
    private func row(
        id: String,
        imdb: String = "tt7000001",
        date: TimeInterval,
        upNext: Bool = false
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: NuvioMeta(id: id, name: "Identity fixture", imdbId: imdb, type: "series"),
            streamUrl: "",
            position: 100,
            duration: 1_800,
            lastWatchedAt: Date(timeIntervalSince1970: date),
            season: 1,
            episode: 2,
            isUpNext: upNext
        )
    }

    func testResolvedAliasesKeepNewestPlaybackInEitherOrder() {
        let older = row(id: "simkl:7001", date: 10)
        let newer = row(id: "tt7000001", date: 20)
        for input in [[older, newer], [newer, older]] {
            let result = ContinueWatchingBuilder.deduplicatingResolvedIdentities(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.meta.id, newer.meta.id)
        }
    }

    func testRealPlaybackWinsOverNewerUpNextAlias() {
        let playback = row(id: "simkl:7001", date: 10)
        let seed = row(id: "tt7000001", date: 20, upNext: true)
        for input in [[playback, seed], [seed, playback]] {
            let result = ContinueWatchingBuilder.deduplicatingResolvedIdentities(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.isUpNextEntry, false)
        }
    }

    func testDistinctKnownIdentitiesWithSameTitleRemainSeparate() {
        let first = row(id: "tt7000001", date: 10)
        let second = row(id: "tt7000002", imdb: "tt7000002", date: 20)
        XCTAssertEqual(
            ContinueWatchingBuilder.deduplicatingResolvedIdentities([first, second]).count,
            2
        )
    }

    func testPersistedFirstPageAliasCannotResurrectAfterRemoval() {
        let persisted = row(id: "tt7000001", date: 10)
        let laterAlias = row(id: "simkl:7001", date: 20)
        let memory = ContinueWatchingBuilder.memoryOnlyItems(
            from: [laterAlias],
            persistedItemIDs: [persisted.meta.id],
            persistedItems: [persisted]
        )
        XCTAssertTrue(memory.isEmpty)
        XCTAssertTrue(ContinueWatchingBuilder.mergeMemoryOnlyItems(memory, with: []).isEmpty)
    }

    func testCurrentStoreWinsAcrossAliasesEvenWhenMemoryIsNewer() {
        let stored = row(id: "tt7000001", date: 10)
        let memory = row(id: "simkl:7001", date: 20)
        let result = ContinueWatchingBuilder.mergeMemoryOnlyItems([memory], with: [stored])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.meta.id, stored.meta.id)
        XCTAssertEqual(result.first?.lastWatchedAt, stored.lastWatchedAt)
    }
}
