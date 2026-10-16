import XCTest
@testable import NuvioTV

final class TopShelfWriteCoordinatorTests: XCTestCase {
    func testOlderDetachedCompletionCannotReplaceNewerFeed() {
        let coordinator = TopShelfWriteCoordinator()
        let old = coordinator.beginWrite()
        let newest = coordinator.beginWrite()
        var feed = "initial"

        XCTAssertTrue(coordinator.commitIfCurrent(newest) { feed = "new" })
        XCTAssertFalse(coordinator.commitIfCurrent(old) { feed = "old" })

        XCTAssertEqual(feed, "new")
    }

    func testNewWriteCanReplaceAnAlreadyCommittedOldFeed() {
        let coordinator = TopShelfWriteCoordinator()
        let old = coordinator.beginWrite()
        var feed = "initial"
        XCTAssertTrue(coordinator.commitIfCurrent(old) { feed = "old" })

        let newest = coordinator.beginWrite()
        XCTAssertTrue(coordinator.commitIfCurrent(newest) { feed = "new" })

        XCTAssertEqual(feed, "new")
    }

    func testOnlyLatestOfSeveralSnapshotsCanCommit() {
        let coordinator = TopShelfWriteCoordinator()
        let generations = (0..<4).map { _ in coordinator.beginWrite() }
        var committed: [Int] = []

        for index in generations.indices.reversed() {
            let accepted = coordinator.commitIfCurrent(generations[index]) { committed.append(index) }
            XCTAssertEqual(accepted, index == generations.count - 1)
        }

        XCTAssertEqual(committed, [3])
    }

    func testNewEmptyFeedCannotBeRepopulatedByOldSnapshot() {
        let coordinator = TopShelfWriteCoordinator()
        let old = coordinator.beginWrite()
        let cleared = coordinator.beginWrite()
        var feed = ["initial"]

        XCTAssertTrue(coordinator.commitIfCurrent(cleared) { feed = [] })
        XCTAssertFalse(coordinator.commitIfCurrent(old) { feed = ["old"] })

        XCTAssertTrue(feed.isEmpty)
    }
}
