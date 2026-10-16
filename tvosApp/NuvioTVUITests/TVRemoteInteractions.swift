import XCTest
import CoreGraphics

/// Test-only navigation. Never send Select until the requested control has focus.
@MainActor
extension XCTestCase {
    func selectTVElement(
        _ element: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let control = tvControl(for: element, in: app, file: file, line: line),
              focusTVControl(control, in: app, file: file, line: line) else { return }
        XCUIRemote.shared.press(.select)
    }

    /// Swiping content up corresponds to moving focus down, not pressing Up.
    /// At an edge the remote may leave focus unchanged; callers own outcome assertions.
    func moveTVFocus(
        _ direction: XCUIRemote.Button, in app: XCUIApplication, within element: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard element.exists else {
            XCTFail("Remote navigation requires an existing container/control", file: file, line: line)
            return
        }
        if element.elementType == .scrollView {
            let focusedChild = element.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if !focusedChild.exists {
                guard let firstControl = element.buttons.allElementsBoundByIndex.first(where: { $0.isHittable }),
                      focusTVControl(firstControl, in: app, file: file, line: line) else {
                    XCTFail("No focusable control found in the requested scroll view", file: file, line: line)
                    return
                }
            }
        } else {
            guard let control = tvControl(for: element, in: app, file: file, line: line),
                  focusTVControl(control, in: app, file: file, line: line) else { return }
        }
        XCUIRemote.shared.press(direction)
    }

    private func tvControl(
        for element: XCUIElement, in app: XCUIApplication,
        file: StaticString, line: UInt
    ) -> XCUIElement? {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("Requested TV control does not exist", file: file, line: line)
            return nil
        }
        guard element.elementType == .image else { return element }
        // Legacy suites select poster images. An image is not necessarily focusable;
        // resolve its unique enclosing button from the accessibility hierarchy.
        let frame = element.frame
        let identifier = element.identifier
        let label = element.label
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite else {
            XCTFail("Poster has no usable accessibility frame", file: file, line: line)
            return nil
        }
        let controls = app.buttons.allElementsBoundByIndex.filter { button in
            button.images.allElementsBoundByIndex.contains { image in
                image.frame == frame && image.identifier == identifier && image.label == label
            }
        }
        guard controls.count == 1 else {
            XCTFail("Poster needs one identifiable enclosing button; update the fixture/selector", file: file, line: line)
            return nil
        }
        return controls[0]
    }

    private func focusTVControl(
        _ target: XCUIElement, in app: XCUIApplication,
        file: StaticString, line: UInt
    ) -> Bool {
        let identifier = target.identifier
        let label = target.label
        guard !identifier.isEmpty || !label.isEmpty else {
            XCTFail("TV navigation needs a labeled or identified control", file: file, line: line)
            return false
        }
        var attemptedMoves = Set<String>()
        // Geometry guides real remote presses. Custom focus guides may require a
        // fixture-specific route: fail after a bounded search, never select blindly.
        for _ in 0..<40 {
            guard target.exists, target.identifier == identifier, target.label == label else {
                XCTFail("Target changed during focus navigation", file: file, line: line)
                return false
            }
            if target.hasFocus { return true }
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else {
                XCTFail("App has no observable focused element", file: file, line: line)
                return false
            }
            let from = focused.frame
            let to = target.frame
            guard !from.isEmpty, !to.isEmpty, !from.isNull, !to.isNull,
                  !from.isInfinite, !to.isInfinite else {
                XCTFail("Focus navigation requires usable frames", file: file, line: line)
                return false
            }
            let dx = to.midX - from.midX
            let dy = to.midY - from.midY
            let horizontal: XCUIRemote.Button = dx >= 0 ? .right : .left
            let vertical: XCUIRemote.Button = dy >= 0 ? .down : .up
            let preferred = abs(dx) > abs(dy) ? [horizontal, vertical] : [vertical, horizontal]
            let choices: [XCUIRemote.Button] = preferred + [.up, .down, .left, .right]
            let state = "\(focused.identifier)|\(focused.label)|\(from)"
            guard let direction = choices.first(where: { !attemptedMoves.contains("\(state)|\($0)") }) else { break }
            attemptedMoves.insert("\(state)|\(direction)")
            XCUIRemote.shared.press(direction)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                target.hasFocus || !focused.exists ||
                    "\(focused.identifier)|\(focused.label)|\(focused.frame)" != state
            }, object: nil)
            _ = XCTWaiter.wait(for: [changed], timeout: 0.3)
        }
        XCTFail("Requested control did not gain focus within 40 remote presses", file: file, line: line)
        return false
    }
}
