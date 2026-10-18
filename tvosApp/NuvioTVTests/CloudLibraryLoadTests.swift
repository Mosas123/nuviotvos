import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class CloudLibraryLoadTests: XCTestCase {
    private func item(_ id: String) -> CloudItem {
        CloudItem(providerId: "torbox", id: id, type: .torrent, name: id,
                  status: nil, sizeBytes: nil, files: [])
    }

    private func store() -> UserDefaults {
        UserDefaults(suiteName: "nuvio.tv.tests.cloud-load.\(UUID().uuidString)")!
    }

    func testSuccessfulLoadPublishesItemsAndFinishesLoading() async {
        let expected = [item("current")]
        let model = CloudLibraryViewModel(store: store(), loadItems: { expected })
        await model.load()
        XCTAssertEqual(model.items, expected)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testCurrentEmptyLoadStillReportsEmptyLibrary() async {
        let model = CloudLibraryViewModel(store: store(), loadItems: { [] })
        await model.load()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testAlreadyCancelledLoadDoesNotStartProviderWork() async {
        var calls = 0
        let model = CloudLibraryViewModel(store: store()) {
            calls += 1
            return []
        }
        let task = Task { await model.load() }
        task.cancel()
        await task.value
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testCancelledLateSuccessPreservesExistingItems() async {
        let started = expectation(description: "pending load")
        let gate = CloudLoadGate { started.fulfill() }
        let existing = [item("existing")]
        var calls = 0
        let model = CloudLibraryViewModel(store: store()) {
            calls += 1
            if calls == 1 { return existing }
            return try await gate.load()
        }
        await model.load()
        let pending = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        gate.finish(.success([]))
        await pending.value
        XCTAssertEqual(model.items, existing)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testOlderSuccessCannotReplaceLatestItems() async {
        let started = expectation(description: "old load")
        let gate = CloudLoadGate { started.fulfill() }
        let current = [item("current")]
        var calls = 0
        let model = CloudLibraryViewModel(store: store()) {
            calls += 1
            if calls == 1 { return try await gate.load() }
            return current
        }
        let old = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        await model.load()
        gate.finish(.success([]))
        await old.value
        XCTAssertEqual(model.items, current)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testOlderFailureCannotStopNewerSpinnerOrPublishError() async {
        let firstStarted = expectation(description: "old load")
        let secondStarted = expectation(description: "new load")
        let firstGate = CloudLoadGate { firstStarted.fulfill() }
        let secondGate = CloudLoadGate { secondStarted.fulfill() }
        var calls = 0
        let model = CloudLibraryViewModel(store: store()) {
            calls += 1
            return try await (calls == 1 ? firstGate : secondGate).load()
        }
        let old = Task { await model.load() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let latest = Task { await model.load() }
        await fulfillment(of: [secondStarted], timeout: 2)
        firstGate.finish(.failure(URLError(.cannotConnectToHost)))
        await old.value
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.errorMessage)
        let expected = [item("current")]
        secondGate.finish(.success(expected))
        await latest.value
        XCTAssertEqual(model.items, expected)
        XCTAssertFalse(model.isLoading)
    }
}

@MainActor
private final class CloudLoadGate {
    private let onStarted: () -> Void
    private var continuation: CheckedContinuation<[CloudItem], Error>?

    init(onStarted: @escaping () -> Void) { self.onStarted = onStarted }

    func load() async throws -> [CloudItem] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onStarted()
        }
    }

    func finish(_ result: Result<[CloudItem], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
