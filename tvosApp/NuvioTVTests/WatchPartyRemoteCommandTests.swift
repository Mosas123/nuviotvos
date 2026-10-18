import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyRemoteCommandTests: XCTestCase {
    func testPlayAndPauseRemainExplicitIntents() {
        guard case .play? = PlayerRemoteIntent.play.localIntent(positionMs: 0, isPlaying: false),
              case .pause? = PlayerRemoteIntent.pause.localIntent(positionMs: 0, isPlaying: true) else {
            return XCTFail("Transport intent lost")
        }
    }

    func testToggleUsesCurrentTransportNotPreviousSample() {
        guard case .pause? = PlayerRemoteIntent.toggle.localIntent(positionMs: 0, isPlaying: true),
              case .play? = PlayerRemoteIntent.toggle.localIntent(positionMs: 0, isPlaying: false) else {
            return XCTFail("Toggle used stale transport")
        }
    }

    func testPositionRejectsNonFiniteAndOverflow() {
        XCTAssertNil(PlayerRemoteIntent.position(.nan).localIntent(positionMs: 0, isPlaying: false))
        XCTAssertNil(PlayerRemoteIntent.position(.infinity).localIntent(positionMs: 0, isPlaying: false))
        XCTAssertNil(PlayerRemoteIntent.position(Double(Int64.max)).localIntent(positionMs: 0, isPlaying: false))
        guard case .seek(let value)? = PlayerRemoteIntent.position(12.5).localIntent(positionMs: 0, isPlaying: false) else {
            return XCTFail("Valid position rejected")
        }
        XCTAssertEqual(value, 12_500)
    }

    func testRelativeSkipClampsAtZero() {
        guard case .seek(let value)? = PlayerRemoteIntent.skip(-10).localIntent(positionMs: 2_000, isPlaying: false) else {
            return XCTFail("Valid skip rejected")
        }
        XCTAssertEqual(value, 0)
    }

    func testRelativeSkipSaturatesAdditionAndRejectsInvalidDelta() {
        guard case .seek(let value)? = PlayerRemoteIntent.skip(10).localIntent(positionMs: .max, isPlaying: false) else {
            return XCTFail("Saturating skip rejected")
        }
        XCTAssertEqual(value, .max)
        XCTAssertNil(PlayerRemoteIntent.skip(.nan).localIntent(positionMs: 0, isPlaying: false))
        XCTAssertNil(PlayerRemoteIntent.skip(.infinity).localIntent(positionMs: 0, isPlaying: false))
    }

    func testStopInvokesOnlyRegisteredRemovalClosuresOnce() {
        let targets = PlayerRemoteCommandTargets()
        let otherOwner = PlayerRemoteCommandTargets()
        var own = 0
        var foreign = 0
        targets.retainRemoval { own += 1 }
        targets.retainRemoval { own += 1 }
        otherOwner.retainRemoval { foreign += 1 }
        targets.stop(); targets.stop()
        XCTAssertEqual(own, 2)
        XCTAssertEqual(foreign, 0)
        otherOwner.stop()
        XCTAssertEqual(foreign, 1)
    }

    func testOldGenerationCannotDeliverAfterStop() {
        let targets = PlayerRemoteCommandTargets()
        let old = targets.generation
        var calls = 0
        targets.stop()
        targets.deliver(.play, generation: old) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
    }

    func testReplacementGenerationDeliversOnlyNewCommand() {
        let targets = PlayerRemoteCommandTargets()
        let old = targets.generation
        var calls = 0
        targets.stop()
        targets.deliver(.play, generation: old) { _ in calls += 1 }
        targets.deliver(.pause, generation: targets.generation) { _ in calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testRemovalReentryCannotDeliverInvalidatedGeneration() {
        let targets = PlayerRemoteCommandTargets()
        let old = targets.generation
        var calls = 0
        targets.retainRemoval { targets.deliver(.play, generation: old) { _ in calls += 1 } }
        targets.stop()
        XCTAssertEqual(calls, 0)
    }

    func testQueuedMainActorCommandCannotCrossReplacement() async {
        let targets = PlayerRemoteCommandTargets()
        let old = targets.generation
        var calls = 0
        let queued = Task { @MainActor in targets.deliver(.play, generation: old) { _ in calls += 1 } }
        targets.stop()
        await queued.value
        XCTAssertEqual(calls, 0)
    }
}
