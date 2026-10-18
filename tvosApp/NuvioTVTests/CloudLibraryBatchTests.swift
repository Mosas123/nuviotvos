import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class CloudLibraryBatchTests: XCTestCase {
    private func item(_ id: String) -> CloudItem {
        CloudItem(providerId: id, id: id, type: .torrent, name: id,
                  status: nil, sizeBytes: nil, files: [])
    }

    private func request(
        _ id: String,
        result: Result<[CloudItem], Error>
    ) -> (provider: CloudLibraryProvider, apiKey: String) {
        (CloudBatchStub(providerId: id, handler: { try result.get() }), "fixture-key")
    }

    func testSuccessfulProvidersAreCombined() async throws {
        let result = try await CloudLibraryService.loadProviderItems([
            request("a", result: .success([item("a")])),
            request("b", result: .success([item("b")]))
        ])
        XCTAssertEqual(result.map(\.id).sorted(), ["a", "b"])
    }

    func testPartialFailureKeepsSuccessfulFiles() async throws {
        let expected = [item("available")]
        let result = try await CloudLibraryService.loadProviderItems([
            request("a", result: .failure(CloudBatchTestError.unavailable)),
            request("b", result: .success(expected))
        ])
        XCTAssertEqual(result, expected)
    }

    func testAllSuccessfulEmptyProvidersReturnEmptyLibrary() async throws {
        let result = try await CloudLibraryService.loadProviderItems([
            request("a", result: .success([])),
            request("b", result: .success([]))
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testSuccessfulEmptyProviderStillCountsAsSuccess() async throws {
        let result = try await CloudLibraryService.loadProviderItems([
            request("a", result: .success([])),
            request("b", result: .failure(CloudBatchTestError.unavailable))
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testTotalFailureIsNotReportedAsEmptyLibrary() async {
        do {
            _ = try await CloudLibraryService.loadProviderItems([
                request("a", result: .failure(CloudBatchTestError.unavailable)),
                request("b", result: .failure(CloudBatchTestError.unavailable))
            ])
            XCTFail("Expected a provider error")
        } catch {
            XCTAssertTrue(error is CloudBatchTestError)
        }
    }

    func testExplicitProviderCancellationIsNotSwallowed() async {
        do {
            _ = try await CloudLibraryService.loadProviderItems([
                request("a", result: .failure(CancellationError())),
                request("b", result: .success([]))
            ])
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAlreadyCancelledBatchStartsNoProviderRequests() async {
        let counter = CloudBatchCounter()
        let provider = CloudBatchStub(providerId: "fixture") {
            await counter.record()
            return []
        }
        let task = Task {
            try await CloudLibraryService.loadProviderItems([(provider, "fixture-key")])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
    }

    func testLateSuccessAfterCancellationDoesNotBecomeEmptySuccess() async {
        let started = expectation(description: "provider started")
        let gate = CloudBatchGate { started.fulfill() }
        let provider = CloudBatchStub(providerId: "fixture") { await gate.load() }
        let task = Task {
            try await CloudLibraryService.loadProviderItems([(provider, "fixture-key")])
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.finish()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private enum CloudBatchTestError: Error { case unavailable }

private struct CloudBatchStub: CloudLibraryProvider {
    let providerId: String
    var displayName: String { "Fixture" }
    let handler: () async throws -> [CloudItem]

    func listItems(apiKey: String) async throws -> [CloudItem] { try await handler() }
    func resolvePlayback(apiKey: String, item: CloudItem, file: CloudFile) async -> CloudPlaybackResult {
        .notPlayable
    }
}

private actor CloudBatchCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}

private actor CloudBatchGate {
    private let onStarted: @Sendable () -> Void
    private var continuation: CheckedContinuation<[CloudItem], Never>?

    init(onStarted: @escaping @Sendable () -> Void) { self.onStarted = onStarted }

    func load() async -> [CloudItem] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStarted()
        }
    }

    func finish() {
        continuation?.resume(returning: [])
        continuation = nil
    }
}
