import Foundation

// Clock sampling adapted from NuvioMedia/NuvioTV (GPL-3.0), PartyClock.kt,
// reference f7e2a78ad3b19a09080ad08315825f1f0a472934.
// The owning session serializes mutation. No timer, socket, or wall-clock resync is started here.
struct WatchPartyClock {
    private let uptime: () -> TimeInterval
    private let wallTimeMs: () -> Int64
    private var anchorServerMs: Int64?
    private var anchorUptime: TimeInterval?
    private var bestRoundTripMs = Int64.max

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallTimeMs: @escaping () -> Int64 = { WatchPartyTimeMath.integer(Date().timeIntervalSince1970 * 1_000) }) {
        self.uptime = uptime
        self.wallTimeMs = wallTimeMs
    }

    var isSynced: Bool { anchorServerMs != nil }

    func mark() -> TimeInterval { uptime() }

    func nowMs() -> Int64 {
        guard let anchorServerMs, let anchorUptime else { return wallTimeMs() }
        let current = uptime()
        guard current.isFinite, current >= anchorUptime else { return anchorServerMs }
        return WatchPartyTimeMath.add(anchorServerMs, max(0, WatchPartyTimeMath.integer((current - anchorUptime) * 1_000)))
    }

    @discardableResult
    mutating func addSample(serverMs: Int64, sentAt: TimeInterval) -> Bool {
        let receivedAt = uptime()
        guard receivedAt.isFinite, sentAt.isFinite, receivedAt >= sentAt else { return false }
        let roundTripMs = max(0, WatchPartyTimeMath.integer((receivedAt - sentAt) * 1_000))
        guard roundTripMs <= bestRoundTripMs else { return false }
        bestRoundTripMs = roundTripMs
        anchorServerMs = WatchPartyTimeMath.add(serverMs, roundTripMs / 2)
        anchorUptime = receivedAt
        return true
    }

    mutating func reset() {
        anchorServerMs = nil
        anchorUptime = nil
        bestRoundTripMs = .max
    }
}
