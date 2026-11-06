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
        let menu = app.buttons["Lock Screen"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
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
        menu.tap()
        let follow = app.buttons["Follow on Lock Screen"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.tap()
        menu.tap()
        let stop = app.buttons["Stop Following"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        shot("live-activity-following-" + appearance)
        stop.tap()
        menu.tap()
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        app.buttons["Live Activity Settings…"].tap()
        toggle(enabled)
        XCTAssertEqual(enabled.value as? String, "0")
        app.navigationBars["Live Activity"].buttons["Done"].tap()
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
