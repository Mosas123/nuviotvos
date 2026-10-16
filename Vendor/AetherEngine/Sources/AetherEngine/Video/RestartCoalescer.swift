import Foundation

/// Collapses burst seek restarts to in-flight + one pending (AetherEngine#35). Rapid scrubs on loopback-HLS fired one `performRestart` per position (up to 5s `waitForFinish` + demuxer seek each); timeout left the abandoned producer reading the shared demuxer, stealing the first post-seek packet. Not thread-safe; HLSVideoEngine mutates under `restartLock`.
struct RestartCoalescer {
    struct Request: Equatable, Sendable {
        let index: Int
        let authoritative: Bool
        let automatic: Bool
        let sessionEpoch: UInt64
    }

    private var inFlight = false
    private var pending: Request?

    /// Returns `true` if the caller should become the in-flight worker; `false` if coalesced.
    mutating func begin(_ request: Request) -> Bool {
        if inFlight {
            if request.authoritative {
                pending = request
            } else if pending?.authoritative != true {
                pending = request
            }
            // An authoritative pending target keeps its priority over stale automatic/scrub work.
            return false
        }
        inFlight = true
        return true
    }

    /// Source-compatible convenience for policy tests and ordinary scrub callers.
    mutating func begin(_ idx: Int, authoritative: Bool = false) -> Bool {
        begin(Request(index: idx, authoritative: authoritative, automatic: false, sessionEpoch: 0))
    }

    /// True while a coalesced restart run is executing (#93 residual: segment fetches ride this
    /// instead of burning fixed retry budgets against a progressing restart).
    var isInFlight: Bool { inFlight }

    /// #178: a NEW user seek makes a pending authoritative recovery re-anchor obsolete.
    mutating func clearSupersededAuthoritativePending() {
        guard pending?.authoritative == true else { return }
        pending = nil
    }

    /// Returns next pending target, or `nil` when the burst has settled (clears in-flight flag).
    mutating func next(justRan request: Request, destructiveStarted: Bool = true) -> Request? {
        if let pending,
           pending.index != request.index || pending.sessionEpoch != request.sessionEpoch
                || (!destructiveStarted && pending.authoritative) {
            self.pending = nil
            return pending
        }
        pending = nil
        inFlight = false
        return nil
    }

    /// Source-compatible convenience for the existing coalescer policy tests.
    mutating func next(justRan idx: Int) -> Int? {
        next(justRan: Request(index: idx, authoritative: false, automatic: false, sessionEpoch: 0))?.index
    }
}
