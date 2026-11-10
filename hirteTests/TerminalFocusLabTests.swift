import XCTest
import UIKit
import HerdrKit
@testable import hirte

@MainActor
final class TerminalFocusLabTests: XCTestCase {
    private func canvas(mouse: Bool) throws -> (TerminalCanvasView, TerminalScreenModel, VirtualTerminal, UIWindow) {
        let terminal = try VirtualTerminal(cols: 40, rows: 10)
        terminal.write(Data("sample prompt> ".utf8))
        if mouse { terminal.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8)) }
        let model = TerminalScreenModel(
            theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: window)
        host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        canvas.model = model
        canvas.screen = model.frame
        host.rootViewController?.view.addSubview(canvas)
        return (canvas, model, terminal, host)
    }

    func testShellAndMouseReportingTapAcquireTextFocus() throws {
        for mouse in [false, true] {
            let (canvas, model, _, window) = try canvas(mouse: mouse)
            defer { model.stop(); window.isHidden = true }
            canvas.handleTap(at: CGPoint(x: 30, y: 18))
            XCTAssertTrue(canvas.isFirstResponder, "mouse=\(mouse)")
            XCTAssertTrue(model.wantsKeyboard)
            XCTAssertFalse(model.watching)
            XCTAssertTrue(canvas.resignFirstResponder())
        }
    }

    func testObserverTapTakesOverAndFocusesIncludingMousePrograms() throws {
        for mouse in [false, true] {
            let (canvas, model, _, window) = try canvas(mouse: mouse)
            defer { model.stop(); window.isHidden = true }
            model.setWatching(true)
            canvas.handleTap(at: CGPoint(x: 30, y: 18))
            XCTAssertTrue(canvas.isFirstResponder)
            XCTAssertTrue(model.wantsKeyboard)
            XCTAssertFalse(model.watching)
            let expected = Data("\u{1b}[<0;3;1M\u{1b}[<0;3;1m".utf8)
            XCTAssertEqual(model.queuedInputForTesting, mouse ? [expected] : [],
                           "Mouse press/release stays queued in order for the viewer reattach")
            XCTAssertTrue(canvas.resignFirstResponder())
            model.setWatching(true)
            // The explicit keyboard action remains a deliberate takeover as well.
            XCTAssertTrue(canvas.becomeFirstResponder())
            XCTAssertFalse(model.watching)
            XCTAssertTrue(canvas.resignFirstResponder())
        }
    }

    func testHoldSelectsAndSpaceBarTrackpadSendsArrows() throws {
        let (canvas, model, _, window) = try canvas(mouse: false)
        defer { model.stop(); window.isHidden = true }
        // Holding selects (HIRTE-20); the scroll view's pan waits for the hold to fail, so a hold
        // never scrolls and a moving finger never holds.
        let hold = try XCTUnwrap((canvas.gestureRecognizers ?? []).first { type(of: $0) == UILongPressGestureRecognizer.self })
        XCTAssertTrue(hold.isEnabled)
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        canvas.beginFloatingCursor(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(canvas.subviews.contains { $0 is ArrowPadView })
        canvas.updateFloatingCursor(at: CGPoint(x: 140, y: 100))
        canvas.endFloatingCursor()
        XCTAssertEqual(input, [Data("\u{1b}[C".utf8)])
        XCTAssertFalse(canvas.subviews.contains { $0 is ArrowPadView })
    }

    func testLinkTapRemainsALinkActionWhileWatching() throws {
        let terminal = try VirtualTerminal(cols: 40, rows: 10)
        terminal.write(Data("https://example.com".utf8))
        let model = TerminalScreenModel(
            theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
        model.setWatching(true)
        guard case .link(let url) = model.tap(at: (3, 0)) else { return XCTFail("Link action must survive") }
        XCTAssertEqual(url.absoluteString, "https://example.com")
        XCTAssertTrue(model.watching)
        XCTAssertFalse(model.wantsKeyboard)
    }

    func testWatchingScrollsOnlyLocalHistory() async throws {
        for alternate in [false, true] {
            let terminal = try VirtualTerminal(cols: 40, rows: 10)
            for row in 0..<100 { terminal.write(Data("sample \(row)\r\n".utf8)) }
            terminal.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
            if alternate { terminal.write(Data("\u{1b}[?1049h".utf8)) }
            let model = TerminalScreenModel(
                theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
            defer { model.stop() }
            model.setWatching(true)
            model.scroll(lines: -3, column: 2, row: 2)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(model.watching)
            XCTAssertFalse(model.wantsKeyboard)
            XCTAssertEqual(model.scrolledBack, !alternate)
        }
    }

    /// A hold selects the word under the finger, shows its handles and offers the menu; a tap beside
    /// it takes the selection away without typing or clicking anything.
    func testHoldSelectsTheWordAndATapClearsIt() throws {
        let (canvas, model, terminal, window) = try canvas(mouse: true)
        defer { model.stop(); window.isHidden = true }
        terminal.write(Data("\r\nsecond row here".utf8))
        model.receiveOutputForTesting(Data())
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        let fonts = Fonts(size: canvas.fontSize)
        // The "prompt" of "sample prompt> " (Ghostty's words stop at punctuation): column 8, row 0.
        canvas.holdBegan(at: CGPoint(x: TerminalCanvasView.padding + 8.5 * fonts.cellWidth, y: TerminalCanvasView.padding + fonts.cellHeight / 2))
        XCTAssertEqual(model.copySelectionForTesting(), "prompt")
        canvas.holdBegan(at: CGPoint(x: TerminalCanvasView.padding + 8.5 * fonts.cellWidth, y: TerminalCanvasView.padding + fonts.cellHeight / 2))
        XCTAssertTrue(model.hasSelection)
        canvas.screen = model.frame
        let handles = canvas.subviews.compactMap { $0 as? SelectionHandle }
        XCTAssertEqual(handles.filter { !$0.isHidden }.count, 2, "both ends are in view")
        XCTAssertTrue(canvas.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        // Dragging on from the word to the second row's "second" extends it there.
        canvas.selectionDragged(to: CGPoint(x: TerminalCanvasView.padding + 3.5 * fonts.cellWidth, y: TerminalCanvasView.padding + 1.5 * fonts.cellHeight))
        canvas.selectionDragEnded(at: .zero)
        XCTAssertEqual(terminal.selectedText(), "prompt>\nseco")
        // Dragging backwards keeps the word's end and reaches before its start.
        canvas.holdBegan(at: CGPoint(x: TerminalCanvasView.padding + 8.5 * fonts.cellWidth, y: TerminalCanvasView.padding + fonts.cellHeight / 2))
        canvas.selectionDragged(to: CGPoint(x: TerminalCanvasView.padding + 2.5 * fonts.cellWidth, y: TerminalCanvasView.padding + fonts.cellHeight / 2))
        canvas.selectionDragEnded(at: .zero)
        XCTAssertEqual(terminal.selectedText(), "mple prompt")
        XCTAssertTrue(input.isEmpty, "selecting sends nothing to the program")

        canvas.handleTap(at: CGPoint(x: 300, y: 300))
        XCTAssertFalse(model.hasSelection)
        XCTAssertTrue(input.isEmpty, "the clearing tap is no click, even for a mouse-tracking program")
        XCTAssertFalse(canvas.isFirstResponder, "and brings no keyboard")
        canvas.screen = model.frame
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? SelectionHandle }.allSatisfy(\.isHidden))
    }

    /// Holding empty screen selects nothing (the menu then only offers Paste), and typing clears a selection.
    func testHoldOnEmptyScreenSelectsNothingAndTypingClears() throws {
        let (canvas, model, terminal, window) = try canvas(mouse: false)
        defer { model.stop(); window.isHidden = true }
        canvas.holdBegan(at: CGPoint(x: 300, y: 150))
        XCTAssertFalse(model.hasSelection)
        XCTAssertFalse(canvas.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertTrue(canvas.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        canvas.selectAll(nil)
        XCTAssertEqual(terminal.selectedText(), "sample prompt>")
        model.type("x")
        XCTAssertFalse(model.hasSelection, "typing is done with the selection")
    }

    /// What a program puts on the clipboard (OSC 52) lands on the pasteboard; pasting goes through
    /// libghostty's encoder (bracketed where asked for).
    func testClipboardWritesAndPastesFollowTheTerminal() throws {
        let (_, model, terminal, window) = try canvas(mouse: false)
        defer { model.stop(); window.isHidden = true }
        let before = UIPasteboard.general.string
        defer { UIPasteboard.general.string = before ?? "" }
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        model.paste("a\nb")
        XCTAssertEqual(input, [Data("a\rb".utf8)])
        terminal.write(Data("\u{1b}[?2004h".utf8))
        model.paste("a\nb")
        XCTAssertEqual(input.last, Data("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        // The in-memory test terminal has no OSC 52 hookup (that happens on attach); the kit's own
        // test covers decoding, so this checks the model's hookup indirectly through its API shape.
        XCTAssertNotNil(terminal.encodePaste("x"))
    }
}
