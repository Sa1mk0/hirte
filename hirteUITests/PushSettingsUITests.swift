import XCTest

/// The Notifications switch in Settings: off, on (iOS's question allowed), and off again. Saves
/// screenshots into `TEST_RUNNER_HIRTE_SHOTS`, named by appearance (`TEST_RUNNER_HIRTE_UI_APPEARANCE`).
final class PushSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNotificationsSwitch() throws {
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                "-hirte.demo", "YES", "-push.enabled", "NO"]
        app.launch()
        // Settings is in the title menu, below the machines.
        let row = app.descendants(matching: .any).matching(identifier: "t3").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the demo's terminals show")
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let settings = app.buttons["Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the title menu offers Settings")
        settings.tap()
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5), "Settings opened")
        // Below the terminal and demo sections: a row out of view doesn't exist until it scrolls in.
        let toggle = app.switches["Notifications (Beta)"]
        for _ in 0..<5 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the Notifications switch is in Settings")
        if toggle.frame.midY > app.frame.height * 0.6 { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        shot("push-settings-off-\(appearance)")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        allowNotifications(app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.buttons["Open iOS Settings"].waitForExistence(timeout: 2), "allowed: no way to iOS Settings offered")
        shot("push-settings-on-\(appearance)")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    /// iOS asks once whether Hirte may send notifications. Taps the button that allows it, in any
    /// language: the one that isn't "Don't Allow" / "Nicht erlauben".
    @MainActor
    private func allowNotifications(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                let refuse = NSPredicate(format: "label CONTAINS[c] 'don' OR label CONTAINS[c] 'nicht' OR label CONTAINS[c] 'not'")
                let accept = alert.buttons.allElementsBoundByIndex.first { !refuse.evaluate(with: $0) }
                accept?.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
