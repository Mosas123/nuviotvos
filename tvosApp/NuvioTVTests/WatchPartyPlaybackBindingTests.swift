import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyPlaybackBindingTests: XCTestCase {
    private final class Engine {}
    private enum Failure: Error { case network, engine }

    @MainActor
    private final class Room: WatchPartyPlaybackRoom {
        var bindingState: WatchPartyBindingRoomState?
        var now: Int64 = 1_000
        var publications: [(Bool, Int64, Float)] = []
        var statuses: [WatchPartyPresence] = []
        var observers: [UUID: @MainActor () -> Void] = [:]
        var failPublish = false

        init(hostOnly: Bool = false, host: String = "host", paused: Bool = true, position: Int64 = 10_000) {
            bindingState = WatchPartyBindingRoomState(roomID: "room", memberID: "me", mediaKey: "movie|tt1||",
                hostMemberID: host, hostOnly: hostOnly, connected: true,
                playback: WatchPartyPlayback(seq: 1, memberID: host, paused: paused, positionMs: position,
                                              at: 1_000, mediaKey: "movie|tt1||"))
        }
        func nowMs() -> Int64 { now }
        func observeChanges(_ callback: @escaping @MainActor () -> Void) -> UUID {
            let id = UUID(); observers[id] = callback; return id
        }
        func removeChangeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
        func notify() { for callback in Array(observers.values) { callback() } }
        func emit(_ playback: WatchPartyPlayback?) {
            guard let s = bindingState else { return }
            bindingState = WatchPartyBindingRoomState(roomID: s.roomID, memberID: s.memberID, mediaKey: s.mediaKey,
                hostMemberID: s.hostMemberID, hostOnly: s.hostOnly, connected: s.connected, playback: playback)
            notify()
        }
        func connection(_ value: Bool) {
            guard let s = bindingState else { return }
            bindingState = WatchPartyBindingRoomState(roomID: s.roomID, memberID: s.memberID, mediaKey: s.mediaKey,
                hostMemberID: s.hostMemberID, hostOnly: s.hostOnly, connected: value, playback: s.playback)
            notify()
        }
        func lockControls() {
            guard let s = bindingState else { return }
            bindingState = WatchPartyBindingRoomState(roomID: s.roomID, memberID: s.memberID, mediaKey: s.mediaKey,
                hostMemberID: "host", hostOnly: true, connected: s.connected, playback: s.playback)
            notify()
        }
        func publish(paused: Bool, positionMs: Int64, rate: Float, waiting: Bool) async throws {
            publications.append((paused, positionMs, rate))
            if failPublish { throw Failure.network }
            let seq = (bindingState?.playback?.seq ?? 0) + 1
            emit(WatchPartyPlayback(seq: seq, memberID: "me", paused: paused, positionMs: positionMs,
                                   rate: rate, at: now, mediaKey: "movie|tt1||", waiting: waiting))
        }
        func setPresence(status: WatchPartyMemberStatus, mediaKey: String?, behindMs: Int64?) async throws {
            statuses.append(WatchPartyPresence(memberID: "me", status: status, mediaKey: mediaKey, behindMs: behindMs))
            notify() // This must not revoke a playback effect.
        }
    }

    @MainActor
    private final class Fixture {
        let room: Room
        let engine = Engine()
        var generation: UInt64 = 1
        var position: Int64 = 10_000
        var rate: Float = 1
        var paused = true
        var loading = false
        var coherent = true
        var rendered = true
        var failed = false
        var current = true
        var time: TimeInterval = 0
        var seekTargets: [Int64] = []
        var playCalls = 0
        var failSeek = false
        var errors: [Error] = []
        var binding: WatchPartyPlaybackBinding?
        var stamp: WatchPartyPlayerStamp {
            WatchPartyPlayerStamp(generation: generation, engineID: ObjectIdentifier(engine), mediaKey: "movie|tt1||")
        }
        lazy var bridge = WatchPartyPlayerBridge(isCurrent: { [weak self] in self?.current == true },
            currentStamp: { [weak self] in self?.stamp }, issueSeek: { [weak self] target, _ in
                guard let self else { throw Failure.engine }
                self.seekTargets.append(target)
                if self.failSeek { throw Failure.engine }
            }, transport: { [weak self] paused, rate, _ in
                guard let self else { throw Failure.engine }
                if let rate { self.rate = rate }
                if let paused { self.paused = paused; if !paused { self.playCalls += 1 } }
                return self.rate
            }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })

        init(room: Room? = nil) { self.room = room ?? Room() }
        func start() throws -> WatchPartyPlaybackBinding {
            let binding = try WatchPartyPlaybackBinding(room: room, bridge: bridge,
                isCurrent: { [weak self] in self?.current == true }, uptime: { [weak self] in self?.time ?? 0 })
            self.binding = binding
            binding.onError = { [weak self] in self?.errors.append($0) }
            return binding
        }
        func tick() {
            bridge.observe(WatchPartyPlayerSample(stamp: stamp, positionMs: position, durationMs: 100_000,
                rate: rate, paused: paused, loading: loading, coherent: coherent, seeking: false,
                rendered: rendered, failed: failed))
        }
        func stop() { binding?.stop() }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if condition() { return }; await Task.yield() }
        XCTFail("Expected controlled task transition", file: file, line: line)
    }

    private func settle(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            await Task.yield()
            if f.bridge.awaitsSeekSample, let target = f.seekTargets.last { f.position = target; f.tick() }
            if f.binding?.isSynchronizing == false { return }
        }
        XCTFail("Binding did not settle", file: file, line: line)
    }

    func testRemotePauseAndSamplesNeverPublishAnEcho() async throws {
        let f = Fixture(); _ = try f.start(); defer { f.stop() }
        f.paused = false
        f.tick(); await settle(f)
        XCTAssertTrue(f.paused)
        for _ in 0..<20 { f.time += 0.5; f.tick(); await Task.yield() }
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testRemoteSeekMustConfirmBeforePlayAndDoesNotPublish() async throws {
        let f = Fixture(room: Room(paused: false, position: 20_000)); _ = try f.start(); defer { f.stop() }
        f.position = 0
        f.tick()
        await until { f.bridge.awaitsSeekSample }
        XCTAssertEqual(f.playCalls, 0)
        f.position = 20_000; f.tick(); await settle(f)
        XCTAssertFalse(f.paused)
        XCTAssertEqual(f.seekTargets, [20_000])
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testNewerRoomStateRevokesInFlightPlayAndAppliesLatestOnly() async throws {
        let f = Fixture(room: Room(paused: false, position: 30_000)); _ = try f.start(); defer { f.stop() }
        f.tick()
        await until { f.bridge.awaitsSeekSample }
        f.room.emit(WatchPartyPlayback(seq: 2, memberID: "host", paused: true, positionMs: 5_000,
                                       at: 1_000, mediaKey: "movie|tt1||"))
        await settle(f)
        XCTAssertTrue(f.paused)
        XCTAssertEqual(f.position, 5_000)
        XCTAssertEqual(f.playCalls, 0)
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testAdmittedLocalPlayPublishesExactlyOnce() async throws {
        let f = Fixture(); let binding = try f.start(); defer { f.stop() }
        f.tick(); await settle(f)
        try await binding.perform(.play)
        XCTAssertEqual(f.room.publications.count, 1)
        XCTAssertFalse(f.room.publications[0].0)
        f.tick(); await settle(f)
        for _ in 0..<10 { f.time += 0.5; f.tick(); await Task.yield() }
        XCTAssertEqual(f.room.publications.count, 1)
    }

    func testHostOnlyGuestCannotChangeRoomSpeedOrSeekAhead() async throws {
        let f = Fixture(room: Room(hostOnly: true)); let binding = try f.start(); defer { f.stop() }
        f.tick(); await settle(f)
        for intent in [WatchPartyLocalIntent.speed(2), .seek(30_000), .play] {
            do { try await binding.perform(intent); XCTFail("Locked control accepted") }
            catch { XCTAssertEqual(error as? WatchPartyPlaybackBindingError, .forbidden) }
        }
        XCTAssertTrue(f.room.publications.isEmpty)
        XCTAssertTrue(f.seekTargets.isEmpty)
    }

    func testGuestOwnPauseEntersBehindWithoutPausingRoom() async throws {
        let f = Fixture(room: Room(hostOnly: true, paused: false)); let binding = try f.start(); defer { f.stop() }
        f.paused = false
        f.tick(); await settle(f)
        try await binding.perform(.pause)
        f.tick()
        await until { f.room.statuses.last?.status == .behind }
        XCTAssertTrue(binding.isBehind)
        XCTAssertTrue(f.paused)
        XCTAssertEqual(f.room.bindingState?.playback?.paused, false)
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testGuestRewindAndCatchUpStayLocal() async throws {
        let f = Fixture(room: Room(hostOnly: true, position: 20_000)); let binding = try f.start(); defer { f.stop() }
        f.position = 20_000; f.tick(); await settle(f)
        let rewind = Task { try await binding.perform(.seek(5_000)) }
        await until { f.bridge.awaitsSeekSample }
        await settle(f); try await rewind.value
        XCTAssertTrue(binding.isBehind)
        XCTAssertEqual(f.position, 5_000)
        try await binding.perform(.catchUp)
        await settle(f)
        XCTAssertFalse(binding.isBehind)
        XCTAssertEqual(f.position, 20_000)
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testBehindAutomaticallyRejoinsOnlyWhilePlayingNearRoom() async throws {
        let f = Fixture(room: Room(hostOnly: true, paused: false)); let binding = try f.start(); defer { f.stop() }
        f.paused = false; f.tick(); await settle(f)
        try await binding.perform(.pause)
        f.tick()
        XCTAssertTrue(binding.isBehind)
        f.paused = false; f.tick(); await settle(f)
        XCTAssertFalse(binding.isBehind)
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testPresenceLoadingReadyAndDelayedBufferingAreDeduplicated() async throws {
        let f = Fixture(); _ = try f.start(); defer { f.stop() }
        f.rendered = false; f.loading = true; f.coherent = false; f.tick()
        await until { f.room.statuses.last?.status == .loading }
        f.rendered = true; f.loading = false; f.coherent = true; f.tick(); await settle(f)
        await until { f.room.statuses.last?.status == .ready }
        let count = f.room.statuses.count
        for _ in 0..<5 { f.tick(); await Task.yield() }
        XCTAssertEqual(f.room.statuses.count, count)
        f.time = 0.25; f.loading = true; f.tick()
        await Task.yield()
        XCTAssertEqual(f.room.statuses.last?.status, .ready)
        f.time = 1.5; f.tick()
        await until { f.room.statuses.last?.status == .buffering }
    }

    func testHostSeedsPlaybackOnceOnlyAfterRenderedSample() async throws {
        let room = Room(host: "me"); room.emit(nil)
        let f = Fixture(room: room); _ = try f.start(); defer { f.stop() }
        f.rendered = false; f.tick(); await Task.yield()
        XCTAssertTrue(room.publications.isEmpty)
        f.rendered = true; f.tick(); await settle(f)
        for _ in 0..<10 { f.tick(); await Task.yield() }
        XCTAssertEqual(room.publications.count, 1)
    }

    func testAmbiguousInitialPublishIsNeverRepeatedAutomatically() async throws {
        let room = Room(host: "me"); room.emit(nil); room.failPublish = true
        let f = Fixture(room: room); _ = try f.start(); defer { f.stop() }
        f.tick(); await settle(f)
        for _ in 0..<10 { f.tick(); await Task.yield() }
        XCTAssertEqual(room.publications.count, 1)
        XCTAssertEqual(f.errors.count, 1)
    }

    func testFailedSeekBlocksRetryUntilExplicitRecovery() async throws {
        let f = Fixture(room: Room(position: 30_000)); let binding = try f.start(); defer { f.stop() }
        f.failSeek = true; f.tick(); await settle(f)
        XCTAssertEqual(f.seekTargets.count, 1)
        for _ in 0..<10 { f.time += 0.5; f.tick(); await Task.yield() }
        XCTAssertEqual(f.seekTargets.count, 1)
        f.failSeek = false; binding.retrySynchronization(); await settle(f)
        XCTAssertEqual(f.seekTargets.count, 2)
        XCTAssertEqual(f.position, 30_000)
    }

    func testDisconnectDuringSeekNeverRunsPendingPlay() async throws {
        let f = Fixture(room: Room(paused: false, position: 30_000)); _ = try f.start(); defer { f.stop() }
        f.tick(); await until { f.bridge.awaitsSeekSample }
        f.room.connection(false)
        await settle(f)
        XCTAssertEqual(f.playCalls, 0)
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testDisconnectRestoresTemporaryRateOnSameEngine() async throws {
        let f = Fixture(room: Room(paused: false)); _ = try f.start(); defer { f.stop() }
        f.paused = false; f.tick(); await settle(f)
        f.time = 0.5; f.room.now = 1_300; f.tick()
        XCTAssertEqual(f.rate, 1.05, accuracy: 0.0001)
        f.room.connection(false)
        XCTAssertEqual(f.rate, 1)
    }

    func testTwoSlowSeeksDoNotStartPlaybackOrRepeatForever() async throws {
        let f = Fixture(room: Room(paused: false, position: 20_000)); _ = try f.start(); defer { f.stop() }
        f.tick()
        for count in 1...2 {
            await until { f.bridge.awaitsSeekSample && f.seekTargets.count == count }
            f.position = try XCTUnwrap(f.seekTargets.last)
            f.time += 6; f.room.now += 6_000; f.tick()
        }
        await settle(f)
        XCTAssertEqual(f.seekTargets.count, 2)
        XCTAssertEqual(f.playCalls, 0)
        XCTAssertTrue(f.errors.contains { ($0 as? WatchPartyPlaybackBindingError) == .seekTooSlow })
        for _ in 0..<10 { f.tick(); await Task.yield() }
        XCTAssertEqual(f.seekTargets.count, 2)
    }

    func testControlRevocationDuringLocalSeekCannotPublish() async throws {
        let f = Fixture(); let binding = try f.start(); defer { f.stop() }
        f.tick(); await settle(f)
        let local = Task { try await binding.perform(.seek(30_000)) }
        await until { f.bridge.awaitsSeekSample }
        f.room.lockControls()
        f.tick()
        do { try await local.value; XCTFail("Revoked local seek accepted") }
        catch { XCTAssertTrue(error is CancellationError || (error as? WatchPartyPlayerBridgeError) == .staleOperation) }
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testStopRemovesObserverAndLateSampleCannotPlay() async throws {
        let f = Fixture(room: Room(paused: false, position: 30_000)); let binding = try f.start()
        f.tick(); await until { f.bridge.awaitsSeekSample }
        binding.stop()
        XCTAssertTrue(f.room.observers.isEmpty)
        f.position = 30_000; f.tick()
        await Task.yield()
        XCTAssertEqual(f.playCalls, 0)
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testPresenceNotificationsDoNotRevokePendingSeek() async throws {
        let f = Fixture(room: Room(position: 30_000)); _ = try f.start(); defer { f.stop() }
        f.tick(); await until { f.bridge.awaitsSeekSample }
        try await f.room.setPresence(status: .ready, mediaKey: "movie|tt1||", behindMs: nil)
        f.position = 30_000; f.tick(); await settle(f)
        XCTAssertEqual(f.seekTargets.count, 1)
        XCTAssertTrue(f.errors.isEmpty)
    }

    func testContextLossStopsBindingAndRejectsLocalIntent() async throws {
        let f = Fixture(); let binding = try f.start(); defer { f.stop() }
        f.tick(); await settle(f)
        f.current = false; f.room.notify()
        XCTAssertTrue(f.room.observers.isEmpty)
        do { try await binding.perform(.play); XCTFail("Old context accepted") }
        catch { XCTAssertEqual(error as? WatchPartyPlaybackBindingError, .notReady) }
        XCTAssertTrue(f.room.publications.isEmpty)
    }

    func testMediaChangeRequestsExplicitReplacementWithoutPlayingOldSource() async throws {
        let f = Fixture(); let binding = try f.start(); defer { f.stop() }
        var requested: String?
        binding.onNeedsMedia = { requested = $0 }
        let s = try XCTUnwrap(f.room.bindingState)
        f.room.bindingState = WatchPartyBindingRoomState(roomID: s.roomID, memberID: s.memberID, mediaKey: "movie|tt2||",
            hostMemberID: s.hostMemberID, hostOnly: s.hostOnly, connected: true, playback: nil)
        f.room.notify()
        XCTAssertEqual(requested, "movie|tt2||")
        XCTAssertTrue(f.room.observers.isEmpty)
        XCTAssertTrue(f.room.publications.isEmpty)
        XCTAssertEqual(f.playCalls, 0)
    }
}
