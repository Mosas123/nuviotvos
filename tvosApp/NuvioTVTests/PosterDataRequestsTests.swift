import Foundation
import XCTest
@testable import NuvioTV

final class PosterDataRequestsTests: XCTestCase {
    private let url = URL(string: "https://example.invalid/poster.jpg")!

    func testConcurrentConsumersShareOneDownload() async {
        let requests = PosterDataRequests()
        let gate = PosterDownloadGate(result: Data([1, 2]))
        let first = await requests.request(url: url, revalidate: false) { await gate.fetch() }
        let second = await requests.request(url: url, revalidate: false) { await gate.fetch() }
        await gate.release()
        let firstData = await first.value
        let secondData = await second.value
        let count = await gate.count
        XCTAssertEqual(firstData, Data([1, 2]))
        XCTAssertEqual(secondData, firstData)
        XCTAssertEqual(count, 1)
    }

    func testDifferentURLsDoNotShareDownloads() async {
        let requests = PosterDataRequests()
        let gate = PosterDownloadGate(result: Data([1]))
        let first = await requests.request(url: url, revalidate: false) { await gate.fetch() }
        let otherURL = URL(string: "https://example.invalid/other.jpg")!
        let second = await requests.request(url: otherURL, revalidate: false) { await gate.fetch() }
        await gate.release()
        _ = await first.value
        _ = await second.value
        let count = await gate.count
        XCTAssertEqual(count, 2)
    }

    func testForcedRefreshDoesNotJoinNormalDownload() async {
        let requests = PosterDataRequests()
        let gate = PosterDownloadGate(result: Data([1]))
        let normal = await requests.request(url: url, revalidate: false) { await gate.fetch() }
        let refresh = await requests.request(url: url, revalidate: true) { await gate.fetch() }
        await gate.release()
        _ = await normal.value
        _ = await refresh.value
        let count = await gate.count
        XCTAssertEqual(count, 2)
    }

    func testConcurrentForcedRefreshesShareOneDownload() async {
        let requests = PosterDataRequests()
        let gate = PosterDownloadGate(result: Data([3]))
        let first = await requests.request(url: url, revalidate: true) { await gate.fetch() }
        let second = await requests.request(url: url, revalidate: true) { await gate.fetch() }
        await gate.release()
        _ = await first.value
        _ = await second.value
        let count = await gate.count
        XCTAssertEqual(count, 1)
    }

    func testFailureDoesNotPreventRetry() async {
        let requests = PosterDataRequests()
        let gate = PosterDownloadGate(result: nil)
        await gate.release()
        let first = await requests.request(url: url, revalidate: false) { await gate.fetch() }
        let failedData = await first.value
        XCTAssertNil(failedData)
        let retry = await requests.request(url: url, revalidate: false) { Data([4]) }
        let retryData = await retry.value
        XCTAssertEqual(retryData, Data([4]))
    }

    func testCompletedBytesAreNotRetainedAsAnotherCache() async {
        let requests = PosterDataRequests()
        let first = await requests.request(url: url, revalidate: false) { Data([1]) }
        let firstData = await first.value
        XCTAssertEqual(firstData, Data([1]))
        let next = await requests.request(url: url, revalidate: false) { Data([2]) }
        let nextData = await next.value
        XCTAssertEqual(nextData, Data([2]))
    }
}

private actor PosterDownloadGate {
    let result: Data?
    private(set) var count = 0
    private var released = false
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    init(result: Data?) { self.result = result }

    func fetch() async -> Data? {
        count += 1
        if released { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: result) }
    }
}
