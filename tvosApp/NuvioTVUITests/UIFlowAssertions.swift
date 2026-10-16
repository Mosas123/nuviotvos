import XCTest

/// Records a failure when a required UI branch cannot run, while keeping
/// its actions guarded so a missing element is never interacted with.
@discardableResult
func requireUICondition(
    _ condition: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Bool {
    XCTAssertTrue(
        condition,
        "Required UI precondition is missing; the declared flow was not exercised.",
        file: file,
        line: line
    )
    return condition
}
