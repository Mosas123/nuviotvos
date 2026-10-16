import Testing
import Foundation
@testable import AetherEngine

@Suite(.offCooperativePool)
struct VODAutomaticRestartProviderTests {
    private final class OutcomeQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [VODProviderRestartResult]

        init(_ outcomes: [VODProviderRestartResult]) { self.outcomes = outcomes }

        func next() -> VODProviderRestartResult {
            lock.lock()
            defer { lock.unlock() }
            return outcomes.isEmpty ? .superseded : outcomes.removeFirst()
        }
    }

    @Test("deferred and exhausted automatic callbacks preserve the current producer front")
    func deniedAutomaticRestartsDoNotResetProviderFront() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        cache.resetHighWaterForRestart()
        for index in 40...46 {
            cache.store(index: index, data: Data(repeating: 0xA9, count: 8))
        }
        #expect(cache.highestStoredIndex == 46)

        let outcomes = OutcomeQueue([
            .deferred(remaining: 15),
            .exhausted(firstReport: true),
        ])
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: (0..<200).map { index in
                HLSVideoEngine.Segment(
                    startPts: Int64(index) * 4_000,
                    endPts: Int64(index + 1) * 4_000,
                    startSeconds: Double(index) * 4,
                    durationSeconds: 4
                )
            },
            codecsString: "hvc1",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 24,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { _ in outcomes.next() },
            restartActivity: { false },
            activeProducerBase: { 40 },
            producerFinished: { true },
            initialRestartIndex: 40,
            repositionWaitSlice: 0.001,
            repositionRideCapSeconds: 0.1,
            forwardBackpressureWaitSeconds: 0.001
        )

        #expect(provider.mediaSegment(at: 47) == nil)
        #expect(cache.highestStoredIndex == 46)
        #expect(provider.mediaSegment(at: 47) == nil)
        #expect(cache.highestStoredIndex == 46)
    }
}
