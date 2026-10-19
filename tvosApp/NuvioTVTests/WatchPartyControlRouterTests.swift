import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyControlRouterTests: XCTestCase {
    private enum Failure: Error { case rejected }
    private final class Engine {}
    @MainActor
    private final class Fixture {
        let engine = Engine()
        var generation: UInt64 = 1
        var current = true
        var loaded = true
        var calls = 0
        var completed = 0
        var errors = 0
        var suspensions: [Bool] = []
        var gate: CheckedContinuation<Void, Never>?
        var shouldWait = false
        var fail = false
        var waitAfterApplied = false
        var publicationGate: CheckedContinuation<Void, Never>?
        var stamp: WatchPartyPlayerStamp? {
            loaded ? WatchPartyPlayerStamp(generation: generation, engineID: ObjectIdentifier(engine), mediaKey: "movie|test||") : nil
        }
        lazy var router = WatchPartyControlRouter(isCurrent: { [weak self] in self?.current == true },
            currentStamp: { [weak self] in self?.stamp }, perform: { [weak self] _, applied in
                guard let self else { throw Failure.rejected }
                self.calls += 1
                if self.shouldWait { await withCheckedContinuation { self.gate = $0 } }
                if self.fail { throw Failure.rejected }
                applied?()
                if self.waitAfterApplied { await withCheckedContinuation { self.publicationGate = $0 } }
            }, suspend: { [weak self] in self?.suspensions.append($0) },
            onError: { [weak self] _ in self?.errors += 1 },
            onCompleted: { [weak self] _ in self?.completed += 1 })
        func release() { let continuation = gate; gate = nil; continuation?.resume() }
        func releasePublication() { let continuation = publicationGate; publicationGate = nil; continuation?.resume() }
        func stop() { router.stop(); release(); releasePublication() }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if condition() { return }; await Task.yield() }
        XCTFail("Expected controlled task transition", file: file, line: line)
    }

    func testOneGestureRunsOnceAndCompletesOnce() async {
        let f = Fixture(); defer { f.stop() }
        XCTAssertEqual(f.router.submit(.play), .accepted)
        await until { f.completed == 1 }
        XCTAssertEqual(f.calls, 1)
        XCTAssertEqual(f.errors, 0)
    }

    func testBusyGestureIsRejectedNotQueued() async {
        let f = Fixture(); f.shouldWait = true; defer { f.stop() }
        XCTAssertEqual(f.router.submit(.seekAndPlay(20_000)), .accepted)
        await until { f.gate != nil }
        XCTAssertEqual(f.router.submit(.play), .busy)
        f.release()
        await until { f.completed == 1 }
        XCTAssertEqual(f.calls, 1)
        XCTAssertEqual(f.errors, 1)
    }

    func testUnavailableSourceAndContextNeverInvokeFallback() async {
        let f = Fixture(); defer { f.stop() }
        f.loaded = false
        XCTAssertEqual(f.router.submit(.play), .unavailable)
        f.loaded = true; f.current = false
        XCTAssertEqual(f.router.submit(.pause), .unavailable)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.calls, 0)
    }

    func testSourceChangeBeforeScheduledExecutionDropsOldGesture() async {
        let f = Fixture(); defer { f.stop() }
        XCTAssertEqual(f.router.submit(.play), .accepted)
        f.generation += 1 // Same membership, different load; no actor yield before this.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.calls, 0)
        XCTAssertEqual(f.completed, 0)
    }

    func testLateReturnAfterStopCannotCompleteOrReportOldError() async {
        let f = Fixture(); f.shouldWait = true; f.fail = true
        XCTAssertEqual(f.router.submit(.play), .accepted)
        await until { f.gate != nil }
        f.stop()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.completed, 0)
        XCTAssertEqual(f.errors, 0)
        XCTAssertEqual(f.router.submit(.play), .unavailable)
    }

    func testSuspensionRevokesBeforeParkingAndDoesNotReplayGesture() async {
        let f = Fixture(); f.shouldWait = true; defer { f.stop() }
        XCTAssertEqual(f.router.submit(.play), .accepted)
        await until { f.gate != nil }
        f.router.setSuspended(true)
        f.router.setSuspended(true)
        XCTAssertEqual(f.router.submit(.pause), .unavailable)
        f.router.setSuspended(false)
        XCTAssertEqual(f.router.submit(.play), .busy) // Old slot remains until actual return.
        f.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.suspensions, [true, false])
        XCTAssertEqual(f.completed, 0)
        XCTAssertEqual(f.calls, 1)
    }

    func testFailedMutationIsReportedOnceWithoutRetry() async {
        let f = Fixture(); f.fail = true; defer { f.stop() }
        XCTAssertEqual(f.router.submit(.speed(2)), .accepted)
        await until { f.errors == 1 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.calls, 1)
        XCTAssertEqual(f.completed, 0)
    }

    func testChangedSourceDuringAwaitSuppressesOldCompletion() async {
        let f = Fixture(); f.shouldWait = true; defer { f.stop() }
        XCTAssertEqual(f.router.submit(.seek(20_000)), .accepted)
        await until { f.gate != nil }
        f.generation += 1
        f.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.completed, 0)
        XCTAssertEqual(f.calls, 1)
    }

    func testSeekConversionRejectsNonFiniteAndOverflowWithoutTrapping() {
        XCTAssertNil(PlayerViewModel.watchPartySeekMilliseconds(.nan))
        XCTAssertNil(PlayerViewModel.watchPartySeekMilliseconds(.infinity))
        XCTAssertNil(PlayerViewModel.watchPartySeekMilliseconds(Double(Int64.max)))
        XCTAssertEqual(PlayerViewModel.watchPartySeekMilliseconds(-5), 0)
        XCTAssertEqual(PlayerViewModel.watchPartySeekMilliseconds(12.345), 12_345)
    }

    func testPiPCompletionWaitsForEngineReceiptNotEnqueue() async {
        let f = Fixture(); f.shouldWait = true; defer { f.stop() }
        var callbacks = 0
        XCTAssertEqual(f.router.submit(.seek(20_000), completion: { callbacks += 1 }), .accepted)
        XCTAssertEqual(callbacks, 0)
        await until { f.gate != nil }
        XCTAssertEqual(callbacks, 0)
        f.release()
        await until { callbacks == 1 }
        f.stop()
        XCTAssertEqual(callbacks, 1)
    }

    func testBusyAndUnavailablePiPCallbacksAreNotStranded() async {
        let f = Fixture(); f.shouldWait = true; defer { f.stop() }
        var callbacks = 0
        _ = f.router.submit(.play)
        await until { f.gate != nil }
        XCTAssertEqual(f.router.submit(.seek(20_000), completion: { callbacks += 1 }), .busy)
        f.current = false
        XCTAssertEqual(f.router.submit(.seek(20_000), completion: { callbacks += 1 }), .unavailable)
        XCTAssertEqual(callbacks, 2)
    }

    func testStopReleasesNativeCallbackBeforeNonCooperativeReturn() async {
        let f = Fixture(); f.shouldWait = true
        var callbacks = 0
        _ = f.router.submit(.seek(20_000), completion: { callbacks += 1 })
        await until { f.gate != nil }
        f.router.stop()
        XCTAssertEqual(callbacks, 1)
        f.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(callbacks, 1)
    }

    func testSourceValidationReleasesNativeCallbackImmediately() async {
        let f = Fixture(); f.shouldWait = true; defer { f.stop() }
        var callbacks = 0
        _ = f.router.submit(.seek(20_000), completion: { callbacks += 1 })
        await until { f.gate != nil }
        f.generation += 1
        f.router.validateContext()
        XCTAssertEqual(callbacks, 1)
        f.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(f.completed, 0)
    }

    func testFailedPiPOperationFinishesWithoutAppliedReceipt() async {
        let f = Fixture(); f.fail = true; defer { f.stop() }
        var callbacks = 0
        var applied = 0
        _ = f.router.submit(.seek(20_000), completion: { callbacks += 1 }, onApplied: { applied += 1 })
        await until { callbacks == 1 }
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(f.errors, 1)
    }

    func testEngineReceiptCanReleasePiPWhilePublicationRemainsPending() async {
        let f = Fixture(); f.waitAfterApplied = true; defer { f.stop() }
        var callbacks = 0
        var applied = 0
        _ = f.router.submit(.seek(20_000), completion: { callbacks += 1 }, onApplied: { applied += 1 })
        await until { f.publicationGate != nil }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(f.completed, 0)
        XCTAssertEqual(f.router.submit(.play), .busy)
        f.releasePublication()
        await until { f.completed == 1 }
        XCTAssertEqual(callbacks, 1)
    }
}
