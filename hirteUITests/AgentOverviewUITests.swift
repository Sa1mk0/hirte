import XCTest

final class AgentOverviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testStatusModesAndRowCustomization() throws {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-appearance", appearance]
        app.launch()
        if app.buttons["Try the Demo"].waitForExistence(timeout: 3) { app.buttons["Try the Demo"].tap() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.waitForExistence(timeout: 10))
        if app.buttons["Agents"].exists { app.buttons["Agents"].tap() }
        let initialMenu = app.buttons["agent-overview-menu"]
        initialMenu.tap()
        app.buttons["Customize Rows…"].tap()
        let initialReset = app.buttons["Reset to Defaults"]
        for _ in 0..<5 where !initialReset.isHittable { app.swipeUp() }
        if initialReset.isEnabled { initialReset.tap() }
        app.navigationBars["Agent Overview"].buttons["Done"].tap()
        shot("overview-individual-" + appearance)

        let menu = app.buttons["agent-overview-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        shot("overview-menu-" + appearance)
        XCTAssertTrue(app.buttons["Nested"].waitForExistence(timeout: 5))
        app.buttons["Nested"].tap()
        XCTAssertTrue(app.buttons["children-t1"].waitForExistence(timeout: 5))
        shot("overview-nested-" + appearance)
        app.buttons["children-t1"].tap()
        app.buttons["children-t1"].tap()

        menu.tap()
        app.buttons["Customize Rows…"].tap()
        XCTAssertTrue(app.navigationBars["Agent Overview"].waitForExistence(timeout: 5))
        shot("overview-customize-" + appearance)
        let branch = app.switches["Branch"]
        for _ in 0..<4 where !branch.isHittable { app.swipeUp() }
        XCTAssertTrue(branch.isHittable)
        XCTAssertEqual(branch.value as? String, "1")
        branch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: branch)], timeout: 3), .completed)
        let reset = app.buttons["Reset to Defaults"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        for _ in 0..<4 where !branch.isHittable { app.swipeDown() }
        XCTAssertEqual(branch.value as? String, "1")
        app.navigationBars["Agent Overview"].buttons["Done"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        shot("overview-reset-" + appearance)
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
