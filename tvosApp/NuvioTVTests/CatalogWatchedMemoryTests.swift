import Foundation
import UIKit
import XCTest
@testable import NuvioTV

@MainActor
final class CatalogWatchedMemoryTests: XCTestCase {
    private func meta(_ name: String) -> NuvioMeta {
        NuvioMeta(id: "tt1234567", name: name, type: "series")
    }

    func testMemoryWarningReleasesMetadataAndDecisions() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(2, for: "decision")
        XCTAssertEqual(fetchCount, 1)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 2)
    }

    func testManualCacheClearAlsoReleasesAuxiliaryMetadata() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(1, for: "decision")
        center.post(name: AppCacheManager.didClearCacheNotification, object: nil)
        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 2)
    }

    func testWatchedChangeKeepsGuideButInvalidatesCalculatedCount() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(3, for: "decision")
        center.post(name: WatchedStore.changedNotification, object: nil)
        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 1)
    }

    func testPendingResultStillReachesConsumerButDoesNotRefillPurgedCache() async {
        let started = expectation(description: "old request started")
        let gate = WatchedMetadataGate { started.fulfill() }
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: NotificationCenter()) { _, _ in
            fetchCount += 1
            if fetchCount == 1 { return await gate.fetch() }
            return self.meta("Fresh")
        }
        let pending = Task { await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil) }
        await fulfillment(of: [started], timeout: 2)
        cache.purgeTransientValues()
        gate.finish(meta("Old"))
        let oldResult = await pending.value
        XCTAssertEqual(oldResult?.name, "Old")
        let fresh = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fresh?.name, "Fresh")
        XCTAssertEqual(fetchCount, 2)
    }

    func testOlderCompletionCannotOverwritePostPurgeResponse() async {
        let started = expectation(description: "old request started")
        let gate = WatchedMetadataGate { started.fulfill() }
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: NotificationCenter()) { _, _ in
            fetchCount += 1
            if fetchCount == 1 { return await gate.fetch() }
            return self.meta("Fresh")
        }
        let pending = Task { await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil) }
        await fulfillment(of: [started], timeout: 2)
        cache.purgeTransientValues()
        let fresh = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fresh?.name, "Fresh")
        gate.finish(meta("Old"))
        _ = await pending.value
        let cached = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(cached?.name, "Fresh")
        XCTAssertEqual(fetchCount, 2)
    }
}

@MainActor
private final class WatchedMetadataGate {
    private let onStarted: () -> Void
    private var continuation: CheckedContinuation<NuvioMeta?, Never>?

    init(onStarted: @escaping () -> Void) { self.onStarted = onStarted }

    func fetch() async -> NuvioMeta? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStarted()
        }
    }

    func finish(_ meta: NuvioMeta) {
        continuation?.resume(returning: meta)
        continuation = nil
    }
}
