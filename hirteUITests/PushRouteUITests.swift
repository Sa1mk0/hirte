import XCTest

/// What a tapped notification does, with real pushes: `scripts/push-check.sh` runs these one by one
/// and delivers the payloads with `xcrun simctl push` at the right moments. They skip without
/// `HIRTE_PUSH_CHECK` (the test can't send pushes itself). The notification's title is the terminal's
/// (`shop-api` for the demo's t3, `website` for t1), as the script sends it.
final class PushRouteUITests: XCTestCase {
    private static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var app: XCUIApplication { XCUIApplication() }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HIRTE_PUSH_CHECK"] != nil, "driven by scripts/push-check.sh")
    }

    /// First: a fresh install with the demo and notifications on, iOS's permission question allowed,
    /// so the simulator accepts pushes for the app. The script reads the demo machine's id afterwards.
    @MainActor
    func testPrepare() throws {
        launch()
        allowNotifications()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)  // the saved machines reach their file
    }

    /// The app isn't running; its notification waits in Notification Center. Tapping it starts the
    /// app on the terminal. (Started by the tap, the app has no fixed demo epoch, so the script sends
    /// this one without `created_ms`: the address alone decides, as for a sender that doesn't know it.)
    @MainActor
    func testColdTap() throws {
        XCTAssertNotEqual(app.state, .runningForeground, "the script terminated the app before sending")
        tapNotification(titled: "shop-api", lookInCenter: true)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        assertTerminalOpen("Run the database migration?")
    }

    /// The app is in the background when the notification arrives.
    @MainActor
    func testWarmTap() throws {
        launch()
        XCUIDevice.shared.press(.home)
        // The script sends it some seconds after the app started: its banner shows here.
        tapNotification(titled: "shop-api", lookInCenter: false)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        assertTerminalOpen("Run the database migration?")
    }

    /// In front with the terminal open: its own notification shows no banner, another terminal's does.
    @MainActor
    func testForegroundSuppression() throws {
        launch()
        let row = app.descendants(matching: .any).matching(identifier: "t3").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch.waitForExistence(timeout: 10))
        // The script sends t3's push now, t1's some seconds later.
        let own = Self.springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'shop-api'")).firstMatch
        let other = Self.springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'website'")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 90), "the other terminal's banner shows")
        XCTAssertFalse(own.exists, "no banner for the terminal on screen")
        shot("push-foreground-other-banner")
        // Nothing waits in Notification Center for the one on screen either.
        other.tap()
        assertTerminalOpen("Adding a dark mode toggle")
    }

    @MainActor
    private func launch() {
        let app = app
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hirte.demo", "YES", "-push.enabled", "YES"]
        app.launchEnvironment["HIRTE_DEMO_EPOCH_MS"] = ProcessInfo.processInfo.environment["HIRTE_DEMO_EPOCH_MS"] ?? ""
        app.launch()
    }

    /// Taps the notification's banner while it shows on the Home Screen (sent just before, or while
    /// this waits), else, when `lookInCenter`, the entry in Notification Center once it's there. (A
    /// tap in Notification Center doesn't open the app on the iOS 26 simulator, hence the banner.)
    @MainActor
    private func tapNotification(titled title: String, lookInCenter: Bool) {
        let springboard = Self.springboard
        let matches = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title))
        func tapIfShown(_ shot: String, timeout: TimeInterval) -> Bool {
            // The entry behind a stack's top matches too, off screen: take one that can be hit.
            guard matches.firstMatch.waitForExistence(timeout: timeout) else { return false }
            Thread.sleep(forTimeInterval: 0.5)  // still sliding in
            let shown = matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
            self.shot(shot)
            shown.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return app.wait(for: .runningForeground, timeout: 5)
        }
        if tapIfShown("push-notification-\(name)", timeout: lookInCenter ? 3 : 120) { return }
        guard lookInCenter else { XCTFail("no banner titled \(title) opened the app"); return }
        for _ in 0..<20 {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            if tapIfShown("push-notification-center-\(name)", timeout: 2) { return }
            // Close it again and look later.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("no notification titled \(title) opened the app")
    }

    /// Taps the button that allows notifications, in any language: the one that isn't "Don't Allow".
    @MainActor
    private func allowNotifications() {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            for alert in [Self.springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                let refuse = NSPredicate(format: "label CONTAINS[c] 'don' OR label CONTAINS[c] 'nicht' OR label CONTAINS[c] 'not'")
                alert.buttons.allElementsBoundByIndex.first { !refuse.evaluate(with: $0) }?.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    @MainActor
    private func assertTerminalOpen(_ title: String) {
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 20), "the terminal opens")
        // The screen's title is the agent's task, as in the lists.
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "it is the terminal the notification named")
        shot("push-opened-\(name)")
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            let file = name.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "", options: .regularExpression)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(file).png"))
        }
    }
}
