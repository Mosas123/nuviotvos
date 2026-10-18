import Foundation

// Session contract adapted from PartyRepository.kt, NuvioMedia/NuvioTV (GPL-3.0), f7e2a78.
@MainActor
protocol WatchPartySessionRemote: AnyObject {
    func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot
    func clock() async throws -> Int64
    func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot
    func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot
}

extension WatchPartyAPI: WatchPartySessionRemote {}

enum WatchPartyConnectionState: Equatable { case stopped, connecting, reconciling, ready, recovering }
enum WatchPartySessionError: Error, Equatable { case invalidSnapshot, notReady, forbidden, sequenceExhausted }

/// Owns one accepted create/join result. The future app service replaces it on context changes.
/// No player, view, global Auth, or automatic create/join retries are owned here.
@MainActor
final class WatchPartySession {
    typealias ChannelFactory = @MainActor () -> any WatchPartyChannel
    typealias Sleep = @MainActor (UInt64) async throws -> Void

    private(set) var connection: WatchPartyConnectionState = .stopped
    private(set) var party: WatchPartyInfo?
    private(set) var memberID: String?
    private(set) var members: [WatchPartyMember] = []
    private(set) var playback: WatchPartyPlayback?
    private(set) var presence: [String: WatchPartyPresence] = [:]
    private(set) var failure: WatchPartyFailure?
    var onChange: (@MainActor () -> Void)?
    /// Stream sharing remains opt-in in the future binding; never automatically resolve a URL here.
    var onStream: (@MainActor (Data) -> Void)?

    private let remote: any WatchPartySessionRemote
    private let context: WatchPartyRequestContext
    private let isCurrent: WatchPartyAPI.ContextValidator
    private let deviceID: String
    private let makeChannel: ChannelFactory
    private let sleep: Sleep
    private var clock: WatchPartyClock
    private var generation = UUID()
    private var connectionID = UUID()
    private var outboundSequence: Int64 = 0
    private var channel: (any WatchPartyChannel)?
    private var recoveryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var localPresence: WatchPartyPresence?

    init(remote: any WatchPartySessionRemote, context: WatchPartyRequestContext, deviceID: String,
         isCurrent: @escaping WatchPartyAPI.ContextValidator, makeChannel: @escaping ChannelFactory,
         clock: WatchPartyClock = WatchPartyClock(),
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) {
        self.remote = remote
        self.context = context
        self.deviceID = deviceID
        self.isCurrent = isCurrent
        self.makeChannel = makeChannel
        self.clock = clock
        self.sleep = sleep
    }

    var canControl: Bool {
        guard connection == .ready, let party, let memberID, isCurrent(context) else { return false }
        return !party.hostOnly || party.hostMemberID == memberID
    }

    func nowMs() -> Int64 { clock.nowMs() }

    /// Does not repeat a create/join whose remote outcome may be ambiguous.
    func start(snapshot: WatchPartySnapshot) async throws {
        stop()
        try checkContext()
        guard snapshot.error == nil, let info = snapshot.party, !info.id.isEmpty,
              let member = snapshot.memberID, !member.isEmpty,
              snapshot.members.contains(where: { $0.id == member }) else { throw WatchPartySessionError.invalidSnapshot }
        party = info
        memberID = member
        members = snapshot.members
        playback = validPlayback(info.playback, for: info)
        localPresence = WatchPartyPresence(memberID: member)
        failure = nil
        let epoch = generation
        do {
            try await connect(epoch: epoch)
            if active(epoch) { startHeartbeat(epoch: epoch) }
        } catch {
            if generation == epoch, Task.isCancelled || !isCurrent(context) { stop() }
            else if active(epoch) {
                invalidateConnection()
                scheduleRecovery(epoch: epoch)
                startHeartbeat(epoch: epoch)
            }
            throw error
        }
    }

    /// Called explicitly on account/backend/profile loss or true membership teardown.
    func stop() {
        generation = UUID()
        recoveryTask?.cancel(); recoveryTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        channel?.close(); channel = nil
        connection = .stopped
        party = nil; memberID = nil; members = []; playback = nil; presence = [:]
        localPresence = nil
        outboundSequence = 0
        failure = nil
        clock.reset()
        onChange?()
    }

    /// Call from the future service's foreground/auth-refresh transition, preserving PiP ownership.
    func reconnect() async throws {
        try checkContext()
        guard party != nil else { throw WatchPartySessionError.notReady }
        recoveryTask?.cancel(); recoveryTask = nil
        // Invalidate the old attempt before any await; old listeners cannot publish into this one.
        generation = UUID()
        heartbeatTask?.cancel(); heartbeatTask = nil
        invalidateConnection()
        let epoch = generation
        do { try await connect(epoch: epoch) }
        catch {
            if generation == epoch, Task.isCancelled || !isCurrent(context) { stop() }
            else if active(epoch) { invalidateConnection(); scheduleRecovery(epoch: epoch) }
            if active(epoch) { startHeartbeat(epoch: epoch) }
            throw error
        }
        if active(epoch) { startHeartbeat(epoch: epoch) }
    }

    func setPresence(status: WatchPartyMemberStatus, mediaKey: String?, behindMs: Int64? = nil) async throws {
        try checkContext()
        guard let memberID else { throw WatchPartySessionError.notReady }
        let value = WatchPartyPresence(memberID: memberID, status: status, mediaKey: mediaKey, behindMs: behindMs)
        // Presence is current local state, not an offline gesture queue.
        localPresence = value
        presence[memberID] = value
        onChange?()
        guard connection == .ready, let channel else { return }
        let epoch = generation
        let attempt = connectionID
        do {
            try await channel.track(value)
            try checkAttempt(epoch, channel: channel)
            try requireReady(epoch)
            try await send("status", value, epoch: epoch)
        } catch {
            lost(epoch: epoch, attempt: attempt)
            throw error
        }
    }

    /// The future intent dispatcher calls this only after admitting a local user/coordinator action.
    /// Remote playback acceptance never calls publish, preventing echo loops.
    func publish(paused: Bool, positionMs: Int64, rate: Float, waiting: Bool = false) async throws {
        try checkContext()
        guard connection == .ready, let party, let memberID else { throw WatchPartySessionError.notReady }
        guard canControl else { throw WatchPartySessionError.forbidden }
        guard rate.isFinite, rate > 0 else { throw WatchPartyChannelError.invalidPayload }
        let seq = max(playback?.seq ?? 0, outboundSequence)
        guard seq < Int64.max else { throw WatchPartySessionError.sequenceExhausted }
        outboundSequence = seq + 1
        let next = WatchPartyPlayback(seq: seq + 1, memberID: memberID, paused: paused,
                                     positionMs: max(0, positionMs), rate: min(4, max(0.25, rate)),
                                     at: clock.nowMs(), mediaKey: party.media.key, waiting: waiting)
        let epoch = generation
        let attempt = connectionID
        do {
            try await send("state", next, epoch: epoch)
            // A newer remote state can arrive while send awaits. Never overwrite it on completion.
            try requireReady(epoch)
            accept(next)
        } catch { lost(epoch: epoch, attempt: attempt); throw error }
        // Debounced RPC persistence and waiting coordination are added with the player binding.
    }

    func leave(endForEveryone: Bool = false) async throws {
        try checkContext()
        guard let party else { return }
        if endForEveryone, party.hostMemberID != memberID { throw WatchPartySessionError.forbidden }
        // Close locally first. One mutation attempt only; transport failure is an ambiguous outcome.
        stop()
        let stoppedEpoch = generation
        let result = try await (endForEveryone
            ? remote.end(partyID: party.id, deviceID: deviceID)
            : remote.leave(partyID: party.id, deviceID: deviceID))
        try checkContext()
        guard generation == stoppedEpoch else { throw WatchPartyAPIError.staleContext }
        if let error = WatchPartyFailure(serverCode: result.error) { failure = error; onChange?() }
    }

    private func connect(epoch: UUID) async throws {
        try checkContext()
        guard active(epoch), let party, let memberID else { throw WatchPartySessionError.notReady }
        connection = .connecting; onChange?()
        let created = makeChannel()
        let attempt = connectionID
        channel = created
        try await created.open(partyID: party.id, memberID: memberID) { [weak self, weak created] event in
            guard let self, let created, self.active(epoch), self.channel === created else { return }
            self.receive(event, epoch: epoch, attempt: attempt)
        }
        try checkAttempt(epoch, channel: created)
        connection = .reconciling; onChange?()
        let sent = clock.mark()
        let snapshot = try await remote.heartbeat(partyID: party.id, deviceID: deviceID)
        try checkAttempt(epoch, channel: created)
        try apply(snapshot)
        if let server = snapshot.serverTimeMs { clock.addSample(serverMs: server, sentAt: sent) }
        // Refine before admitting gestures; use the same existing auth/RPC path.
        let clockSent = clock.mark()
        let server = try await remote.clock()
        try checkAttempt(epoch, channel: created)
        clock.addSample(serverMs: server, sentAt: clockSent)
        let own = localPresence ?? WatchPartyPresence(memberID: memberID)
        try await created.track(own)
        try checkAttempt(epoch, channel: created)
        presence[memberID] = own
        connection = .ready; failure = nil; onChange?()
        try await send("status", own, epoch: epoch)
        try await send("state_request", MemberPayload(memberID: memberID), epoch: epoch)
    }

    private func checkContext() throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw WatchPartyAPIError.staleContext }
    }

    private func active(_ epoch: UUID) -> Bool { generation == epoch && party != nil && isCurrent(context) }

    private func checkAttempt(_ epoch: UUID, channel: any WatchPartyChannel) throws {
        try checkContext()
        guard active(epoch), self.channel === channel, channel.isConnected else { throw WatchPartyChannelError.disconnected }
    }

    private func requireReady(_ epoch: UUID) throws {
        try checkContext()
        guard active(epoch), connection == .ready, channel?.isConnected == true else { throw WatchPartySessionError.notReady }
    }

    private func send<T: Encodable>(_ event: String, _ value: T, epoch: UUID) async throws {
        try requireReady(epoch)
        guard let channel else { throw WatchPartySessionError.notReady }
        let payload = try JSONEncoder().encode(value)
        try await channel.send(event: event, payload: payload)
        guard self.channel === channel else { throw WatchPartyAPIError.staleContext }
        try requireReady(epoch)
    }

    private func invalidateConnection() {
        connectionID = UUID()
        channel?.close(); channel = nil
        connection = .recovering
        presence = presence.filter { $0.key == memberID }
        onChange?()
    }

    private func lost(epoch: UUID, attempt: UUID) {
        guard active(epoch), connectionID == attempt else { return }
        let opening = connection == .connecting || connection == .reconciling
        invalidateConnection()
        // The in-flight connect catches its failure and owns scheduling in this case.
        if !opening { scheduleRecovery(epoch: epoch) }
    }

    private func scheduleRecovery(epoch: UUID) {
        guard active(epoch), recoveryTask == nil else { return }
        let sleep = self.sleep
        recoveryTask = Task { [weak self] in
            var delay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do { try await sleep(delay) } catch { break }
                guard let self, self.active(epoch) else { break }
                do {
                    try await self.connect(epoch: epoch)
                    if self.active(epoch) { self.recoveryTask = nil }
                    return
                } catch {
                    guard self.active(epoch), !Task.isCancelled else { break }
                    self.invalidateConnection()
                    delay = min(delay * 2, 30_000_000_000)
                }
            }
        }
    }

    private func startHeartbeat(epoch: UUID) {
        let sleep = self.sleep
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(120_000_000_000) } catch { return }
                guard let self, self.active(epoch) else { return }
                guard self.connection == .ready, let party = self.party else { continue }
                let attempt = self.connectionID
                do {
                    let snapshot = try await self.remote.heartbeat(partyID: party.id, deviceID: self.deviceID)
                    guard self.active(epoch), !Task.isCancelled else { return }
                    guard self.connectionID == attempt else { continue }
                    try self.apply(snapshot)
                    try await self.channel?.refreshAuth()
                    guard self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { continue }
                } catch {
                    if self.active(epoch), !Task.isCancelled { self.lost(epoch: epoch, attempt: attempt) }
                }
            }
        }
    }

    private func validPlayback(_ value: WatchPartyPlayback?, for party: WatchPartyInfo) -> WatchPartyPlayback? {
        guard let value, value.mediaKey == nil || value.mediaKey == party.media.key,
              !party.hostOnly || value.memberID == party.hostMemberID else { return nil }
        return value
    }

    private func accept(_ value: WatchPartyPlayback) {
        guard let party, validPlayback(value, for: party) != nil,
              WatchPartyPolicy.isNewer(value, than: playback) else { return }
        playback = value
        onChange?()
    }

    private func apply(_ snapshot: WatchPartySnapshot) throws {
        if let error = WatchPartyFailure(serverCode: snapshot.error) {
            switch error {
            case .removed, .ended, .notFound, .unavailable:
                stop(); failure = error; onChange?()
            default: failure = error; onChange?()
            }
            throw WatchPartySessionError.invalidSnapshot
        }
        guard let info = snapshot.party, info.id == party?.id,
              snapshot.memberID == nil || snapshot.memberID == memberID,
              snapshot.members.contains(where: { $0.id == memberID }) else { throw WatchPartySessionError.invalidSnapshot }
        let mediaChanged = info.media.key != party?.media.key
        party = info; members = snapshot.members
        presence = presence.filter { key, _ in members.contains { $0.id == key } }
        if mediaChanged || validPlayback(playback, for: info) == nil {
            playback = validPlayback(info.playback, for: info)
        } else if let value = info.playback { accept(value) }
        onChange?()
    }

    private func receive(_ event: WatchPartyChannelEvent, epoch: UUID, attempt: UUID) {
        guard connectionID == attempt else { return }
        if case .disconnected = event { lost(epoch: epoch, attempt: attempt); return }
        // Snapshot first, then state_request. Do not replay messages collected during reconciliation.
        guard connection == .ready, let party, let memberID else { return }
        switch event {
        case .disconnected: break
        case let .presence(joins, leaves):
            for key in leaves where key != memberID && joins[key] == nil { presence[key] = nil }
            for (key, var value) in joins where key != memberID && members.contains(where: { $0.id == key }) {
                value.memberID = key
                // Preserve more recent status broadcasts, as Android does.
                if presence[key] == nil { presence[key] = value }
            }
            onChange?()
        case let .message(name, data):
            switch name {
            case "state":
                if let value = try? JSONDecoder().decode(WatchPartyPlayback.self, from: data),
                   value.memberID == nil || members.contains(where: { $0.id == value.memberID }) { accept(value) }
            case "status":
                if let value = try? JSONDecoder().decode(WatchPartyPresence.self, from: data),
                   value.memberID != memberID, members.contains(where: { $0.id == value.memberID }) {
                    presence[value.memberID] = value; onChange?()
                }
            case "state_request":
                guard let request = try? JSONDecoder().decode(MemberPayload.self, from: data), request.memberID != memberID else { return }
                Task { [weak self] in
                    guard let self, self.active(epoch), self.connectionID == attempt, self.connection == .ready else { return }
                    do {
                        if let own = self.localPresence { try await self.send("status", own, epoch: epoch) }
                        if let playback = self.playback { try await self.send("state", playback, epoch: epoch) }
                    } catch { self.lost(epoch: epoch, attempt: attempt) }
                }
            case "ended": stop(); failure = .ended; onChange?()
            case "control", "member_joined", "member_left", "media":
                // Treat server notifications as invalidations, not authoritative permission/media payloads.
                // Reconcile once through RPC before reopening the send gate.
                lost(epoch: epoch, attempt: attempt)
            case "stream":
                if let sender = try? JSONDecoder().decode(MemberPayload.self, from: data),
                   sender.memberID == party.hostMemberID, memberID != party.hostMemberID { onStream?(data) }
            default: break
            }
        }
    }

    private struct MemberPayload: Codable {
        let memberID: String
        enum CodingKeys: String, CodingKey { case memberID = "member_id" }
    }
}
