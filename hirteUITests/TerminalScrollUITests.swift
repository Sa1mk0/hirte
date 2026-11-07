import XCTest

/// Real continuous XCTest touches in the production sidebar and terminal. Generic demo only.
final class TerminalScrollUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testContinuousDragAndRelease() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "light"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", appearance, "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                               "-terminal.watch", "NO", "-terminal.fontSize", "13"]
        app.launchEnvironment["HIRTE_SCROLL_TRACE"] = "1"
        if let delay = ProcessInfo.processInfo.environment["HIRTE_SCROLL_TUI_MS"] {
            app.launchEnvironment["HIRTE_SCROLL_TUI_MS"] = delay
        }
        app.launch()
        let first = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let sidebar = app.collectionViews.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        func drag(_ element: XCUIElement, down: Bool, velocity: CGFloat, hold: TimeInterval) {
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: down ? 0.3 : 0.7))
            let end = start.withOffset(CGVector(dx: 0, dy: down ? 240 : -240))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: hold)
        }
        drag(sidebar, down: false, velocity: 160, hold: 0.4)
        drag(sidebar, down: true, velocity: 600, hold: 0)
        drag(screen, down: true, velocity: 160, hold: 0.4)
        drag(screen, down: true, velocity: 600, hold: 0)
        drag(screen, down: false, velocity: 160, hold: 0.4)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "scroll-" + appearance
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("scroll-" + appearance + ".png"))
        }
    }

    @MainActor
    func testWatchPinchKeyboardAndEdgeDrag() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "light"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", appearance, "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                               "-terminal.watch", "NO", "-terminal.fontSize", "13"]
        app.launchEnvironment["HIRTE_SCROLL_TRACE"] = "1"
        app.launch()
        let first = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        // A vertical drag in the edge zone must still scroll; a horizontal drag hides the list.
        let edge = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: 130)),
                   withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.3)
        XCTAssertTrue(app.staticTexts["Scrolled back. Tap to return to the live screen."].exists)
        screen.pinch(withScale: 1.25, velocity: 1)
        app.terminalAction("Watch Only").tap()
        XCTAssertTrue(app.terminalAction("Take Over").waitForExistence(timeout: 5))
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)),
                    withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0)
        XCTAssertTrue(app.terminalAction("Take Over").exists, "History scrolling never takes over")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "watch-scroll-" + appearance
        attachment.lifetime = .keepAlways
        add(attachment)
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 1) { hint.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Ordinary tap still focuses and takes over")
        XCTAssertTrue(app.terminalAction("Watch Only").exists)
        app.terminalAction("Hide Keyboard").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let hide = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        hide.press(forDuration: 0.05, thenDragTo: hide.withOffset(CGVector(dx: -150, dy: 0)),
                   withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0)
        XCTAssertFalse(app.buttons["Agents"].isHittable, "The horizontal edge swipe still hides the sidebar")
    }
}
