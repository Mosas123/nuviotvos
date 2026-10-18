import XCTest
@testable import NuvioTV

final class TmdbResponseCacheTests: XCTestCase {
    func testInsertEvictsLeastRecentlyUsedResponse() {
        var cache = TmdbResponseCache<Int>(capacity: 2)
        cache.insert(1, for: "first")
        cache.insert(2, for: "second")
        XCTAssertEqual(cache.value(for: "first"), 1)
        cache.insert(3, for: "third")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: "second"))
        XCTAssertEqual(cache.value(for: "first"), 1)
        XCTAssertEqual(cache.value(for: "third"), 3)
    }

    func testReplacingAnEntryRefreshesItsRecencyWithoutIncreasingCount() {
        var cache = TmdbResponseCache<Int>(capacity: 2)
        cache.insert(1, for: "first")
        cache.insert(2, for: "second")
        cache.insert(10, for: "first")
        XCTAssertEqual(cache.count, 2)
        cache.insert(3, for: "third")
        XCTAssertNil(cache.value(for: "second"))
        XCTAssertEqual(cache.value(for: "first"), 10)
    }

    func testMissingLookupDoesNotChangeEvictionOrder() {
        var cache = TmdbResponseCache<Int>(capacity: 2)
        cache.insert(1, for: "first")
        cache.insert(2, for: "second")
        XCTAssertNil(cache.value(for: "missing"))
        cache.insert(3, for: "third")
        XCTAssertNil(cache.value(for: "first"))
        XCTAssertEqual(cache.value(for: "second"), 2)
    }

    func testClearResetsValuesAndRecency() {
        var cache = TmdbResponseCache<Int>(capacity: 1)
        cache.insert(1, for: "old")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(for: "old"))
        cache.insert(2, for: "new")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "new"), 2)
    }

    func testZeroAndNegativeCapacityDoNotRetainResponses() {
        for capacity in [0, -1] {
            var cache = TmdbResponseCache<Int>(capacity: capacity)
            cache.insert(1, for: "key")
            XCTAssertEqual(cache.count, 0)
            XCTAssertNil(cache.value(for: "key"))
        }
    }

    func testLongSessionRetainsOnlyTheConfiguredWorkingSet() {
        var cache = TmdbResponseCache<Int>(capacity: 256)
        for index in 0..<10_000 {
            cache.insert(index, for: String(index))
        }
        XCTAssertEqual(cache.count, 256)
        XCTAssertNil(cache.value(for: "0"))
        XCTAssertNil(cache.value(for: "9743"))
        XCTAssertEqual(cache.value(for: "9744"), 9744)
        XCTAssertEqual(cache.value(for: "9999"), 9999)
    }

    func testLanguageKeysRetainIndependentResponses() {
        var cache = TmdbResponseCache<String>(capacity: 2)
        cache.insert("English", for: "movie:42:en-US")
        cache.insert("Español", for: "movie:42:es-ES")
        XCTAssertEqual(cache.value(for: "movie:42:en-US"), "English")
        XCTAssertEqual(cache.value(for: "movie:42:es-ES"), "Español")
    }
}
