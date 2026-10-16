import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class WatchProgressAcknowledgementTests: XCTestCase {
    func testUnchangedSnapshotIsAcknowledgedAndRepeatedAckIsHarmless() {
        withProfile { profileId in
            let sent = makeRecord()
            XCTAssertTrue(WatchProgressLedger.upsert(sent, profileId: profileId))

            WatchProgressLedger.markPushed(records: [sent], profileId: profileId)
            var expected = sent
            expected.isPendingPush = false
            XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: profileId), expected)

            WatchProgressLedger.markPushed(records: [sent], profileId: profileId)
            XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: profileId), expected)
        }
    }

    func testNewerSaveRemainsPendingAfterOldSnapshotAck() {
        withProfile { profileId in
            let sent = makeRecord()
            let newer = makeRecord(position: 300, watchedAt: 1_700_000_100)
            XCTAssertTrue(WatchProgressLedger.upsert(sent, profileId: profileId))
            XCTAssertTrue(WatchProgressLedger.upsert(newer, profileId: profileId))

            WatchProgressLedger.markPushed(records: [sent], profileId: profileId)

            XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: profileId), newer)
        }
    }

    func testChangedPayloadWithSameTimestampRemainsPending() {
        withProfile { profileId in
            let sent = makeRecord()
            let changedPayloads = [
                makeRecord(position: 300),
                makeRecord(duration: 2_000),
                makeRecord(videoId: "g01-alternate-video")
            ]
            for changed in changedPayloads {
                XCTAssertTrue(WatchProgressLedger.upsert(changed, profileId: profileId))
                WatchProgressLedger.markPushed(records: [sent], profileId: profileId)
                XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: profileId), changed)
            }
        }
    }

    func testTimestampOnlyChangeRemainsPending() {
        withProfile { profileId in
            let sent = makeRecord()
            let newer = makeRecord(watchedAt: 1_700_000_100)
            XCTAssertTrue(WatchProgressLedger.upsert(newer, profileId: profileId))

            WatchProgressLedger.markPushed(records: [sent], profileId: profileId)

            XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: profileId), newer)
        }
    }

    func testBatchAcknowledgesOnlyMatchingRowsAndDoesNotResurrectDeletedRows() {
        withProfile { profileId in
            let unchanged = makeRecord(contentId: "g01-unchanged")
            let old = makeRecord(contentId: "g01-updated")
            let newer = makeRecord(contentId: "g01-updated", position: 300)
            let deleted = makeRecord(contentId: "g01-deleted")
            let unrelated = makeRecord(contentId: "g01-unrelated")
            for record in [unchanged, newer, deleted, unrelated] {
                XCTAssertTrue(WatchProgressLedger.upsert(record, profileId: profileId))
            }
            XCTAssertTrue(WatchProgressLedger.remove(keys: [deleted.progressKey], profileId: profileId))

            WatchProgressLedger.markPushed(records: [unchanged, old, deleted], profileId: profileId)

            XCTAssertEqual(WatchProgressLedger.record(forKey: unchanged.progressKey, profileId: profileId)?.isPendingPush, false)
            XCTAssertEqual(WatchProgressLedger.record(forKey: old.progressKey, profileId: profileId), newer)
            XCTAssertNil(WatchProgressLedger.record(forKey: deleted.progressKey, profileId: profileId))
            XCTAssertEqual(WatchProgressLedger.record(forKey: unrelated.progressKey, profileId: profileId), unrelated)
        }
    }

    func testExplicitOriginProfileIsAcknowledgedWithoutChangingActiveProfile() {
        withProfile { origin in
            withProfile { other in
                let previousActive = WatchProgressLedger.activeProfileId
                defer { WatchProgressLedger.setActiveProfile(previousActive) }
                let sent = makeRecord()
                XCTAssertTrue(WatchProgressLedger.upsert(sent, profileId: origin))
                XCTAssertTrue(WatchProgressLedger.upsert(sent, profileId: other))
                WatchProgressLedger.setActiveProfile(other)

                WatchProgressLedger.markPushed(records: [sent], profileId: origin)

                XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: origin)?.isPendingPush, false)
                XCTAssertEqual(WatchProgressLedger.record(forKey: sent.progressKey, profileId: other), sent)
            }
        }
    }

    private func withProfile(_ body: (String) -> Void) {
        let profileId = "g01-ack-\(UUID().uuidString)"
        defer { WatchProgressLedger.eraseProfile(profileId) }
        body(profileId)
    }

    private func makeRecord(
        contentId: String = "g01-ack-movie",
        position: Double = 100,
        duration: Double = 1_000,
        watchedAt: TimeInterval = 1_700_000_000,
        videoId: String? = nil
    ) -> WatchProgressRecord {
        WatchProgressRecord(
            progressKey: contentId,
            contentId: contentId,
            contentType: "movie",
            videoId: videoId ?? contentId,
            season: nil,
            episode: nil,
            position: position,
            duration: duration,
            lastWatchedAt: Date(timeIntervalSince1970: watchedAt),
            isPendingPush: true
        )
    }
}
