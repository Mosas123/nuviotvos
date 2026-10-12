import Foundation
import Testing
@testable import AetherEngine

@Suite("SegmentCache window/prune index math")
struct SegmentCacheTests {

    private func makeData(_ n: Int, fill: UInt8 = 0xAA) -> Data { Data(repeating: fill, count: n) }

    @Test("store then fetch round-trips; count and totalBytes track")
    func storeFetch() {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { c.close() }
        c.store(index: 0, data: makeData(100))
        c.store(index: 1, data: makeData(200))
        #expect(c.count == 2)
        #expect(c.totalBytes == 300)
        #expect(c.peek(index: 0)?.count == 100)
        #expect(c.fetch(index: 1, timeout: 0.1)?.count == 200)
        #expect(c.peek(index: 99) == nil)
    }

    @Test("Overwriting an index subtracts the old byte count (not double-counted)")
    func overwriteByteAccounting() {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { c.close() }
        c.store(index: 3, data: makeData(100))
        #expect(c.totalBytes == 100)
        c.store(index: 3, data: makeData(250))
        #expect(c.count == 1)
        #expect(c.totalBytes == 250)
    }

    @Test("A re-adopted index gets a fresh file and retires the previous one (audit SEG-4)")
    func readoptionNeverReusesAPath() throws {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { c.close() }
        func staged(_ n: Int, fill: UInt8) throws -> URL {
            let url = c.sessionDir.appendingPathComponent("staging-\(UUID().uuidString).tmp")
            try makeData(n, fill: fill).write(to: url)
            return url
        }
        c.adopt(index: 3, stagingPath: try staged(100, fill: 0x01), byteCount: 100)
        let first = try #require(c.peekURL(index: 3))
        c.adopt(index: 3, stagingPath: try staged(250, fill: 0x02), byteCount: 250)
        let second = try #require(c.peekURL(index: 3))

        // A reader that resolved the first URL and finds it gone must not be able to drop the
        // second adoption, which it could while both generations shared one path.
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(c.fetch(index: 3, timeout: 0.1)?.first == 0x02)
        #expect(c.count == 1)
        #expect(c.totalBytes == 250)

        c.store(index: 3, data: makeData(40, fill: 0x03))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(c.peek(index: 3)?.first == 0x03)
        #expect(c.totalBytes == 40)
    }

    @Test("Backward refetch does not evict already-produced forward segments")
    func backwardRefetchKeepsForward() {
        // forwardWindow small, backwardWindow wide so production never prunes the trailing end.
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.count == 11)
        // AVPlayer audio-handover refetch to seg 2: hi anchors on highestStoredIndex (10), not
        // target+forwardWindow (4), so forward seg 3..10 survive (repro: seg0..25, refetch4 stalled at 15).
        c.declareTarget(2)
        #expect(c.count == 11)
        #expect(c.peek(index: 3) != nil)
        #expect(c.peek(index: 10) != nil)
    }

    @Test("highestStoredIndex is monotonic; only reset by resetHighWaterForRestart")
    func highWaterMonotonic() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.highestStoredIndex == 10)
        c.store(index: 4, data: makeData(10))     // storing a lower index
        #expect(c.highestStoredIndex == 10)       // must not lower the high-water mark
        c.resetHighWaterForRestart()
        #expect(c.highestStoredIndex == -1)
    }

    @Test("After high-water reset, prune drops segments above target+forwardWindow")
    func pruneAfterReset() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.resetHighWaterForRestart()
        c.declareTarget(2)                        // hi = max(2+2, -1) = 4 -> seg 5..10 evicted
        #expect(c.peek(index: 5) == nil)
        #expect(c.peek(index: 4) != nil)          // inside forward window
        #expect(c.peek(index: 0) != nil)          // inside (wide) backward window
    }

    @Test("indexRange reflects only resident entries")
    func indexRangeResident() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        #expect(c.indexRange() == nil)
        for i in 5...8 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        let range = c.indexRange()
        #expect(range?.0 == 5)
        #expect(range?.1 == 8)
    }

    @Test("evictBelow removes segments strictly below the cutoff and adjusts totalBytes")
    func evictBelowCutoff() {
        let c = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.evictBelow(5)
        #expect(c.peek(index: 4) == nil)
        #expect(c.peek(index: 5) != nil)
        #expect(c.totalBytes == 60)   // seg 5..10 == 6 * 10 bytes
    }

    @Test("residentIndexRanges is empty when the cache is empty")
    func residentRangesEmpty() {
        let c = SegmentCache()
        defer { c.close() }
        #expect(c.residentIndexRanges().isEmpty)
    }

    @Test("residentIndexRanges reports one stored segment")
    func residentRangesOneSegment() {
        let c = SegmentCache()
        defer { c.close() }
        c.store(index: 3, data: makeData(10))
        #expect(c.residentIndexRanges() == [3...3])
    }

    @Test("residentIndexRanges merges adjacent segments")
    func residentRangesAdjacentSegments() {
        let c = SegmentCache()
        defer { c.close() }
        c.store(index: 3, data: makeData(10))
        c.store(index: 4, data: makeData(10))
        #expect(c.residentIndexRanges() == [3...4])
    }

    @Test("residentIndexRanges preserves separated islands")
    func residentRangesSeparatedSegments() {
        let c = SegmentCache()
        defer { c.close() }
        c.store(index: 1, data: makeData(10))
        c.store(index: 2, data: makeData(10))
        c.store(index: 4, data: makeData(10))
        #expect(c.residentIndexRanges() == [1...2, 4...4])
    }

    @Test("residentIndexRanges reflects evictBelow")
    func residentRangesAfterEviction() {
        let c = SegmentCache()
        defer { c.close() }
        for index in [1, 2, 4] { c.store(index: index, data: makeData(10)) }
        c.evictBelow(2)
        #expect(c.residentIndexRanges() == [2...2, 4...4])
    }

    @Test("Init version resolution picks the highest fromSegment at or below the index")
    func initVersionResolution() {
        let c = SegmentCache()
        defer { c.close() }
        c.setInit(makeData(8, fill: 0))
        c.addInitVersion(makeData(8, fill: 1), fromSegment: 10)
        c.addInitVersion(makeData(8, fill: 2), fromSegment: 20)
        #expect(c.initVersionID(forSegment: 5) == 0)
        #expect(c.initVersionID(forSegment: 10) == 1)
        #expect(c.initVersionID(forSegment: 15) == 1)
        #expect(c.initVersionID(forSegment: 25) == 2)
        #expect(c.initData(versionID: 0)?.first == 0)
        #expect(c.initData(versionID: 1)?.first == 1)
        #expect(c.initData(versionID: 2)?.first == 2)
    }

    @Test("addInitVersion is idempotent on fromSegment (updates in place)")
    func initVersionIdempotent() {
        let c = SegmentCache()
        defer { c.close() }
        c.addInitVersion(makeData(8, fill: 1), fromSegment: 10)
        c.addInitVersion(makeData(8, fill: 9), fromSegment: 10)
        #expect(c.initVersionID(forSegment: 12) == 1)
        #expect(c.initData(versionID: 1)?.first == 9)
    }

    @Test("close clears all bookkeeping")
    func closeClears() {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        c.store(index: 0, data: makeData(100))
        c.close()
        #expect(c.count == 0)
        #expect(c.totalBytes == 0)
        #expect(c.highestStoredIndex == -1)
        #expect(c.peek(index: 0) == nil)
    }

    @Test("contiguousForwardFrontier stops at the first gap ahead of target")
    func contiguousForwardFrontierStopsAtGap() {
        let c = SegmentCache(forwardWindow: 200, backwardWindow: 20)
        defer { c.close() }
        // Resident: 5,6,7,8 then a hole at 9, then 10.
        for i in [5, 6, 7, 8, 10] { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.declareTarget(5)
        #expect(c.contiguousForwardFrontier(from: 5) == 8)   // stops before the hole at 9
        #expect(c.contiguousForwardFrontier(from: 7) == 8)
        #expect(c.contiguousForwardFrontier(from: 8) == 8)
        #expect(c.contiguousForwardFrontier(from: 9) == 8)   // 9 absent -> targetIdx - 1
        #expect(c.contiguousForwardFrontier(from: 99) == 98) // fully absent -> targetIdx - 1
    }

    @Test("awaitInit succeeds immediately if already stored or waits for async arrival")
    func awaitInitSuccess() {
        let c = SegmentCache()
        defer { c.close() }
        #expect(c.awaitInit(timeout: 0.05) == false)

        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            c.setInit(self.makeData(16))
        }
        #expect(c.awaitInit(timeout: 5.0) == true)
        // Immediate return once cached
        #expect(c.awaitInit(timeout: 0.05) == true)
    }

    @Test("awaitSegment succeeds immediately if already stored or waits for async arrival")
    func awaitSegmentSuccess() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { c.close() }
        #expect(c.awaitSegment(index: 5, timeout: 0.05) == false)

        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            c.store(index: 5, data: self.makeData(64))
        }
        #expect(c.awaitSegment(index: 5, timeout: 5.0) == true)
        // Immediate return once cached
        #expect(c.awaitSegment(index: 5, timeout: 0.05) == true)
    }
}

private final class ColdVODPrimingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func store(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

@Suite("ColdVODStartupPrimingTests")
struct ColdVODStartupPrimingTests {
    private func makeCache() -> SegmentCache {
        SegmentCache(forwardWindow: 4, backwardWindow: 4)
    }

    @Test("Cold VOD priming waits for the second finalized segment")
    func waitsForSecondFinalizedSegment() {
        let cache = makeCache()
        defer { cache.close() }
        cache.setInit(Data([0x01]))

        let finished = DispatchSemaphore(value: 0)
        let result = ColdVODPrimingResult()
        Thread.detachNewThread {
            result.store(HLSVideoEngine.primeColdVODStartupSegments(
                cache: cache,
                plannedSegmentCount: 8,
                timeout: 2.0
            ))
            finished.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        cache.store(index: 0, data: Data([0x10]))
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)

        cache.store(index: 1, data: Data([0x11]))
        #expect(finished.wait(timeout: .now() + 1.0) == .success)
        #expect(result.value == true)
    }

    @Test("Ready cache returns immediately and one-segment plans clamp to seg0")
    func readyCacheAndShortPlan() {
        let ready = makeCache()
        defer { ready.close() }
        ready.setInit(Data([0x01]))
        ready.store(index: 0, data: Data([0x10]))
        ready.store(index: 1, data: Data([0x11]))

        let readyStart = Date()
        #expect(HLSVideoEngine.primeColdVODStartupSegments(cache: ready, plannedSegmentCount: 2))
        #expect(Date().timeIntervalSince(readyStart) < 0.25)

        let short = makeCache()
        defer { short.close() }
        short.setInit(Data([0x01]))
        short.store(index: 0, data: Data([0x10]))

        let shortStart = Date()
        #expect(HLSVideoEngine.primeColdVODStartupSegments(
            cache: short,
            plannedSegmentCount: 1,
            timeout: 0.5
        ))
        #expect(Date().timeIntervalSince(shortStart) < 0.25)
    }

    @Test("Both segments share one overall startup deadline")
    func usesOneSharedDeadline() {
        let cache = makeCache()
        defer { cache.close() }
        cache.setInit(Data([0x01]))

        let started = Date()
        let finished = DispatchSemaphore(value: 0)
        let result = ColdVODPrimingResult()
        Thread.detachNewThread {
            result.store(HLSVideoEngine.primeColdVODStartupSegments(
                cache: cache,
                plannedSegmentCount: 2,
                timeout: 1.0
            ))
            finished.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        Thread.sleep(forTimeInterval: 0.65)
        cache.store(index: 0, data: Data([0x10]))
        #expect(finished.wait(timeout: .now() + 0.5) == .success)
        #expect(result.value == false)
        #expect(Date().timeIntervalSince(started) < 1.4)
    }

    @Test("Closing the segment cache releases a waiting cold-start prime")
    func closeUnblocksPrime() {
        let cache = makeCache()
        cache.setInit(Data([0x01]))
        let finished = DispatchSemaphore(value: 0)
        let result = ColdVODPrimingResult()
        Thread.detachNewThread {
            result.store(HLSVideoEngine.primeColdVODStartupSegments(
                cache: cache,
                plannedSegmentCount: 2,
                timeout: 5.0
            ))
            finished.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        cache.close()
        #expect(finished.wait(timeout: .now() + 0.5) == .success)
        #expect(result.value == false)
    }
}

