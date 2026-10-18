import Foundation
import Combine

@MainActor
protocol WatchPartyServiceRemote: WatchPartySessionRemote {
    func create(identity: WatchPartyIdentity, media: WatchPartyMedia,
                playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot
    func join(code: String, identity: WatchPartyIdentity) async throws -> WatchPartySnapshot
    func preview(code: String) async throws -> WatchPartyPreview
    func enabled() async throws -> Bool
}

extension WatchPartyAPI: WatchPartyServiceRemote {}

struct WatchPartyEnvironment: Equatable {
    let configuration: ServerConfiguration
    let userID: String
    let profileID: String
    let identity: WatchPartyIdentity
}

enum WatchPartyServiceError: Error, Equatable {
    case busy, alreadyInRoom, unavailable, membershipOutcomeUncertain, newJoinRequired, requestFailed
    case rejected(WatchPartyFailure)
}

/// App-level owner. Construction is inert; the future root/UI explicitly invokes its operations.
@MainActor
final class WatchPartyService: ObservableObject {
    typealias EnvironmentProvider = @MainActor () -> WatchPartyEnvironment?
    typealias RemoteFactory = @MainActor (WatchPartyEnvironment, WatchPartyRequestContext,
                                         @escaping WatchPartyAPI.ContextValidator) -> any WatchPartyServiceRemote
    typealias SessionFactory = @MainActor (any WatchPartyServiceRemote, WatchPartyEnvironment,
                                          WatchPartyRequestContext, @escaping WatchPartyAPI.ContextValidator) -> WatchPartySession

    @Published private(set) var session: WatchPartySession?
    @Published private(set) var busy = false
    @Published private(set) var available: Bool?
    @Published private(set) var failure: WatchPartyFailure?
    @Published private(set) var membershipOutcomeUncertain = false

    private let environment: EnvironmentProvider
    private let makeRemote: RemoteFactory
    private let makeSession: SessionFactory
    private var captured: WatchPartyEnvironment?
    private var context: WatchPartyRequestContext?
    private var remote: (any WatchPartyServiceRemote)?
    private var revision = UUID()
    private var operation: UUID?
    private var connectionTask: Task<Void, Error>?
    // Owned subscriptions are cancelled on destruction; their closures retain the service weakly.
    var authObservation: AnyCancellable?

    init(environment: @escaping EnvironmentProvider, makeRemote: @escaping RemoteFactory,
         makeSession: @escaping SessionFactory) {
        self.environment = environment
        self.makeRemote = makeRemote
        self.makeSession = makeSession
    }

    /// Root must call synchronously for profile/backend transitions, even A→B→A.
    /// Account transitions are also observed by the Auth composition below.
    func invalidateContext() {
        revision = UUID()
        operation = nil
        connectionTask?.cancel(); connectionTask = nil
        session?.onChange = nil
        session?.stop()
        session = nil
        remote = nil; captured = nil; context = nil
        busy = false; available = nil; failure = nil; membershipOutcomeUncertain = false
    }

    /// Explicit acknowledgement after an ambiguous create/join; never called by recovery logic.
    func acknowledgeUncertainMembershipOutcome() { membershipOutcomeUncertain = false }

    func checkAvailability() async throws -> Bool {
        let setup = try begin()
        defer { finish(setup.operation) }
        do {
            let result = try await setup.remote.enabled()
            try check(setup.context, operation: setup.operation)
            available = result
            return result
        } catch { throw report(error, context: setup.context, operation: setup.operation) }
    }

    func preview(code: String) async throws -> WatchPartyPreview {
        let setup = try begin()
        defer { finish(setup.operation) }
        do {
            let value = try await setup.remote.preview(code: code)
            try check(setup.context, operation: setup.operation)
            if let failure = WatchPartyFailure(serverCode: value.error) { throw WatchPartyServiceError.rejected(failure) }
            return value
        } catch { throw report(error, context: setup.context, operation: setup.operation) }
    }

    func create(media: WatchPartyMedia, playback: WatchPartyPlayback? = nil) async throws {
        try await enter { remote, identity in try await remote.create(identity: identity, media: media, playback: playback) }
    }

    func join(code: String) async throws {
        guard WatchPartyCode.isValid(code) else { throw WatchPartyAPIError.invalidCode }
        let code = WatchPartyCode.normalize(code)
        try await enter { remote, identity in try await remote.join(code: code, identity: identity) }
    }

    /// Context teardown does not perform a leave with obsolete credentials.
    func leave(endForEveryone: Bool = false) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let current = session, current.party != nil else { return }
        do {
            try await current.leave(endForEveryone: endForEveryone)
            try check(setup.context, operation: setup.operation)
            if let reason = current.failure { throw WatchPartyServiceError.rejected(reason) }
            current.onChange = nil
            if session === current { session = nil }
        } catch {
            if isCurrent(setup.context), session === current, current.party == nil {
                current.onChange = nil; session = nil
            }
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    func resume() async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let session else { return }
        guard session.membershipExit == nil else { throw WatchPartyServiceError.newJoinRequired }
        guard session.party != nil else { return }
        do {
            let task = Task { try await session.reconnect() }
            connectionTask = task
            defer { if self.session === session { connectionTask = nil } }
            try await task.value
            try check(setup.context, operation: setup.operation)
        } catch { throw report(error, context: setup.context, operation: setup.operation) }
    }

    private func enter(_ request: @MainActor (any WatchPartyServiceRemote, WatchPartyIdentity) async throws -> WatchPartySnapshot) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard session?.party == nil else { throw WatchPartyServiceError.alreadyInRoom }
        guard !membershipOutcomeUncertain else { throw WatchPartyServiceError.membershipOutcomeUncertain }
        var submitted = false
        var accepted = false
        do {
            let enabled = try await setup.remote.enabled()
            try check(setup.context, operation: setup.operation)
            available = enabled
            guard enabled else { throw WatchPartyServiceError.unavailable }
            submitted = true
            let snapshot = try await request(setup.remote, setup.environment.identity)
            try check(setup.context, operation: setup.operation)
            if let failure = WatchPartyFailure(serverCode: snapshot.error) { throw WatchPartyServiceError.rejected(failure) }
            guard let info = snapshot.party, !info.id.isEmpty,
                  let member = snapshot.memberID, !member.isEmpty,
                  snapshot.members.contains(where: { $0.id == member }) else { throw WatchPartyAPIError.invalidResponse }
            accepted = true
            let validator: WatchPartyAPI.ContextValidator = { [weak self] in self?.isCurrent($0) == true }
            let current = makeSession(setup.remote, setup.environment, setup.context, validator)
            session?.onChange = nil; session?.stop()
            session = current
            current.onChange = { [weak self, weak current] in
                guard let self, let current, self.session === current, self.isCurrent(setup.context) else { return }
                self.objectWillChange.send()
            }
            // Membership is now known. Caller cancellation must not discard it or repeat create/join.
            // Context invalidation explicitly cancels this owner-held task and stops the session.
            let task = Task { try await current.start(snapshot: snapshot) }
            connectionTask = task
            defer { if session === current { connectionTask = nil } }
            do { try await task.value }
            catch {
                try check(setup.context, operation: setup.operation)
                // Membership was accepted. Keep the reconnecting session instead of repeating create/join.
                guard current.party != nil else { throw error }
                failure = .network
            }
            try check(setup.context, operation: setup.operation)
        } catch {
            if isCurrent(setup.context), operation == setup.operation,
               submitted, !accepted, isAmbiguous(error) { membershipOutcomeUncertain = true }
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    private struct Setup {
        let environment: WatchPartyEnvironment
        let context: WatchPartyRequestContext
        let remote: any WatchPartyServiceRemote
        let operation: UUID
    }

    private func begin() throws -> Setup {
        try Task.checkCancellation()
        let current = environment()
        if captured != current { invalidateContext() }
        guard let current else { throw WatchPartyAPIError.signInRequired }
        guard !busy else { throw WatchPartyServiceError.busy }
        if context == nil {
            let value = WatchPartyRequestContext(backendIdentity: current.configuration.backendIdentity,
                                                userID: current.userID, profileID: current.profileID, epoch: revision)
            captured = current; context = value
            let validator: WatchPartyAPI.ContextValidator = { [weak self] in self?.isCurrent($0) == true }
            remote = makeRemote(current, value, validator)
        }
        guard let context, let remote else { throw WatchPartyAPIError.staleContext }
        let token = UUID()
        operation = token; busy = true; failure = nil
        return Setup(environment: current, context: context, remote: remote, operation: token)
    }

    private func isCurrent(_ value: WatchPartyRequestContext) -> Bool {
        context == value && value.epoch == revision && captured == environment()
    }

    private func check(_ value: WatchPartyRequestContext, operation: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(value), self.operation == operation else { throw WatchPartyAPIError.staleContext }
    }

    private func finish(_ token: UUID) {
        guard operation == token else { return }
        operation = nil; busy = false
    }

    private func isAmbiguous(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? WatchPartyAPIError {
            switch error {
            case .transport, .invalidResponse: return true
            case .httpStatus(let status): return status >= 500
            default: return false
            }
        }
        return !(error is WatchPartyServiceError)
    }

    private func report(_ error: Error, context: WatchPartyRequestContext, operation: UUID) -> Error {
        guard isCurrent(context), self.operation == operation else { return WatchPartyAPIError.staleContext }
        if error is CancellationError { return CancellationError() }
        if let value = error as? WatchPartyServiceError {
            switch value {
            case .rejected(let reason): failure = reason
            case .unavailable: failure = .unavailable
            default: failure = .network
            }
            return value
        }
        if let value = error as? WatchPartyAPIError {
            failure = value == .signInRequired ? .signInRequired : .network
            return value
        }
        if let value = error as? WatchPartySessionError {
            failure = value == .forbidden ? nil : .network
            return value
        }
        failure = .network
        return WatchPartyServiceError.requestFailed
    }
}
