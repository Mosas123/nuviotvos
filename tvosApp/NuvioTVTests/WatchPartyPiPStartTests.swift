import XCTest
@testable import NuvioTV

final class WatchPartyPiPStartTests: XCTestCase {
    func testFailedStartNeverTransfersFullscreenOwnershipAndAllowsRetry() {
        var state = PlayerPiPStartState()
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.isStarting)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.fail())
        XCTAssertFalse(state.isInProgress)
        XCTAssertFalse(state.stop())
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.confirm())
        XCTAssertTrue(state.isActive)
    }

    func testRepeatedStartDoesNotRequestAnotherTransition() {
        var state = PlayerPiPStartState()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertTrue(state.confirm())
        XCTAssertFalse(state.confirm())
        XCTAssertFalse(state.begin())
        XCTAssertTrue(state.isActive)
    }

    func testCancelBeforeConfirmationKeepsFullscreenSession() {
        var state = PlayerPiPStartState()
        state.begin()
        XCTAssertFalse(state.stop())
        XCTAssertFalse(state.confirm())
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.begin())
    }

    func testLateFailureCannotRevokeConfirmedWindow() {
        var state = PlayerPiPStartState()
        state.begin()
        XCTAssertTrue(state.confirm())
        XCTAssertFalse(state.fail())
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.stop())
        XCTAssertFalse(state.stop())
    }

    func testStopAfterFailureDoesNotReportAClosedFloatingWindow() {
        var state = PlayerPiPStartState()
        state.begin()
        XCTAssertTrue(state.fail())
        XCTAssertFalse(state.stop())
        XCTAssertFalse(state.fail())
        XCTAssertFalse(state.confirm())
        XCTAssertFalse(state.isInProgress)
    }
}

final class WatchPartyPiPRestoreTests: XCTestCase {
    @MainActor
    func testUIAcknowledgementWaitsForFullscreenSurface() throws {
        let request = PlayerPiPRestoreRequest()
        var results: [Bool] = []
        let token = try XCTUnwrap(request.begin { results.append($0) })
        request.acceptUIResult(true, for: token)
        XCTAssertTrue(results.isEmpty)
        request.surfaceDidRebind()
        XCTAssertEqual(results, [true])
        request.surfaceDidRebind()
        request.acceptUIResult(true, for: token)
        XCTAssertEqual(results, [true])
    }

    @MainActor
    func testSurfaceMayArriveBeforeUIAcknowledgement() throws {
        let request = PlayerPiPRestoreRequest()
        var results: [Bool] = []
        let token = try XCTUnwrap(request.begin { results.append($0) })
        request.surfaceDidRebind()
        XCTAssertTrue(results.isEmpty)
        request.acceptUIResult(true, for: token)
        XCTAssertEqual(results, [true])
    }

    @MainActor
    func testSystemExpandJoinsAppRequestWithoutSecondPresentation() throws {
        let request = PlayerPiPRestoreRequest()
        var app: [Bool] = []
        var system: [Bool] = []
        let token = try XCTUnwrap(request.begin { app.append($0) })
        XCTAssertNil(request.begin { system.append($0) })
        request.acceptUIResult(true, for: token)
        XCTAssertTrue(app.isEmpty)
        XCTAssertTrue(system.isEmpty)
        request.surfaceDidRebind()
        XCTAssertEqual(app, [true])
        XCTAssertEqual(system, [true])
        var repeated: [Bool] = []
        XCTAssertNil(request.begin { repeated.append($0) })
        XCTAssertEqual(repeated, [true])
    }

    @MainActor
    func testFailedUICompletesWithoutWaitingForSurfaceAndCanRetry() throws {
        let request = PlayerPiPRestoreRequest()
        var results: [Bool] = []
        let old = try XCTUnwrap(request.begin { results.append($0) })
        request.acceptUIResult(false, for: old)
        XCTAssertEqual(results, [false])
        request.cancel()
        let retry = try XCTUnwrap(request.begin { results.append($0) })
        request.surfaceDidRebind()
        request.acceptUIResult(true, for: retry)
        XCTAssertEqual(results, [false, true])
    }

    @MainActor
    func testCancellationRejectsLateResultForPreviousSession() throws {
        let request = PlayerPiPRestoreRequest()
        var oldResults: [Bool] = []
        var newResults: [Bool] = []
        let old = try XCTUnwrap(request.begin { oldResults.append($0) })
        request.surfaceDidRebind()
        request.cancel()
        XCTAssertEqual(oldResults, [false])
        let next = try XCTUnwrap(request.begin { newResults.append($0) })
        request.acceptUIResult(true, for: old)
        request.acceptUIResult(true, for: next)
        XCTAssertTrue(newResults.isEmpty) // The old surface readiness was cleared.
        request.surfaceDidRebind()
        XCTAssertEqual(newResults, [true])
        XCTAssertEqual(oldResults, [false])
    }

    @MainActor
    func testCancellationDrainsJoinedCallbacksExactlyOnce() throws {
        let request = PlayerPiPRestoreRequest()
        var results: [Bool] = []
        let token = try XCTUnwrap(request.begin { results.append($0) })
        XCTAssertNil(request.begin { results.append($0) })
        request.cancel()
        request.cancel()
        request.acceptUIResult(true, for: token)
        request.surfaceDidRebind()
        XCTAssertEqual(results, [false, false])
    }

    @MainActor
    func testCancellationAllowsReentrantSuccessor() throws {
        let request = PlayerPiPRestoreRequest()
        var nextToken: UUID?
        var results: [Bool] = []
        _ = try XCTUnwrap(request.begin { success in
            results.append(success)
            nextToken = request.begin { results.append($0) }
        })
        request.cancel()
        let token = try XCTUnwrap(nextToken)
        request.surfaceDidRebind()
        request.acceptUIResult(true, for: token)
        XCTAssertEqual(results, [false, true])
    }
}
