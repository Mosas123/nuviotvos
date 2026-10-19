import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyPiPCompletionTests: XCTestCase {
    func testCompletionIsExactlyOnceIncludingSynchronousReentry() {
        var calls = 0
        var completion: PlayerControlCompletion?
        completion = PlayerControlCompletion { calls += 1; completion?.finish() }
        completion?.finish(); completion?.finish()
        XCTAssertEqual(calls, 1)
    }

    func testTimebaseMustConvergeAfterEngineReceipt() {
        let requests = PlayerPiPRequests()
        var coherent = false
        var calls = 0
        let request = requests.begin({ calls += 1 }, check: { coherent })
        requests.tick()
        XCTAssertEqual(calls, 0)
        request.applied(); request.finished()
        XCTAssertEqual(calls, 0)
        coherent = true; requests.tick()
        XCTAssertEqual(calls, 1)
        request.finished(); request.applied(); requests.tick()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requests.count, 0)
    }

    func testCoherentTimebaseAloneDoesNotMeanNativeSeekReturned() {
        let requests = PlayerPiPRequests()
        var calls = 0
        let request = requests.begin({ calls += 1 }, check: { true })
        requests.tick()
        XCTAssertEqual(calls, 0)
        request.applied()
        XCTAssertEqual(calls, 1)
    }

    func testRejectedOperationFinishesOnceWithoutEngineReceipt() {
        let requests = PlayerPiPRequests()
        var calls = 0
        let request = requests.begin({ calls += 1 }, check: { false })
        request.finished(); request.finished(); requests.cancelAll()
        XCTAssertEqual(calls, 1)
    }

    func testSettlingTimeoutFinishesInsteadOfLeavingSeekingUI() {
        var now: TimeInterval = 1
        let requests = PlayerPiPRequests(uptime: { now })
        var calls = 0
        let request = requests.begin({ calls += 1 }, check: { false })
        request.applied()
        now = 2.9; requests.tick()
        XCTAssertEqual(calls, 0)
        now = 3; requests.tick()
        XCTAssertEqual(calls, 1)
        request.finished()
        XCTAssertEqual(calls, 1)
    }

    func testContextLossReleasesEvenBeforeEngineReturns() {
        let requests = PlayerPiPRequests()
        var valid = true
        var calls = 0
        let request = requests.begin({ calls += 1 }, check: { valid ? false : nil })
        valid = false; requests.tick()
        XCTAssertEqual(calls, 1)
        request.applied(); request.finished()
        XCTAssertEqual(calls, 1)
    }

    func testOldLateCompletionCannotRemoveNewRequest() {
        let requests = PlayerPiPRequests()
        var oldCalls = 0
        var newCalls = 0
        let old = requests.begin({ oldCalls += 1 }, check: { false })
        requests.cancelAll()
        let new = requests.begin({ newCalls += 1 }, check: { true })
        old.applied(); old.finished()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(oldCalls, 1)
        XCTAssertEqual(newCalls, 0)
        new.applied()
        XCTAssertEqual(newCalls, 1)
    }

    func testCancelAllDoesNotEraseRequestCreatedByCompletionReentry() {
        let requests = PlayerPiPRequests()
        var newCalls = 0
        _ = requests.begin({ _ = requests.begin({ newCalls += 1 }, check: { false }) }, check: { false })
        requests.cancelAll()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(newCalls, 0)
        requests.cancelAll()
        XCTAssertEqual(newCalls, 1)
    }
}
