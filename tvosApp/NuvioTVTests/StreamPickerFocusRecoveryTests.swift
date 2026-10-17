import XCTest
@testable import NuvioTV

final class StreamPickerFocusRecoveryTests: XCTestCase {
    func testUserNavigationTakesPriorityOverOriginalRememberedSource() {
        let result = StreamPickerFocusRecovery.target(
            lastFocusedID: "source-70", restoredSourceID: "source-2",
            streamIDs: (0..<100).map { "source-\($0)" },
            filterIDs: ["filter::all"], fallbackFilterID: "filter::all"
        )
        XCTAssertEqual(result, "source-70")
    }

    func testFilterFocusDoesNotJumpBackToStreamAfterFocusLoss() {
        for filter in ["filter::all", "filter::addon", "filter::sort", "filter::cached"] {
            XCTAssertEqual(StreamPickerFocusRecovery.target(
                lastFocusedID: filter, restoredSourceID: "saved", streamIDs: ["saved", "other"],
                filterIDs: ["filter::all", "filter::addon", "filter::sort", "filter::cached"],
                fallbackFilterID: "filter::all"
            ), filter)
        }
    }

    func testRemovedCardOrFilterFallsBackToAvailableRememberedSource() {
        for removed in ["removed-source", "filter::removed-addon"] {
            XCTAssertEqual(StreamPickerFocusRecovery.target(
                lastFocusedID: removed, restoredSourceID: "saved", streamIDs: ["first", "saved"],
                filterIDs: ["filter::all"], fallbackFilterID: "filter::all"
            ), "saved")
        }
    }

    func testMissingHistoryUsesFirstCardOrAllFilterForEmptyResults() {
        XCTAssertEqual(StreamPickerFocusRecovery.target(
            lastFocusedID: "gone", restoredSourceID: "gone-too", streamIDs: ["first", "second"],
            filterIDs: ["filter::all"], fallbackFilterID: "filter::all"
        ), "first")
        XCTAssertEqual(StreamPickerFocusRecovery.target(
            lastFocusedID: "gone", restoredSourceID: "gone-too", streamIDs: [],
            filterIDs: ["filter::all"], fallbackFilterID: "filter::all"
        ), "filter::all")
    }
}
