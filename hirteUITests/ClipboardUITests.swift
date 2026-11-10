import UIKit
import XCTest

/// Copy and paste by touch, and sending an image to the machine, on the demo shell. Saves
/// screenshots with HIRTE_SHOTS (TEST_RUNNER_HIRTE_SHOTS for xcodebuild).
final class ClipboardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSelectCopyPasteAndAttachInBothAppearances() throws {
        XCUIDevice.shared.orientation = .portrait
        let appearances = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"].map { [$0] } ?? ["light", "dark"]
        for appearance in appearances {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-appearance", appearance, "-hirte.demo", "YES",
                                   "-terminal.watch", "NO", "-terminal.fontSize", "13"]
            app.launch()
            let shell = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
            if !shell.waitForExistence(timeout: 5) { app.buttons["Terminals"].tap() }
            XCTAssertTrue(shell.waitForExistence(timeout: 10), "the demo shell is listed")
            shell.tap()
            let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 5))
            XCTAssertTrue(waitForScreen(screen, toContain: "Update dependencies"), "the shell's history is painted")

            // The commit hashes sit in column 0 of rows 1 to 4 (13 pt JetBrains Mono: ~7.8 × 17 pt cells).
            let cell = CGSize(width: 7.8, height: 17)
            func point(column: CGFloat, row: CGFloat) -> XCUICoordinate {
                screen.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: 10 + (column + 0.5) * cell.width, dy: 10 + (row + 0.5) * cell.height))
            }
            point(column: 3, row: 1).press(forDuration: 0.9)
            let copy = app.menuItems["Copy"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5), "holding a word offers Copy")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "selection-start").firstMatch.exists, "with handles")
            XCTAssertTrue(app.menuItems["Select All"].exists)
            shot(app, "clipboard-1-selected-" + appearance)
            copy.tap()
            XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
            // (The runner may not read what the app copied; the paste below shows it arrived.)

            // A hold on empty screen offers Paste; the hash lands on the prompt line.
            point(column: 20, row: 14).press(forDuration: 0.9)
            let paste = app.menuItems["Paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5), "holding empty screen offers Paste")
            XCTAssertFalse(app.menuItems["Copy"].exists, "nothing to copy there")
            shot(app, "clipboard-2-paste-menu-" + appearance)
            paste.tap()
            XCTAssertTrue(waitForScreen(screen, toContain: "❯ a41c9e2"), "the pasted hash is typed at the prompt")
            shot(app, "clipboard-3-pasted-" + appearance)

            // An image copied elsewhere (here: by the runner) is pasted the same way: it goes to the
            // machine and its path is typed after the hash. (The system's Paste reads the pasteboard
            // as the person's own action; a custom button would need iOS's paste permission, which
            // the simulator denies silently.)
            UIPasteboard.general.image = sampleImage()
            XCTAssertTrue(UIPasteboard.general.hasImages, "the runner put an image on the pasteboard")
            point(column: 20, row: 14).press(forDuration: 0.9)
            XCTAssertTrue(paste.waitForExistence(timeout: 5), "an image on the pasteboard offers Paste too")
            paste.tap()
            let progress = app.descendants(matching: .any).matching(identifier: "attachment-progress").firstMatch
            if progress.waitForExistence(timeout: 2) { shot(app, "clipboard-4-sending-" + appearance) }
            XCTAssertTrue(waitForScreen(screen, toContain: "/Users/demo/.cache/hirte/uploads/pasted-"), "the upload's path is typed")
            XCTAssertTrue(progress.waitForNonExistence(timeout: 5))
            shot(app, "clipboard-5-attached-" + appearance)

            // The attach menu in the title bar: photos and files, and the pasteboard's image.
            app.buttons["Attach"].tap()
            XCTAssertTrue(app.buttons["Photos…"].waitForExistence(timeout: 5), "the attach menu offers Photos")
            XCTAssertTrue(app.buttons["Files…"].exists, "and Files")
            shot(app, "clipboard-6-attach-menu-" + appearance)
            // Outside the menu: this tap only closes it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            XCTAssertTrue(app.buttons["Photos…"].waitForNonExistence(timeout: 5))

            // The key bar has a paste key as well.
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
            let hint = app.buttons["Continue"]
            if hint.waitForExistence(timeout: 1) { hint.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Paste"].firstMatch.waitForExistence(timeout: 5), "the key bar offers Paste")
            shot(app, "clipboard-7-keybar-" + appearance)
            app.terminate()
        }
    }

    /// Whether the screen shows `text`; a long line wraps, so the rows are read as one.
    @MainActor
    private func waitForScreen(_ screen: XCUIElement, toContain text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = screen.value as? String, value.replacingOccurrences(of: "\n", with: "").contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func sampleImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200), format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            UIColor.white.setFill()
            context.fill(CGRect(x: 40, y: 40, width: 240, height: 120))
        }
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
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
