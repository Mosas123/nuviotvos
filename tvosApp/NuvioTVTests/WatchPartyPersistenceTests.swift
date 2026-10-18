import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyPersistenceTests: XCTestCase {
    func testNewGestureMovesDebounceDeadlineAndOnlyLatestStateIsPersisted() async throws {
        let remote = Remote(), delay = Gate()
        var uptime: TimeInterval = 0
        let session = makeSession(remote, uptime: { uptime }, delay: delay)
        defer { session.stop(); delay.cancelAll() }
        try await session.start(snapshot: remote.snapshot)
        let firstWait = expectation(description: "First debounce")
        delay.onWait = { firstWait.fulfill() }
        try await session.publish(paused: true, positionMs: 2_000, rate: 1)
        await fulfillment(of: [firstWait], timeout: 1)
        uptime = 0.5
        try await session.publish(paused: false, positionMs: 3_000, rate: 1)
        let remainingWait = expectation(description: "Moved deadline")
        delay.onWait = { remainingWait.fulfill() }
        uptime = 1.5
        delay.release()
        await fulfillment(of: [remainingWait], timeout: 1)
        XCTAssertTrue(remote.updates.isEmpty)
        XCTAssertEqual(delay.lastDelay, 500_000_000)
        let persisted = expectation(description: "Latest state persisted")
        remote.onUpdate = { _ in persisted.fulfill() }
        delay.onWait = nil
        uptime = 2
        delay.release()
        await fulfillment(of: [persisted], timeout: 1)
        XCTAssertEqual(remote.updates.map(\.seq), [3])
        XCTAssertEqual(remote.updates.first?.positionMs, 3_000)
    }

    func testNewGestureWhileRPCIsInFlightDoesNotStartParallelMutation() async throws {
        let remote = Remote(), delay = Gate(), network = Gate()
        var uptime: TimeInterval = 0
        let session = makeSession(remote, uptime: { uptime }, delay: delay)
        defer { session.stop(); delay.cancelAll(); network.cancelAll(); remote.onUpdate = nil }
        try await session.start(snapshot: remote.snapshot)
        let scheduled = expectation(description: "Debounce scheduled")
        delay.onWait = { scheduled.fulfill() }
        let firstRPC = expectation(description: "First update waiting on network")
        network.onWait = { firstRPC.fulfill() }
        let secondRPC = expectation(description: "Latest update after first completion")
        remote.onUpdate = { value in
            if value.seq == 2 { try await network.wait(1) }
            else { secondRPC.fulfill() }
        }
        try await session.publish(paused: true, positionMs: 2_000, rate: 1)
        await fulfillment(of: [scheduled], timeout: 1)
        delay.onWait = nil
        uptime = 1.5
        delay.release()
        await fulfillment(of: [firstRPC], timeout: 1)
        try await session.publish(paused: false, positionMs: 3_000, rate: 1)
        XCTAssertEqual(remote.updates.count, 1)
        XCTAssertEqual(remote.activeUpdates, 1)
        uptime = 3
        network.release()
        await fulfillment(of: [secondRPC], timeout: 1)
        XCTAssertEqual(remote.updates.map(\.seq), [2, 3])
        XCTAssertEqual(remote.maximumActiveUpdates, 1)
        XCTAssertEqual(session.playback?.seq, 3)
    }

    func testStopCancelsPendingPersistenceBeforeAnyRPC() async throws {
        let remote = Remote(), delay = Gate()
        var uptime: TimeInterval = 0
        let session = makeSession(remote, uptime: { uptime }, delay: delay)
        defer { session.stop(); delay.cancelAll() }
        try await session.start(snapshot: remote.snapshot)
        let scheduled = expectation(description: "Pending persistence")
        delay.onWait = { scheduled.fulfill() }
        try await session.publish(paused: true, positionMs: 2_000, rate: 1)
        await fulfillment(of: [scheduled], timeout: 1)
        session.stop()
        uptime = 10
        delay.release()
        XCTAssertTrue(remote.updates.isEmpty)
        XCTAssertEqual(session.connection, .stopped)
    }

    private func makeSession(_ remote: Remote, uptime: @escaping () -> TimeInterval, delay: Gate) -> WatchPartySession {
        let context = WatchPartyRequestContext(backendIdentity: "https://party.example.test", userID: "user", profileID: "profile", epoch: UUID())
        return WatchPartySession(remote: remote, context: context, deviceID: "device", isCurrent: { _ in true },
                                 makeChannel: { Channel() }, clock: WatchPartyClock(uptime: uptime, wallTimeMs: { 20_000 }),
                                 connectionTasksEnabled: false,
                                 sleep: { nanos in
            if nanos == 0 { return }
            if nanos < 120_000_000_000 { try await delay.wait(nanos) }
            else { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        })
    }

    @MainActor
    private final class Gate {
        var onWait: (() -> Void)?
        var lastDelay: UInt64?
        private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
        func wait(_ delay: UInt64) async throws {
            let id = UUID()
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append((id, continuation)); lastDelay = delay; onWait?()
                }
            }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
        }
        func release() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().1.resume()
        }
        private func cancel(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
        func cancelAll() {
            let pending = waiters; waiters.removeAll()
            for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
            onWait = nil
        }
    }

    @MainActor
    private final class Remote: WatchPartySessionRemote {
        var updates: [WatchPartyPlayback] = []
        var activeUpdates = 0
        var maximumActiveUpdates = 0
        var onUpdate: (@MainActor (WatchPartyPlayback) async throws -> Void)?
        var snapshot: WatchPartySnapshot {
            let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")
            let playback = WatchPartyPlayback(seq: 1, memberID: "me", paused: false, positionMs: 1_000, at: 20_000, mediaKey: media.key)
            return WatchPartySnapshot(party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: "me", media: media, playback: playback),
                                      members: [WatchPartyMember(id: "me", displayName: "Me")], memberID: "me")
        }
        func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { snapshot }
        func clock() async throws -> Int64 { 20_000 }
        func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { WatchPartySnapshot(ok: true) }
        func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { WatchPartySnapshot(ok: true) }
        func update(partyID: String, deviceID: String, media: WatchPartyMedia?, playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot {
            let value = try XCTUnwrap(playback)
            XCTAssertNil(media)
            updates.append(value); activeUpdates += 1; maximumActiveUpdates = max(maximumActiveUpdates, activeUpdates)
            defer { activeUpdates -= 1 }
            try await onUpdate?(value)
            var response = snapshot
            response.party?.playback = value
            return response
        }
    }

    @MainActor
    private final class Channel: WatchPartyChannel {
        var isConnected = false
        func open(partyID: String, memberID: String, receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws { isConnected = true }
        func send(event: String, payload: Data) async throws {}
        func track(_ presence: WatchPartyPresence) async throws {}
        func refreshAuth() async throws {}
        func close() { isConnected = false }
    }
}
