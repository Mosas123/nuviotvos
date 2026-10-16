import Foundation
import Testing
@testable import AetherEngine

struct FrameExtractorLifecycleTests {
    @Test("overlapping auxiliary closes share teardown and keep admission closed")
    func overlappingAuxiliaryClosesCoalesce() async {
        let barrier = ContextCloseBarrier()
        let extractor = FrameExtractor(
            testingReader: DataIOReader(data: Data()),
            formatHint: "mp4",
            beforeContextClose: { barrier.holdFirstClose() }
        )

        let firstClose = Task { await extractor.closeAuxiliaryContext() }
        let closeEntered = await Task.detached {
            barrier.waitForFirstClose(timeout: 2)
        }.value
        guard closeEntered else {
            barrier.releaseFirstClose()
            await firstClose.value
            #expect(Bool(false), "the serial decode queue did not enter teardown")
            return
        }

        let secondClose = Task { await extractor.closeAuxiliaryContext() }
        var joined = false
        for _ in 0..<10_000 {
            if await extractor.coalescedContextCloseCountForTesting == 1 {
                joined = true
                break
            }
            await Task.yield()
        }
        #expect(joined, "the second caller should join the in-flight teardown")
        #expect(await extractor.isClosingContextForTesting)
        #expect(await extractor.thumbnail(at: 0) == nil)

        // Cancellation belongs to this caller; it must not cancel the shared queue close.
        firstClose.cancel()
        barrier.releaseFirstClose()
        await firstClose.value
        await secondClose.value

        #expect(!(await extractor.isClosingContextForTesting))
        #expect(barrier.closeCount == 1)

        await extractor.shutdown()
        #expect(await extractor.thumbnail(at: 0) == nil)
    }
}

private final class ContextCloseBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var count = 0

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func holdFirstClose() {
        lock.lock()
        count += 1
        let shouldHold = count == 1
        lock.unlock()
        guard shouldHold else { return }
        entered.signal()
        release.wait()
    }

    func waitForFirstClose(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func releaseFirstClose() {
        release.signal()
    }
}
