import Foundation

/// Explicit UI intents only. Never feed engine observations or synchronization effects into this.
/// Admission failure is terminal for the gesture: no raw-player fallback and no offline queue.
@MainActor
final class WatchPartyControlRouter {
    enum Submission: Equatable { case accepted, busy, unavailable }
    private let perform: @MainActor (WatchPartyLocalIntent) async throws -> Void
    private let isCurrent: @MainActor () -> Bool
    private let currentStamp: @MainActor () -> WatchPartyPlayerStamp?
    private let readCanonicalRate: @MainActor () -> Float?
    var canonicalRate: Float? { readCanonicalRate() }
    private let suspend: @MainActor (Bool) -> Void
    private let onError: @MainActor (Error) -> Void
    private let onCompleted: @MainActor (WatchPartyLocalIntent) -> Void
    private var task: Task<Void, Never>?
    private var stopped = false
    private var suspended = false
    private var revision = UUID()

    init(isCurrent: @escaping @MainActor () -> Bool,
         currentStamp: @escaping @MainActor () -> WatchPartyPlayerStamp?,
         canonicalRate: @escaping @MainActor () -> Float? = { nil },
         perform: @escaping @MainActor (WatchPartyLocalIntent) async throws -> Void,
         suspend: @escaping @MainActor (Bool) -> Void = { _ in },
         onError: @escaping @MainActor (Error) -> Void = { _ in },
         onCompleted: @escaping @MainActor (WatchPartyLocalIntent) -> Void = { _ in }) {
        self.isCurrent = isCurrent; self.currentStamp = currentStamp
        self.readCanonicalRate = canonicalRate
        self.perform = perform; self.suspend = suspend
        self.onError = onError; self.onCompleted = onCompleted
    }

    @discardableResult
    func submit(_ intent: WatchPartyLocalIntent) -> Submission {
        guard !stopped, !suspended, isCurrent(), let stamp = currentStamp() else {
            onError(WatchPartyPlaybackBindingError.notReady)
            return .unavailable
        }
        guard task == nil else {
            onError(WatchPartyPlaybackBindingError.busy)
            return .busy
        }
        let mark = revision
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                try Task.checkCancellation()
                guard self.permitted(mark, stamp: stamp) else { throw WatchPartyPlaybackBindingError.staleOperation }
                try await self.perform(intent)
                try Task.checkCancellation()
                guard self.permitted(mark, stamp: stamp) else { return }
                self.onCompleted(intent)
            } catch {
                if self.permitted(mark, stamp: stamp), !(error is CancellationError) { self.onError(error) }
            }
        }
        return .accepted // Enqueued, NOT confirmation that engine or network succeeded.
    }

    private func permitted(_ mark: UUID, stamp: WatchPartyPlayerStamp) -> Bool {
        !stopped && !suspended && revision == mark && isCurrent() && currentStamp() == stamp
    }

    /// Revoke effects before the lifecycle caller parks the engine. Never publishes a user pause.
    func setSuspended(_ value: Bool) {
        guard !stopped, suspended != value else { return }
        suspended = value
        revision = UUID()
        task?.cancel() // Keep its slot until the cancelled async operation actually returns.
        suspend(value)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        revision = UUID()
        task?.cancel()
    }
}
