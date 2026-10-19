import XCTest
@testable import NuvioTV

final class WatchPartyMPVFirstFrameTests: XCTestCase {
    func testPausedInitialRestartCanBecomeReadyWithoutTransportPlay() {
        let readiness = MPVFirstFrameReadiness()
        readiness.arm(playlistEntryID: 11)
        XCTAssertFalse(readiness.isReady)
        // No play flag or duration participates in admitting a real restart.
        XCTAssertTrue(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: true))
        XCTAssertTrue(readiness.isReady)
    }

    func testConfiguredDimensionsWithoutRestartDoNotMarkReady() {
        let readiness = MPVFirstFrameReadiness()
        readiness.arm(playlistEntryID: 11)
        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: false))
        XCTAssertFalse(readiness.isReady)
    }

    func testOldRestartCannotAdmitReplacementIncludingSameURL() {
        let readiness = MPVFirstFrameReadiness()
        readiness.arm(playlistEntryID: 11)
        let previousToken = readiness.token
        readiness.reset()
        readiness.arm(playlistEntryID: 12)
        XCTAssertFalse(readiness.receiveRestart(token: previousToken, playlistEntryID: 11, hasVideoFrame: true))
        // Even an old event read after reset still carries its old entry ID.
        XCTAssertFalse(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: true))
        XCTAssertTrue(readiness.receiveRestart(token: readiness.token, playlistEntryID: 12, hasVideoFrame: true))
    }

    func testMissingPlaylistIdentityFailsClosed() {
        let readiness = MPVFirstFrameReadiness()
        XCTAssertFalse(readiness.matches(token: readiness.token, playlistEntryID: nil))
        XCTAssertFalse(readiness.receiveRestart(token: readiness.token, playlistEntryID: nil, hasVideoFrame: true))
        readiness.arm(playlistEntryID: 11)
        XCTAssertFalse(readiness.receiveRestart(token: readiness.token, playlistEntryID: nil, hasVideoFrame: true))
    }

    func testDuplicateRestartNotifiesOnlyOnce() {
        let readiness = MPVFirstFrameReadiness()
        readiness.arm(playlistEntryID: 11)
        XCTAssertTrue(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: true))
        XCTAssertFalse(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: true))
        XCTAssertTrue(readiness.isReady)
    }

    func testLifecycleSuspensionRejectsQueuedCallbackAndRequiresFreshRestart() {
        let readiness = MPVFirstFrameReadiness()
        readiness.arm(playlistEntryID: 11)
        let oldToken = readiness.token
        XCTAssertTrue(readiness.receiveRestart(token: oldToken, playlistEntryID: 11, hasVideoFrame: true))
        readiness.reset(keepingPlaylistEntry: true)
        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.receiveRestart(token: oldToken, playlistEntryID: 11, hasVideoFrame: true))
        XCTAssertTrue(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: true))
    }

    func testTeardownResetDisarmsTheOldEntry() {
        let readiness = MPVFirstFrameReadiness()
        readiness.arm(playlistEntryID: 11)
        readiness.reset()
        XCTAssertFalse(readiness.matches(token: readiness.token, playlistEntryID: 11))
        XCTAssertFalse(readiness.receiveRestart(token: readiness.token, playlistEntryID: 11, hasVideoFrame: true))
        XCTAssertFalse(readiness.isReady)
    }
}
