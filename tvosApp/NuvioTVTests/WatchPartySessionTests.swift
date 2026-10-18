import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartySessionTests: XCTestCase {
    private let context = WatchPartyRequestContext(backendIdentity: "https://party.example.test", userID: "user", profileID: "profile", epoch: UUID())

    private func snapshot(hostOnly: Bool = false, host: String = "me", seq: Int64 = 1) -> WatchPartySnapshot {
        let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")
        let playback = WatchPartyPlayback(seq: seq, memberID: host, paused: false, positionMs: 1_000,
                                         at: 20_000, mediaKey: media.key)
        return WatchPartySnapshot(party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: host,
                                                       hostOnly: hostOnly, media: media, playback: playback),
                                  members: [WatchPartyMember(id: "me", displayName: "Me"), WatchPartyMember(id: "other", displayName: "Other")],
                                  memberID: "me", serverTimeMs: 20_000)
    }

    private func session(_ remote: Remote, channels: [Channel], isCurrent: @escaping WatchPartyAPI.ContextValidator = { _ in true }) -> WatchPartySession {
        var index = 0
        return WatchPartySession(remote: remote, context: context, deviceID: "device", isCurrent: isCurrent,
                                 makeChannel: {
            let channel = channels[min(index, channels.count - 1)]
            index += 1
            return channel
        }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
    }

    func testStartupReconcilesBeforeTrackingAndSending() async throws {
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.stop() }
        remote.onHeartbeat = {
            XCTAssertEqual(session.connection, .reconciling)
            XCTAssertFalse(session.canControl)
            XCTAssertTrue(channel.sent.isEmpty)
        }
        defer { remote.onHeartbeat = nil }
        try await session.start(snapshot: snapshot())
        XCTAssertEqual(session.connection, .ready)
        XCTAssertTrue(session.canControl)
        XCTAssertEqual(remote.calls, ["heartbeat", "clock"])
        XCTAssertEqual(channel.operations, ["open", "track", "status", "state_request"])
        XCTAssertEqual(channel.tracked.first?.memberID, "me")
    }

    func testOfflineGestureIsRejectedAndNotReplayedOnFreshChannel() async throws {
        let remote = Remote(snapshot())
        let old = Channel(), fresh = Channel()
        let session = session(remote, channels: [old, fresh])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        old.receive?(.disconnected)
        XCTAssertEqual(session.connection, .recovering)
        XCTAssertFalse(old.isConnected)
        do { try await session.publish(paused: true, positionMs: 9_000, rate: 1); XCTFail("Expected offline rejection") }
        catch { XCTAssertEqual(error as? WatchPartySessionError, .notReady) }
        try await session.reconnect()
        XCTAssertEqual(fresh.sent.map(\.0), ["status", "state_request"])
        XCTAssertEqual(session.playback?.positionMs, 1_000)
    }

    func testOldConnectionCallbacksCannotAlterNewConnection() async throws {
        let remote = Remote(snapshot())
        let old = Channel(), fresh = Channel()
        let session = session(remote, channels: [old, fresh])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        let staleCallback = old.receive
        try await session.reconnect()
        staleCallback?(.disconnected)
        staleCallback?(.message(name: "ended", payload: Data("{}".utf8)))
        XCTAssertEqual(session.connection, .ready)
        XCTAssertEqual(session.party?.id, "room")
        XCTAssertTrue(fresh.isConnected)
    }

    func testStopDuringHeartbeatDiscardsLateResponse() async {
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel])
        remote.onHeartbeat = { session.stop() }
        defer { remote.onHeartbeat = nil }
        do { try await session.start(snapshot: snapshot()); XCTFail("Expected late response rejection") }
        catch { XCTAssertEqual(session.connection, .stopped) }
        XCTAssertNil(session.party)
        XCTAssertTrue(channel.sent.isEmpty)
        XCTAssertFalse(channel.isConnected)
    }

    func testRemotePlaybackIsOrderedAndNeverEchoed() async throws {
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        let initialSends = channel.sent.count
        var next = try XCTUnwrap(session.playback)
        next.seq = 5; next.memberID = "other"; next.positionMs = 5_000
        channel.receive?(.message(name: "state", payload: try JSONEncoder().encode(next)))
        XCTAssertEqual(session.playback, next)
        next.seq = 4; next.positionMs = 2_000
        channel.receive?(.message(name: "state", payload: try JSONEncoder().encode(next)))
        XCTAssertEqual(session.playback?.seq, 5)
        XCTAssertEqual(channel.sent.count, initialSends)
    }

    func testHostOnlyBlocksGuestPublishAndNonHostState() async throws {
        let initial = snapshot(hostOnly: true, host: "other")
        let remote = Remote(initial)
        let channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.stop() }
        try await session.start(snapshot: initial)
        do { try await session.publish(paused: true, positionMs: 0, rate: 1); XCTFail("Expected host-only rejection") }
        catch { XCTAssertEqual(error as? WatchPartySessionError, .forbidden) }
        var unauthorized = try XCTUnwrap(session.playback)
        unauthorized.memberID = "me"; unauthorized.seq = 99
        channel.receive?(.message(name: "state", payload: try JSONEncoder().encode(unauthorized)))
        XCTAssertEqual(session.playback?.seq, 1)
    }

    func testConcurrentPublishReservesDistinctSequencesAndNeverRollsBack() async throws {
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        var nested = false
        channel.onSend = { event in
            if event == "state", !nested {
                nested = true
                try await session.publish(paused: false, positionMs: 3_000, rate: 1)
            }
        }
        try await session.publish(paused: true, positionMs: 2_000, rate: 1)
        let states = try channel.sent.filter { $0.0 == "state" }.map { try JSONDecoder().decode(WatchPartyPlayback.self, from: $0.1) }
        XCTAssertEqual(states.map(\.seq), [2, 3])
        XCTAssertEqual(session.playback?.seq, 3)
        XCTAssertEqual(session.playback?.positionMs, 3_000)
        channel.onSend = nil
    }

    func testRemovedMembershipClosesWithoutRecreatingIt() async {
        let remote = Remote(WatchPartySnapshot(error: "removed"))
        let channel = Channel()
        let session = session(remote, channels: [channel])
        do { try await session.start(snapshot: snapshot()); XCTFail("Expected removed membership") }
        catch { XCTAssertEqual(session.failure, .removed) }
        XCTAssertEqual(session.connection, .stopped)
        XCTAssertNil(session.party)
        XCTAssertFalse(channel.isConnected)
        XCTAssertEqual(remote.calls, ["heartbeat"])
    }

    func testOwnRemovalPublishesOneTerminalReasonAndClosesChannel() async throws {
        let remote = Remote(snapshot()), channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.onChange = nil; session.stop() }
        try await session.start(snapshot: snapshot())
        var exits: [WatchPartyMembershipExit?] = []
        session.onChange = { if session.connection == .stopped { exits.append(session.membershipExit) } }
        channel.receive?(.message(name: "member_left", payload: Data(#"{"member_id":"me","reason":"removed"}"#.utf8)))
        XCTAssertEqual(exits, [.removed])
        XCTAssertEqual(session.membershipExit, .removed)
        XCTAssertFalse(channel.isConnected)
        XCTAssertEqual(remote.calls, ["heartbeat", "clock"])
    }

    func testNotMemberDoesNotAssumeExpirationOrAutomaticallyRejoin() async {
        let remote = Remote(WatchPartySnapshot(error: "not_member")), channel = Channel()
        let session = session(remote, channels: [channel])
        do { try await session.start(snapshot: snapshot()); XCTFail("Expected lost membership") }
        catch { XCTAssertEqual(session.membershipExit, .membershipLost) }
        XCTAssertNil(session.party)
        XCTAssertFalse(channel.isConnected)
        XCTAssertEqual(remote.calls, ["heartbeat"])
    }

    func testBackendDisabledEventClosesWithUnavailableReason() async throws {
        let remote = Remote(snapshot()), channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        channel.receive?(.message(name: "ended", payload: Data(#"{"reason":"disabled"}"#.utf8)))
        XCTAssertEqual(session.membershipExit, .unavailable)
        XCTAssertEqual(session.failure, .unavailable)
        XCTAssertFalse(channel.isConnected)
    }

    func testOldSendFailureCannotCloseAReplacementConnection() async throws {
        let remote = Remote(snapshot())
        let old = Channel(), fresh = Channel()
        let session = session(remote, channels: [old, fresh])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        old.onSend = { event in
            if event == "state" {
                try await session.reconnect()
                throw WatchPartyChannelError.disconnected
            }
        }
        defer { old.onSend = nil }
        do { try await session.publish(paused: true, positionMs: 5_000, rate: 1); XCTFail("Expected old send failure") }
        catch { XCTAssertEqual(session.connection, .ready) }
        XCTAssertTrue(fresh.isConnected)
        XCTAssertEqual(session.playback?.positionMs, 1_000)
        XCTAssertEqual(fresh.sent.map(\.0), ["status", "state_request"])
    }

    func testOldPresenceCompletionCannotBroadcastIntoReplacementConnection() async throws {
        let remote = Remote(snapshot())
        let old = Channel(), fresh = Channel()
        let session = session(remote, channels: [old, fresh])
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        old.onTrack = { try await session.reconnect() }
        defer { old.onTrack = nil }
        do { try await session.setPresence(status: .ready, mediaKey: "movie|tt1||"); XCTFail("Expected stale completion") }
        catch { XCTAssertEqual(session.connection, .ready) }
        XCTAssertTrue(fresh.isConnected)
        XCTAssertEqual(fresh.sent.map(\.0), ["status", "state_request"])
    }

    func testInvalidatedContextCannotPublishOrReconnect() async throws {
        var current = true
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel], isCurrent: { _ in current })
        defer { session.stop() }
        try await session.start(snapshot: snapshot())
        current = false
        XCTAssertFalse(session.canControl)
        do { try await session.publish(paused: true, positionMs: 0, rate: 1); XCTFail("Expected stale context") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .staleContext) }
        do { try await session.reconnect(); XCTFail("Expected stale context") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .staleContext) }
        XCTAssertEqual(channel.sent.map(\.0), ["status", "state_request"])
    }

    func testLeaveFailureNeverRetriesMutation() async throws {
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel])
        try await session.start(snapshot: snapshot())
        remote.leaveError = URLError(.networkConnectionLost)
        do { try await session.leave(); XCTFail("Expected ambiguous transport failure") }
        catch { XCTAssertEqual(session.connection, .stopped) }
        XCTAssertEqual(remote.calls.filter { $0 == "leave" }.count, 1)
        XCTAssertFalse(channel.isConnected)
    }

    func testRealtimeURLPreservesBackendPrefixAndProxyQuery() throws {
        let config = ServerConfiguration(backendURL: "https://party.example.test/prefix/", publishableKey: "public",
                                         capabilities: ServerCapabilities(), discoveryURL: nil)
        let url = try WatchPartyChannelContract.realtimeURL(configuration: config)
        XCTAssertEqual(url.absoluteString, "https://party.example.test/prefix/realtime/v1?nuvio_realtime=1")
        XCTAssertFalse(url.absoluteString.contains("websocket"))
        var unsafe = config
        unsafe.backendURL = "https://user:password@party.example.test"
        XCTAssertThrowsError(try WatchPartyChannelContract.realtimeURL(configuration: unsafe))
    }

    func testPresenceChangedDuringInitialTrackUsesLatestState() async throws {
        let remote = Remote(snapshot())
        let channel = Channel()
        let session = session(remote, channels: [channel])
        defer { session.stop(); channel.onTrack = nil }
        var transitioned = false
        channel.onTrack = {
            if !transitioned {
                transitioned = true
                try await session.setPresence(status: .ready, mediaKey: "movie|tt1||")
            }
        }
        try await session.start(snapshot: snapshot())
        XCTAssertEqual(channel.tracked.map(\.status), [.browsing, .ready])
        XCTAssertEqual(session.presence["me"]?.status, .ready)
        let status = try XCTUnwrap(channel.sent.first { $0.0 == "status" })
        XCTAssertEqual(try JSONDecoder().decode(WatchPartyPresence.self, from: status.1).status, .ready)
    }

    @MainActor
    private final class Remote: WatchPartySessionRemote {
        var snapshot: WatchPartySnapshot
        var calls: [String] = []
        var onHeartbeat: (() -> Void)?
        var leaveError: Error?
        init(_ snapshot: WatchPartySnapshot) { self.snapshot = snapshot }
        func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot {
            calls.append("heartbeat"); onHeartbeat?(); return snapshot
        }
        func clock() async throws -> Int64 { calls.append("clock"); return 20_000 }
        func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot {
            calls.append("leave")
            if let leaveError { throw leaveError }
            return WatchPartySnapshot(ok: true)
        }
        func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot {
            calls.append("end"); return WatchPartySnapshot(ok: true)
        }
        func update(partyID: String, deviceID: String, media: WatchPartyMedia?, playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot {
            calls.append("update"); return snapshot
        }
    }

    @MainActor
    private final class Channel: WatchPartyChannel {
        var isConnected = false
        var operations: [String] = []
        var sent: [(String, Data)] = []
        var tracked: [WatchPartyPresence] = []
        var receive: (@MainActor (WatchPartyChannelEvent) -> Void)?
        var onSend: (@MainActor (String) async throws -> Void)?
        var onTrack: (@MainActor () async throws -> Void)?
        func open(partyID: String, memberID: String, receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws {
            operations.append("open"); isConnected = true; self.receive = receive
        }
        func send(event: String, payload: Data) async throws {
            guard isConnected else { throw WatchPartyChannelError.disconnected }
            operations.append(event); sent.append((event, payload)); try await onSend?(event)
        }
        func track(_ presence: WatchPartyPresence) async throws {
            operations.append("track"); tracked.append(presence); try await onTrack?()
        }
        func refreshAuth() async throws { operations.append("refreshAuth") }
        func close() { isConnected = false }
    }
}
