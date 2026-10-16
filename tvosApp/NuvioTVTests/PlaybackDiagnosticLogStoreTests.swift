import XCTest
@testable import NuvioTV
import AetherEngine

final class PlaybackDiagnosticLogStoreTests: XCTestCase {
    func testEntryAndByteBoundsEvictOldestLogs() {
        let store = PlaybackDiagnosticLogStore(maxEntries: 10, maxStoredBytes: 12, maxMessageBytes: 4)

        store.append(source: "S", message: "first-message")
        store.append(source: "S", message: "second-message")
        store.append(source: "S", message: "third-message")

        let entries = store.snapshot()
        XCTAssertEqual(entries.map(\.message), ["seco", "thir"])
        XCTAssertLessThanOrEqual(entries.count, 10)
        XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.source.utf8.count + $1.message.utf8.count }, 12)
        XCTAssertTrue(entries.allSatisfy { $0.message.utf8.count <= 4 })
    }

    func testLineBoundClearAndChronologicalIDs() {
        let store = PlaybackDiagnosticLogStore(maxEntries: 2, maxStoredBytes: 1024, maxMessageBytes: 64)
        let base = Date(timeIntervalSince1970: 1_000)
        store.append(source: "Test", message: "one", timestamp: base)
        store.append(source: "Test", message: "two", timestamp: base.addingTimeInterval(1))
        store.append(source: "Test", message: "three", timestamp: base.addingTimeInterval(2))

        let entries = store.snapshot()
        XCTAssertEqual(entries.map(\.message), ["two", "three"])
        XCTAssertEqual(entries.map(\.id), [2, 3])
        XCTAssertLessThan(entries[0].timestamp, entries[1].timestamp)

        store.clear()
        XCTAssertTrue(store.snapshot().isEmpty)
        store.append(source: "Test", message: "four")
        XCTAssertEqual(store.snapshot().map(\.id), [4])
    }

    func testRedactsSignedURLPathsQueriesAndCredentialHeaders() {
        let store = PlaybackDiagnosticLogStore()
        store.append(
            source: "Test",
            message: "GET https://cdn.example/live/opaque-account-secret/master.m3u8?token=opaque-token&sig=opaque-signature Authorization: Bearer header-secret"
        )

        let message = try! XCTUnwrap(store.snapshot().first?.message)
        XCTAssertTrue(message.contains("https://cdn.example/…"))
        XCTAssertFalse(message.contains("opaque-account-secret"))
        XCTAssertFalse(message.contains("opaque-token"))
        XCTAssertFalse(message.contains("opaque-signature"))
        XCTAssertFalse(message.contains("header-secret"))
        XCTAssertTrue(message.contains("Authorization: [redacted]"))
    }

    func testTruncationDoesNotRetainPartialUTF8() {
        let store = PlaybackDiagnosticLogStore(maxEntries: 2, maxStoredBytes: 64, maxMessageBytes: 5)
        store.append(source: "Test", message: "ab😀xy")

        let message = try! XCTUnwrap(store.snapshot().first?.message)
        XCTAssertEqual(message, "ab")
        XCTAssertLessThanOrEqual(message.utf8.count, 5)
    }

    func testRedactsBeforeTruncatingLongMessages() {
        let secret = "diagnostic-opaque-secret"
        XCTAssertTrue(EngineLog.registerSecret(secret))
        defer { EngineLog.unregisterSecret(secret) }
        let store = PlaybackDiagnosticLogStore(maxEntries: 2, maxStoredBytes: 64, maxMessageBytes: 8)
        store.append(source: "Test", message: "\(secret) in a longer message")

        let retained = try! XCTUnwrap(store.snapshot().first?.message)
        XCTAssertFalse(retained.contains("diagnostic"))
        XCTAssertLessThanOrEqual(retained.utf8.count, 8)
    }

    func testInstalledEngineHandlerCapturesRedactedLineInSharedStore() {
        let store = PlaybackDiagnosticLogStore.shared
        store.clear()
        defer { store.clear() }
        PlaybackDiagnosticLogStore.installAetherEngineHandlerIfNeeded()
        let marker = "diagnostic-log-\(UUID().uuidString)"

        EngineLog.emit("\(marker) https://logs.example/signed/opaque-path?token=recognized-secret&sig=opaque-tail")

        let entry = store.snapshot().first {
            $0.source == "AetherEngine" && $0.message.contains(marker)
        }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.message.contains("opaque-path") ?? true)
        XCTAssertFalse(entry?.message.contains("recognized-secret") ?? true)
        XCTAssertFalse(entry?.message.contains("opaque-tail") ?? true)
    }

    func testConcurrentWritersProduceUniqueChronologicalIDs() {
        let store = PlaybackDiagnosticLogStore(maxEntries: 500, maxStoredBytes: 1_000_000, maxMessageBytes: 4096)

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            store.append(source: "Concurrent", message: "event-\(index)")
        }

        let ids = store.snapshot().map(\.id)
        XCTAssertEqual(ids.count, 400)
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
