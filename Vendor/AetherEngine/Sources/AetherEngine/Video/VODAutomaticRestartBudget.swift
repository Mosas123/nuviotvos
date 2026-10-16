import Foundation

/// Result returned to a VOD provider after it asks the engine to re-anchor automatically.
enum VODProviderRestartResult: Equatable, Sendable {
    /// A replacement producer was constructed and started at this settled target.
    case restarted(at: Int)
    /// This target joined an already-running coalesced restart.
    case coalesced
    /// The current fresh reader is still inside its grace/backoff window.
    case deferred(remaining: TimeInterval)
    /// The automatic-restart episode is terminal. Only the first result should surface an error.
    case exhausted(firstReport: Bool)
    /// An admitted destructive attempt did not install a replacement producer.
    case failed
    /// The request belonged to an old session, or could not be executed in this session.
    case superseded
}

/// Settles coalesced restart results into the state the provider may safely publish.
/// A later destructive failure removes any earlier producer success; a denied later request leaves
/// an earlier installed producer in place and therefore preserves that success.
struct VODRestartRunOutcome: Sendable {
    private(set) var successfulTarget: Int?
    private(set) var lastUnsuccessfulResult: VODProviderRestartResult = .superseded

    mutating func record(_ result: VODProviderRestartResult) {
        switch result {
        case .restarted(let target):
            successfulTarget = target
        case .failed:
            successfulTarget = nil
            lastUnsuccessfulResult = .failed
        case .coalesced, .deferred, .exhausted, .superseded:
            lastUnsuccessfulResult = result
        }
    }

    var providerResult: VODProviderRestartResult {
        if let successfulTarget { return .restarted(at: successfulTarget) }
        return lastUnsuccessfulResult
    }
}

/// Monotonic, value-only budget for repeated VOD producer replacements at a frozen playhead.
/// Callers serialize mutation under HLSVideoEngine.restartLock and supply the off-lock rendered clock.
struct VODAutomaticRestartBudget: Sendable {
    enum Admission: Equatable, Sendable {
        case restart(attempt: Int, elapsed: TimeInterval, remaining: TimeInterval, progressReset: Bool)
        case deferred(remaining: TimeInterval, shouldLog: Bool)
        case exhausted(firstReport: Bool, attempts: Int, elapsed: TimeInterval)
    }

    static let freshReaderGrace: TimeInterval = 30
    static let maximumEpisodeDuration: TimeInterval = 120
    static let maximumRestarts = 3
    static let renderedProgressThreshold: Double = 0.5
    private static let cooldowns: [TimeInterval] = [30, 45, 60]
    private static let deferredLogInterval: TimeInterval = 10

    private var episodeStartedAt: TimeInterval?
    private var lastRestartAt: TimeInterval?
    private var maximumRenderedPosition: Double?
    private var restartCount = 0
    private var terminalLatched = false
    private var exhaustionReported = false
    private var lastDeferredLogAt: TimeInterval?

    /// Records one automatic replacement decision. A `.restart` admission is consumed exactly once,
    /// by the caller immediately before it detaches the current producer.
    mutating func admit(now: TimeInterval, renderedPosition: Double?) -> Admission {
        let didResetForProgress = observeRenderedProgress(renderedPosition)
        if terminalLatched {
            return .exhausted(firstReport: reportExhaustionOnce(), attempts: restartCount, elapsed: elapsed(at: now))
        }

        if episodeStartedAt == nil { episodeStartedAt = now }
        let elapsed = elapsed(at: now)
        if elapsed >= Self.maximumEpisodeDuration {
            terminalLatched = true
            return .exhausted(firstReport: reportExhaustionOnce(), attempts: restartCount, elapsed: elapsed)
        }

        if let lastRestartAt {
            let cooldown = Self.cooldowns[min(max(restartCount - 1, 0), Self.cooldowns.count - 1)]
            let remaining = cooldown - max(0, now - lastRestartAt)
            if remaining > 0 {
                let shouldLog = lastDeferredLogAt.map { now - $0 >= Self.deferredLogInterval } ?? true
                if shouldLog { lastDeferredLogAt = now }
                return .deferred(remaining: remaining, shouldLog: shouldLog)
            }
        }

        let episodeRemaining = max(0, Self.maximumEpisodeDuration - elapsed)
        if episodeRemaining < Self.freshReaderGrace {
            return deferred(remaining: episodeRemaining, now: now)
        }
        if restartCount >= Self.maximumRestarts {
            terminalLatched = true
            return .exhausted(firstReport: reportExhaustionOnce(), attempts: restartCount, elapsed: elapsed)
        }

        restartCount += 1
        return .restart(
            attempt: restartCount,
            elapsed: elapsed,
            remaining: episodeRemaining,
            progressReset: didResetForProgress
        )
    }

    /// A new user seek is fresh intent, including a backward seek. Its baseline starts at the actual
    /// rendered position observed for that seek, never at a requested segment index.
    mutating func resetForUserSeek() {
        resetEpisode()
        maximumRenderedPosition = nil
    }

    /// Anchors the next reader's grace after old-producer teardown and bounded reopen work finish.
    mutating func markReplacementStarted(at now: TimeInterval) {
        lastRestartAt = now
    }

    /// A stopped/new session receives a wholly fresh budget.
    mutating func resetForSession() {
        resetEpisode()
        maximumRenderedPosition = nil
    }

    private mutating func observeRenderedProgress(_ position: Double?) -> Bool {
        guard let position = Self.validPosition(position) else { return false }
        guard let maximumRenderedPosition else {
            self.maximumRenderedPosition = position
            return false
        }
        guard position > maximumRenderedPosition + Self.renderedProgressThreshold else { return false }

        let hadEpisode = episodeStartedAt != nil || terminalLatched || restartCount > 0
        self.maximumRenderedPosition = position
        resetEpisode()
        self.maximumRenderedPosition = position
        return hadEpisode
    }

    private mutating func reportExhaustionOnce() -> Bool {
        guard !exhaustionReported else { return false }
        exhaustionReported = true
        return true
    }

    private mutating func deferred(remaining: TimeInterval, now: TimeInterval) -> Admission {
        let shouldLog = lastDeferredLogAt.map { now - $0 >= Self.deferredLogInterval } ?? true
        if shouldLog { lastDeferredLogAt = now }
        return .deferred(remaining: remaining, shouldLog: shouldLog)
    }

    private func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let episodeStartedAt else { return 0 }
        return max(0, now - episodeStartedAt)
    }

    private mutating func resetEpisode() {
        episodeStartedAt = nil
        lastRestartAt = nil
        restartCount = 0
        terminalLatched = false
        exhaustionReported = false
        lastDeferredLogAt = nil
    }

    private static func validPosition(_ position: Double?) -> Double? {
        guard let position, position.isFinite, position >= 0 else { return nil }
        return position
    }
}
