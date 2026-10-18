import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyPlayerBridgeTests: XCTestCase {
    private final class Engine {}
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    private final class Fixture {
        let engine = Engine()
        var stamp: WatchPartyPlayerStamp
        var current = true
        var rate: Float = 1
        var maximumRate: Float = 4
        var supportedRate: Float = 4
        var calls: [String] = []
        var targets: [Int64] = []
        let nativeGate: Gate?
        let timeoutGate: Gate?
        lazy var bridge = WatchPartyPlayerBridge(isCurrent: { [weak self] in self?.current == true },
            currentStamp: { [weak self] in self?.stamp }, issueSeek: { [weak self] target, _ in
                guard let self else { throw WatchPartyPlayerBridgeError.staleOperation }
                self.targets.append(target)
                if let gate = self.nativeGate { await gate.wait() }
            }, transport: { [weak self] paused, rate, _ in
                guard let self else { throw WatchPartyPlayerBridgeError.staleOperation }
                if let rate { self.rate = min(rate, self.maximumRate); self.calls.append("rate") }
                if let paused { self.calls.append(paused ? "pause" : "play") }
                return self.rate
            }, maximumRate: { [weak self] in self?.supportedRate ?? 0 }, sleep: { [weak self] _ in
                if let gate = self?.timeoutGate { await gate.wait() }
                else { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            })

        init(nativeGate: Gate? = nil, timeoutGate: Gate? = nil) {
            self.nativeGate = nativeGate
            self.timeoutGate = timeoutGate
            stamp = WatchPartyPlayerStamp(generation: 1, engineID: ObjectIdentifier(engine), mediaKey: "movie|test||")
        }

        func sample(position: Int64 = 0, duration: Int64 = 100_000, loading: Bool = false,
                    coherent: Bool = true, seeking: Bool = false) {
            bridge.observe(WatchPartyPlayerSample(stamp: stamp, positionMs: position, durationMs: duration,
                                                 rate: rate, paused: true, loading: loading,
                                                 coherent: coherent, seeking: seeking))
        }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Expected controlled task transition", file: file, line: line)
    }

    private func seek(_ f: Fixture, target: Int64 = 10_000) -> Task<WatchPartyPlayerReceipt, Error> {
        Task { @MainActor in
            try await f.bridge.apply(WatchPartyPlayerEffect(paused: false, rate: 1, seekToMs: target), origin: .remoteRoom)
        }
    }

    func testNativeCompletionAndANewerCoherentSampleAreBothRequired() async throws {
        let f = Fixture(nativeGate: Gate())
        // Use the fixture's controlled engine call; no actual player/network is involved.
        f.sample()
        let task = seek(f)
        await until { f.nativeGate?.entered == true }
        f.sample(position: 10_000)
        XCTAssertTrue(f.bridge.isSeeking)
        XCTAssertFalse(f.bridge.awaitsSeekSample)
        XCTAssertEqual(f.calls, ["pause"])
        f.nativeGate?.release()
        await until { f.bridge.awaitsSeekSample }
        // The target sample seen before the engine returned is not reused as completion.
        XCTAssertTrue(f.bridge.isSeeking)
        f.sample(position: 10_000)
        let receipt = try await task.value
        XCTAssertEqual(receipt.confirmedSeekPositionMs, 10_000)
        XCTAssertEqual(receipt.origin, .remoteRoom)
        XCTAssertEqual(f.calls, ["pause", "rate", "play"])
        f.bridge.stop()
    }

    func testQueuedCommandReturnAloneNeverConfirmsSeek() async throws {
        let f = Fixture()
        f.sample()
        let task = seek(f)
        await until { f.bridge.awaitsSeekSample }
        f.sample(position: 0)
        f.sample(position: 10_000, loading: true)
        f.sample(position: 10_000, coherent: false)
        f.sample(position: 10_000, seeking: true)
        f.sample(position: 10_501)
        XCTAssertTrue(f.bridge.isSeeking)
        XCTAssertEqual(f.calls, ["pause"])
        f.sample(position: 10_500)
        let receipt = try await task.value
        XCTAssertEqual(receipt.confirmedSeekPositionMs, 10_500)
        f.bridge.stop()
    }

    func testSourceGenerationChangeCannotResumeNewSource() async {
        let f = Fixture()
        f.sample()
        let task = seek(f)
        await until { f.bridge.awaitsSeekSample }
        f.stamp = WatchPartyPlayerStamp(generation: 2, engineID: ObjectIdentifier(f.engine), mediaKey: "movie|test||")
        f.sample(position: 10_000)
        do { _ = try await task.value; XCTFail("Stale source accepted") }
        catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .staleOperation) }
        XCTAssertEqual(f.calls, ["pause"])
        f.bridge.stop()
    }

    func testBackendReplacementWithSameGenerationCannotResumeNewEngine() async {
        let f = Fixture(), replacement = Engine()
        f.sample()
        let task = seek(f)
        await until { f.bridge.awaitsSeekSample }
        f.stamp = WatchPartyPlayerStamp(generation: 1, engineID: ObjectIdentifier(replacement), mediaKey: "movie|test||")
        f.sample(position: 10_000)
        do { _ = try await task.value; XCTFail("Stale engine accepted") }
        catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .staleOperation) }
        XCTAssertFalse(f.calls.contains("play"))
        f.bridge.stop()
    }

    func testContextLossCannotResumeEvenWhenTargetArrives() async {
        let f = Fixture()
        f.sample()
        let task = seek(f)
        await until { f.bridge.awaitsSeekSample }
        f.current = false
        f.sample(position: 10_000)
        do { _ = try await task.value; XCTFail("Obsolete membership accepted") }
        catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .staleOperation) }
        XCTAssertFalse(f.calls.contains("play"))
        f.bridge.stop()
    }

    func testCancellationResumesWaiterOnceAndLateNativeReturnCannotPlay() async {
        let f = Fixture(nativeGate: Gate())
        f.sample()
        let task = seek(f)
        await until { f.nativeGate?.entered == true }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled seek accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        f.nativeGate?.release()
        f.sample(position: 10_000)
        XCTAssertFalse(f.calls.contains("play"))
        f.bridge.stop()
    }

    func testTimeoutLeavesPlaybackPausedWithoutAutomaticRetry() async {
        let f = Fixture(timeoutGate: Gate())
        f.sample()
        let task = seek(f)
        await until { f.timeoutGate?.entered == true && f.bridge.awaitsSeekSample }
        f.timeoutGate?.release()
        do { _ = try await task.value; XCTFail("Timed out seek accepted") }
        catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .timedOut) }
        f.sample(position: 10_000)
        XCTAssertEqual(f.targets.count, 1)
        XCTAssertFalse(f.calls.contains("play"))
        f.bridge.stop()
    }

    func testBusyOperationDoesNotIssueConcurrentSeek() async {
        let f = Fixture()
        f.sample()
        let task = seek(f)
        await until { f.bridge.awaitsSeekSample }
        do {
            _ = try await f.bridge.apply(WatchPartyPlayerEffect(paused: true, rate: 1, seekToMs: 20_000), origin: .localUser)
            XCTFail("Concurrent operation accepted")
        } catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .busy) }
        XCTAssertEqual(f.targets, [10_000])
        f.bridge.stop()
        _ = try? await task.value
    }

    func testSeekIsClampedBeforeDurationAndReceiptUsesActualPosition() async throws {
        let f = Fixture()
        f.sample(duration: 100)
        let task = seek(f, target: .max)
        await until { f.bridge.awaitsSeekSample }
        XCTAssertEqual(f.targets, [99])
        f.sample(position: 99, duration: 100)
        let receipt = try await task.value
        XCTAssertEqual(receipt.confirmedSeekPositionMs, 99)
        f.bridge.stop()
    }

    func testTemporaryRateRestoresCanonicalBaseDespiteIntermediateSamples() async throws {
        let f = Fixture()
        f.sample()
        _ = try await f.bridge.apply(WatchPartyPlayerEffect(paused: false, rate: 1.5), origin: .remoteRoom)
        XCTAssertEqual(try f.bridge.setTemporaryRate(1.575), 1.575)
        f.sample(position: 1_000)
        XCTAssertTrue(f.bridge.isApplyingTemporaryRate)
        f.bridge.clearTemporaryRate()
        XCTAssertEqual(f.rate, 1.5)
        XCTAssertFalse(f.bridge.isApplyingTemporaryRate)
        f.bridge.stop()
    }

    func testSourceReplacementNeverRestoresOldTemporaryRateIntoSuccessor() throws {
        let f = Fixture()
        f.sample()
        _ = try f.bridge.setTemporaryRate(1.05)
        f.stamp = WatchPartyPlayerStamp(generation: 2, engineID: ObjectIdentifier(f.engine), mediaKey: "movie|next||")
        f.rate = 2
        f.sample()
        f.bridge.clearTemporaryRate()
        XCTAssertEqual(f.rate, 2)
        f.bridge.stop()
    }

    func testInvalidRateCannotReachTransport() async {
        let f = Fixture()
        f.sample()
        for rate in [Float.nan, Float.infinity, 0, 4.1] {
            do { _ = try await f.bridge.apply(WatchPartyPlayerEffect(paused: false, rate: rate), origin: .localUser); XCTFail("Invalid rate") }
            catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .invalidRate) }
        }
        XCTAssertTrue(f.calls.isEmpty)
        f.bridge.stop()
    }

    func testReceiptPreservesOriginAndEngineAppliedRate() async throws {
        let f = Fixture()
        f.maximumRate = 1.5
        f.sample()
        let receipt = try await f.bridge.apply(WatchPartyPlayerEffect(paused: true, rate: 4), origin: .waiting)
        XCTAssertEqual(receipt.appliedRate, 1.5)
        XCTAssertEqual(receipt.origin, .waiting)
        XCTAssertNil(receipt.confirmedSeekPositionMs)
        XCTAssertFalse(f.calls.contains("play"))
        f.bridge.stop()
    }

    func testStopIsIdempotentAndLateSampleCannotReviveOperation() async {
        let f = Fixture()
        f.sample()
        let task = seek(f)
        await until { f.bridge.awaitsSeekSample }
        f.bridge.stop()
        f.bridge.stop()
        _ = try? await task.value
        f.sample(position: 10_000)
        XCTAssertNil(f.bridge.sample)
        XCTAssertFalse(f.calls.contains("play"))
    }

    func testNewerRoomRevisionRevokesOldEffectEvenOnTheSameSource() async {
        let f = Fixture()
        var admitted = true
        f.sample()
        let task = Task { @MainActor in
            try await f.bridge.apply(WatchPartyPlayerEffect(paused: false, rate: 1, seekToMs: 10_000),
                                     origin: .remoteRoom, isAdmitted: { admitted })
        }
        await until { f.bridge.awaitsSeekSample }
        admitted = false
        f.sample(position: 10_000)
        do { _ = try await task.value; XCTFail("Revoked room state accepted") }
        catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .staleOperation) }
        XCTAssertFalse(f.calls.contains("play"))
        f.bridge.stop()
    }

    func testUnreadySampleCannotReachTransport() async {
        let f = Fixture()
        f.sample(loading: true)
        do {
            _ = try await f.bridge.apply(WatchPartyPlayerEffect(paused: false, rate: 1), origin: .remoteRoom)
            XCTFail("Loading engine accepted")
        } catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .notReady) }
        XCTAssertTrue(f.calls.isEmpty)
        f.bridge.stop()
    }

    func testKnownUnsupportedCanonicalRateIsRejectedBeforeTransport() async throws {
        let f = Fixture()
        f.supportedRate = 1.5
        f.sample()
        do {
            _ = try await f.bridge.apply(WatchPartyPlayerEffect(paused: false, rate: 2), origin: .remoteRoom)
            XCTFail("Unsupported rate accepted")
        } catch { XCTAssertEqual(error as? WatchPartyPlayerBridgeError, .unsupportedRate) }
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertEqual(try f.bridge.setTemporaryRate(2), 1.5)
        f.bridge.stop()
    }
}
