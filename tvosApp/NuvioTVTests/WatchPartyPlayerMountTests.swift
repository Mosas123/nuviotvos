import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyPlayerMountTests: XCTestCase {
    private func context() -> WatchPartyPlaybackContext {
        WatchPartyPlaybackContext(request: WatchPartyRequestContext(backendIdentity: "https://party.example.test",
                                                                   userID: "user", profileID: "profile", epoch: UUID()),
                                  membershipID: UUID(), roomID: "room", memberID: "member", mediaKey: "movie|test||")
    }

    private func model() -> PlayerViewModel {
        PlayerViewModel(sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
                        adoptsPictureInPictureSession: false)
    }

    func testMountUsesOwnersExactModelAndRejectsForeignOwner() throws {
        let model = model()
        let a = WatchPartyPlayerRuntime(isCurrent: { _ in true }, stopResource: { $0.shutdownForWatchParty() })
        let b = WatchPartyPlayerRuntime(isCurrent: { _ in true }, stopResource: { $0.shutdownForWatchParty() })
        defer { a.invalidate(); b.invalidate() }
        let lease = try a.begin(context: context()) { model }
        let mount = try WatchPartyPlayerMount(runtime: a, lease: lease)
        XCTAssertTrue(mount.viewModel === model)
        XCTAssertThrowsError(try WatchPartyPlayerMount(runtime: b, lease: lease))
    }

    func testRemountDoesNotAuthorizeAnotherInitialLoad() throws {
        let runtime = WatchPartyPlayerRuntime.player(isCurrent: { _ in true })
        defer { runtime.invalidate() }
        let lease = try runtime.begin(context: context()) { model() }
        let mount = try WatchPartyPlayerMount(runtime: runtime, lease: lease)
        let first = try mount.attach()
        XCTAssertTrue(first.startsLoad)
        let second = try mount.attach()
        XCTAssertFalse(second.startsLoad)
        // A late disappear from the previous hierarchy cannot close the second one.
        XCTAssertFalse(mount.detach(first.surface))
        XCTAssertTrue(mount.isCurrent)
    }

    func testInvalidatedMountCannotReattachOrCloseSuccessor() throws {
        let runtime = WatchPartyPlayerRuntime.player(isCurrent: { _ in true })
        defer { runtime.invalidate() }
        let oldLease = try runtime.begin(context: context()) { model() }
        let old = try WatchPartyPlayerMount(runtime: runtime, lease: oldLease)
        let oldSurface = try old.attach().surface
        runtime.invalidate()
        let nextLease = try runtime.begin(context: context()) { model() }
        let next = try WatchPartyPlayerMount(runtime: runtime, lease: nextLease)
        XCTAssertThrowsError(try old.attach())
        XCTAssertFalse(old.detach(oldSurface))
        old.finish()
        XCTAssertTrue(next.isCurrent)
    }

    func testInvalidationClosesModelAndStopsRebinding() throws {
        let runtime = WatchPartyPlayerRuntime.player(isCurrent: { _ in true })
        let model = model()
        let coordinator = model.sessionCoordinator
        let generation = coordinator.loadGeneration
        _ = try runtime.begin(context: context()) { model }
        runtime.invalidate()
        XCTAssertGreaterThan(coordinator.loadGeneration, generation)
        XCTAssertEqual(model.status, .idle)
        XCTAssertFalse(model.rebindWatchPartyFullscreen())
        let after = coordinator.loadGeneration
        model.shutdownForWatchParty()
        XCTAssertEqual(coordinator.loadGeneration, after)
    }

    func testUnloadedModelCannotPretendFullscreenWasRestored() {
        let model = model()
        defer { model.shutdownForWatchParty() }
        let before = model.sessionCoordinator.loadGeneration
        XCTAssertFalse(model.rebindWatchPartyFullscreen())
        XCTAssertEqual(model.sessionCoordinator.loadGeneration, before)
    }

    func testBridgeWithoutControlBindingFailsClosedForNormalTransport() throws {
        let model = model()
        defer { model.shutdownForWatchParty() }
        let initialStatus = model.status
        let initialSpeed = model.playbackSpeed
        _ = try model.attachWatchPartyPlayerBridge(isCurrent: { true })
        model.play()
        model.pause()
        model.togglePlayPause()
        model.seek(to: 30)
        model.setSpeed(.normal)
        XCTAssertEqual(model.status, initialStatus)
        XCTAssertEqual(model.playbackSpeed, initialSpeed)
        XCTAssertNotNil(model.playerToast)
    }

    func testPartyPiPEntryRemainsDisabledWithoutEligibleSoftwareSource() throws {
        let model = model()
        defer { model.shutdownForWatchParty() }
        _ = try model.attachWatchPartyPlayerBridge(isCurrent: { true })
        XCTAssertFalse(model.isPictureInPictureSupported)
        model.startPictureInPicture()
        XCTAssertNotNil(model.playerToast)
    }

    func testContextLossMakesExistingMountInertAndTeardownStillWorks() throws {
        var current = true
        let runtime = WatchPartyPlayerRuntime.player(isCurrent: { _ in current })
        let lease = try runtime.begin(context: context()) { model() }
        let mount = try WatchPartyPlayerMount(runtime: runtime, lease: lease)
        let attachment = try mount.attach()
        current = false
        XCTAssertFalse(mount.isCurrent)
        XCTAssertThrowsError(try mount.attach())
        XCTAssertTrue(mount.detach(attachment.surface))
        XCTAssertEqual(runtime.phase, .idle)
    }
}
