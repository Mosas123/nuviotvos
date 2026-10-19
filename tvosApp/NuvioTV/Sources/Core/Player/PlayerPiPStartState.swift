import Foundation

/// AVKit start admission, separate from confirmed ownership of the floating window.
/// A failed or cancelled start must leave the fullscreen session mounted.
struct PlayerPiPStartState {
    private enum Phase { case idle, starting, active }
    private var phase: Phase = .idle

    var isStarting: Bool { phase == .starting }
    var isActive: Bool { phase == .active }
    var isInProgress: Bool { phase != .idle }

    @discardableResult
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    mutating func confirm() -> Bool {
        guard phase == .starting else { return false }
        phase = .active
        return true
    }

    mutating func fail() -> Bool {
        guard phase == .starting else { return false }
        phase = .idle
        return true
    }

    /// Returns whether a confirmed floating window actually owned playback.
    mutating func stop() -> Bool {
        let wasActive = isActive
        phase = .idle
        return wasActive
    }
}

/// One restoration shared by app and AVKit requests. Success needs both the
/// root UI acknowledgement and the mounted fullscreen surface, in either order.
@MainActor
final class PlayerPiPRestoreRequest {
    private var token: UUID?
    private var result: Bool?
    private var surfaceReady = false
    private var deliveredResult: Bool?
    private var completions: [(Bool) -> Void] = []

    var isPending: Bool { token != nil && deliveredResult == nil }

    /// A nil return joins the existing request instead of presenting UI twice.
    func begin(completion: @escaping (Bool) -> Void) -> UUID? {
        if token != nil {
            if let deliveredResult { completion(deliveredResult) }
            else { completions.append(completion) }
            return nil
        }
        let next = UUID()
        token = next
        completions.append(completion)
        return next
    }

    func acceptUIResult(_ success: Bool, for token: UUID) {
        guard self.token == token, deliveredResult == nil else { return }
        result = success
        finishIfReady()
    }

    func surfaceDidRebind() {
        guard token != nil, deliveredResult == nil else { return }
        surfaceReady = true
        finishIfReady()
    }

    /// Invalidate before callbacks so late acknowledgements cannot affect a successor.
    func cancel() {
        let callbacks = completions
        token = nil
        result = nil
        surfaceReady = false
        deliveredResult = nil
        completions.removeAll()
        callbacks.forEach { $0(false) }
    }

    private func finishIfReady() {
        guard deliveredResult == nil, let result, !result || surfaceReady else { return }
        deliveredResult = result
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(result) }
    }
}
