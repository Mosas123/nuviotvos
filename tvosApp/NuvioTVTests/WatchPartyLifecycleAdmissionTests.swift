import XCTest
@testable import NuvioTV

final class WatchPartyLifecycleAdmissionTests: XCTestCase {
    func testForegroundBeforeEngineRestorationKeepsAdmissionClosed() {
        var gate = PlayerLifecycleAdmission()
        gate.suspend(engineWillPark: true)
        gate.enterForeground()
        XCTAssertFalse(gate.canResume)
        gate.engineDidRestore()
        XCTAssertTrue(gate.canResume)
    }

    func testEngineRestorationBeforeForegroundKeepsAdmissionClosed() {
        var gate = PlayerLifecycleAdmission()
        gate.suspend(engineWillPark: true)
        gate.engineDidRestore()
        XCTAssertFalse(gate.canResume)
        gate.enterForeground()
        XCTAssertTrue(gate.canResume)
    }

    func testDuplicateRootSuspensionCannotErasePendingEngineRestore() {
        var gate = PlayerLifecycleAdmission()
        gate.suspend(engineWillPark: true)
        gate.suspend(engineWillPark: false)
        gate.enterForeground()
        XCTAssertTrue(gate.awaitingEngineRestore)
        XCTAssertFalse(gate.canResume)
    }

    func testInactivityWithoutEngineParkingResumesOnForeground() {
        var gate = PlayerLifecycleAdmission()
        gate.suspend(engineWillPark: false)
        XCTAssertFalse(gate.canResume)
        gate.enterForeground()
        XCTAssertTrue(gate.canResume)
    }
}
