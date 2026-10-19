import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyCoordinationTests: XCTestCase {
    func testSessionTickPausesForBufferingAndResumesWhenReady() async throws {
        let ticks = Gate(), remote = Remote(), channel = Channel()
        var uptime: TimeInterval = 0
        let session = makeSession(remote, channel: channel, uptime: { uptime }, sleep: { nanos in
            if nanos == WatchPartyWaitingCoordinator.tickNanoseconds { try await ticks.wait() }
            else { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        })
        defer { session.stop(); ticks.cancelAll(); channel.onState = nil }
        let firstTick = expectation(description: "Coordinator waiting for first tick")
        ticks.onWait = { firstTick.fulfill() }
        try await session.start(snapshot: remote.snapshot)
        await fulfillment(of: [firstTick], timeout: 1)
        channel.receive?(.message(name: "status", payload: Data(#"{"member_id":"other","status":"buffering","media_key":"movie|tt1||"}"#.utf8)))
        let paused = expectation(description: "Waiting pause broadcast")
        let nextTick = expectation(description: "Next coordinator tick")
        ticks.onWait = { nextTick.fulfill() }
        channel.onState = { state in
            XCTAssertTrue(state.paused)
            XCTAssertTrue(state.waiting)
            XCTAssertEqual(state.positionMs, 1_500)
            paused.fulfill()
        }
        uptime = 0.5
        ticks.release()
        await fulfillment(of: [paused, nextTick], timeout: 1)
        ticks.onWait = nil
        channel.receive?(.message(name: "status", payload: Data(#"{"member_id":"other","status":"ready","media_key":"movie|tt1||"}"#.utf8)))
        let resumed = expectation(description: "Waiting resume broadcast")
        channel.onState = { state in
            XCTAssertFalse(state.paused)
            XCTAssertFalse(state.waiting)
            XCTAssertEqual(state.positionMs, 1_500)
            resumed.fulfill()
        }
        uptime = 1
        ticks.release()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(channel.states.map(\.seq), [2, 3])
    }

    func testFourClockSamplesKeepConnectionReadyWhenOneRefinementFails() async throws {
        let remote = Remote(), channel = Channel()
        let refined = expectation(description: "Four total clock RPC samples attempted")
        remote.onClock = { count in if count == 4 { refined.fulfill() } }
        remote.failClockCall = 2
        let session = makeSession(remote, channel: channel, uptime: { 0 }, sleep: { nanos in
            if nanos == 400_000_000 { return }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        defer { session.stop(); remote.onClock = nil }
        try await session.start(snapshot: remote.snapshot)
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(remote.clockCalls, 4)
        XCTAssertEqual(session.connection, .ready)
        XCTAssertTrue(channel.isConnected)
    }

    private func makeSession(_ remote: Remote, channel: Channel, uptime: @escaping () -> TimeInterval,
                             sleep: @escaping WatchPartySession.Sleep) -> WatchPartySession {
        let context = WatchPartyRequestContext(backendIdentity: "https://party.example.test", userID: "user", profileID: "profile", epoch: UUID())
        return WatchPartySession(remote: remote, context: context, deviceID: "device", isCurrent: { _ in true },
                                 makeChannel: { channel }, clock: WatchPartyClock(uptime: uptime, wallTimeMs: { 20_000 }), sleep: sleep)
    }

    @MainActor
    private final class Gate {
        var onWait: (() -> Void)?
        private var continuation: CheckedContinuation<Void, Error>?
        func wait() async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertNil(self.continuation)
                self.continuation = continuation; onWait?()
            }
        }
        func release() { let current = continuation; continuation = nil; current?.resume() }
        func cancelAll() {
            let current = continuation; continuation = nil; onWait = nil
            current?.resume(throwing: CancellationError())
        }
    }

    @MainActor
    private final class Channel: WatchPartyChannel {
        var isConnected = false
        var receive: (@MainActor (WatchPartyChannelEvent) -> Void)?
        var onState: ((WatchPartyPlayback) -> Void)?
        var states: [WatchPartyPlayback] = []
        func open(partyID: String, memberID: String, receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws {
            isConnected = true; self.receive = receive
        }
        func send(event: String, payload: Data) async throws {
            if event == "state" {
                let state = try JSONDecoder().decode(WatchPartyPlayback.self, from: payload)
                states.append(state); onState?(state)
            }
        }
        func track(_ presence: WatchPartyPresence) async throws {}
        func refreshAuth() async throws {}
        func close() { isConnected = false }
    }

    @MainActor
    private final class Remote: WatchPartySessionRemote {
        var clockCalls = 0
        var failClockCall: Int?
        var onClock: ((Int) -> Void)?
        var snapshot: WatchPartySnapshot {
            let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")
            let state = WatchPartyPlayback(seq: 1, memberID: "me", paused: false, positionMs: 1_000, at: 20_000, mediaKey: media.key)
            return WatchPartySnapshot(party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: "me", media: media, playback: state),
                                      members: [WatchPartyMember(id: "me", displayName: "Me"), WatchPartyMember(id: "other", displayName: "Other")], memberID: "me")
        }
        func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { snapshot }
        func clock() async throws -> Int64 {
            clockCalls += 1; onClock?(clockCalls)
            if clockCalls == failClockCall { throw WatchPartyAPIError.transport }
            return 20_000
        }
        func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { WatchPartySnapshot(ok: true) }
        func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { WatchPartySnapshot(ok: true) }
        func update(partyID: String, deviceID: String, media: WatchPartyMedia?, playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot { snapshot }
    }
}
