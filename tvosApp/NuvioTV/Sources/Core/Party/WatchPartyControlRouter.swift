import Foundation

/// Explicit UI intents only. Never feed engine observations or synchronization effects into this.
/// Admission failure is terminal for the gesture: no raw-player fallback and no offline queue.
@MainActor
final class WatchPartyControlRouter {
    enum Submission: Equatable { case accepted, busy, unavailable }
    private let perform: @MainActor (WatchPartyLocalIntent, (@MainActor () -> Void)?) async throws -> Void
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
    private var pending: (completion: PlayerControlCompletion, stamp: WatchPartyPlayerStamp)?

    init(isCurrent: @escaping @MainActor () -> Bool,
         currentStamp: @escaping @MainActor () -> WatchPartyPlayerStamp?,
         canonicalRate: @escaping @MainActor () -> Float? = { nil },
         perform: @escaping @MainActor (WatchPartyLocalIntent, (@MainActor () -> Void)?) async throws -> Void,
         suspend: @escaping @MainActor (Bool) -> Void = { _ in },
         onError: @escaping @MainActor (Error) -> Void = { _ in },
         onCompleted: @escaping @MainActor (WatchPartyLocalIntent) -> Void = { _ in }) {
        self.isCurrent = isCurrent; self.currentStamp = currentStamp
        self.readCanonicalRate = canonicalRate
        self.perform = perform; self.suspend = suspend
        self.onError = onError; self.onCompleted = onCompleted
    }

    @discardableResult
    func submit(_ intent: WatchPartyLocalIntent, completion: (@MainActor () -> Void)? = nil,
                onApplied: (@MainActor () -> Void)? = nil) -> Submission {
        let finished = PlayerControlCompletion(completion)
        guard !stopped, !suspended, isCurrent(), let stamp = currentStamp() else {
            onError(WatchPartyPlaybackBindingError.notReady)
            finished.finish()
            return .unavailable
        }
        guard task == nil else {
            onError(WatchPartyPlaybackBindingError.busy)
            finished.finish()
            return .busy
        }
        let mark = revision
        let wantsReceipt = completion != nil || onApplied != nil
        pending = (finished, stamp)
        task = Task { [weak self] in
            guard let self else { finished.finish(); return }
            defer {
                self.task = nil
                if self.pending?.completion === finished { self.pending = nil }
                finished.finish()
            }
            do {
                try Task.checkCancellation()
                guard self.permitted(mark, stamp: stamp) else { throw WatchPartyPlaybackBindingError.staleOperation }
                let applied: (@MainActor () -> Void)? = !wantsReceipt ? nil : { [weak self, finished] in
                    guard let self, self.permitted(mark, stamp: stamp) else { return }
                    if self.pending?.completion === finished { self.pending = nil }
                    onApplied?()
                    finished.finish() // Engine receipt, not eventual room RPC confirmation.
                }
                try await self.perform(intent, applied)
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

    /// Reuse the VM tick; no additional timer. Context/source loss releases native waiters.
    func validateContext() {
        guard let pending, !isCurrent() || currentStamp() != pending.stamp else { return }
        revision = UUID()
        task?.cancel()
        self.pending = nil
        pending.completion.finish()
    }

    private func finishPending() {
        let completion = pending?.completion
        pending = nil
        completion?.finish()
    }

    /// Revoke effects before the lifecycle caller parks the engine. Never publishes a user pause.
    func setSuspended(_ value: Bool) {
        guard !stopped, suspended != value else { return }
        suspended = value
        revision = UUID()
        task?.cancel() // Keep its slot until the cancelled async operation actually returns.
        suspend(value)
        finishPending()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        revision = UUID()
        task?.cancel()
        finishPending()
    }
}
