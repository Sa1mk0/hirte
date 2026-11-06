import XCTest

final class LiveActivityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testExplicitFollowAndStop() throws {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance, "-hirte.demo", "YES"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        openLockScreenMenu(app, timeout: 10)
        app.buttons["Live Activity Settings…"].tap()
        let enabled = app.switches["Follow on Lock Screen (Beta)"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "1" { toggle(enabled) }
        shot("live-activity-off-" + appearance)
        toggle(enabled)
        XCTAssertEqual(enabled.value as? String, "1")
        let title = app.switches["Show task title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        if title.value as? String == "1" { toggle(title) }
        shot("live-activity-settings-" + appearance)
        app.navigationBars["Live Activity"].buttons["Done"].tap()
        openLockScreenMenu(app)
        let follow = app.buttons["Follow on Lock Screen"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.tap()
        openLockScreenMenu(app)
        let stop = app.buttons["Stop Following"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        shot("live-activity-following-" + appearance)
        stop.tap()
        openLockScreenMenu(app)
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        app.buttons["Live Activity Settings…"].tap()
        toggle(enabled)
        XCTAssertEqual(enabled.value as? String, "0")
        app.navigationBars["Live Activity"].buttons["Done"].tap()
    }

    /// A menu in the toolbar next to the lists, a section of More on a phone.
    @MainActor
    private func openLockScreenMenu(_ app: XCUIApplication, timeout: TimeInterval = 5) {
        let more = app.buttons["More"]
        let menu = app.buttons["Lock Screen"]
        XCTAssertTrue(menu.exists || more.waitForExistence(timeout: timeout), "the terminal's actions show")
        if more.exists { app.openMore() } else { menu.tap() }
        XCTAssertTrue(app.buttons["Live Activity Settings…"].waitForExistence(timeout: 5), "its actions show")
    }

    @MainActor
    private func toggle(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
