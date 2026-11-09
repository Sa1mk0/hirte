import Foundation
import Testing
@testable import TerminalCore

private func shiftFixture(_ offset: Int = 0) -> ScreenFrame {
    var frame = ScreenFrame.empty
    frame.cols = 1
    frame.rows = 26
    frame.lines = (0..<26).map { y in
        [ScreenCell(text: y == 0 ? "header" : (y >= 24 ? "fixed \(y)" : "item \(y + offset)"), style: .plain, width: 1)]
    }
    return frame
}

@Test func detectsSignedBandsAndFixedFooter() {
    for k in [1, -1, 3, -3, 9, -9] {
        let old = shiftFixture()
        let new = shiftFixture(k)
        let shift = new.shift(from: old, wheelSign: k, wheelAge: 0.1)
        #expect(shift?.rows == k)
        #expect(shift?.region == 1..<24)
    }
}

@Test func changingStatusOutsideBandDoesNotDefeatShift() {
    let old = shiftFixture()
    var new = shiftFixture(3)
    new.lines[25][0].text = "new status"
    #expect(new.shift(from: old, wheelSign: 1, wheelAge: 0)?.region == 1..<24)
}

@Test func rejectsAmbiguousOrUnsafeShifts() {
    let old = shiftFixture()
    let shifted = shiftFixture(1)
    #expect(shifted.shift(from: old, wheelSign: 0, wheelAge: 0) == nil)
    #expect(shifted.shift(from: old, wheelSign: 1, wheelAge: 0.301) == nil)
    #expect(shifted.shift(from: old, wheelSign: -1, wheelAge: 0) == nil)
    var blank = old
    blank.lines = old.lines.map { _ in [ScreenCell(text: "", style: .plain, width: 1)] }
    #expect(blank.shift(from: blank, wheelSign: 1, wheelAge: 0) == nil)
    var repeated = old
    repeated.lines = old.lines.map { _ in [ScreenCell(text: "blank", style: .plain, width: 1)] }
    // A repetitive overlap with four changed rows still must not count as scroll evidence.
    for y in [0, 1, 24, 25] { repeated.lines[y][0].text = "changed" }
    #expect(repeated.shift(from: blank, wheelSign: 1, wheelAge: 0) == nil)
    var redraw = shifted
    redraw.lines = shifted.lines.map { line in
        var line = line; line[0].text += " redraw"; return line
    }
    #expect(redraw.shift(from: old, wheelSign: 1, wheelAge: 0) == nil)
    var partial = shifted
    for y in stride(from: 2, to: 24, by: 2) { partial.lines[y] = old.lines[y] }
    #expect(partial.shift(from: old, wheelSign: 1, wheelAge: 0) == nil)
    var cursor = shifted
    cursor.cursor = ScreenCursor(x: 0, y: 10, shape: .block, blinking: false)
    #expect(cursor.shift(from: old, wheelSign: 1, wheelAge: 0) == nil)
    #expect(shifted.shift(from: cursor, wheelSign: 1, wheelAge: 0) == nil)
    var selected = shifted
    selected.selection = Array(repeating: nil, count: 26)
    selected.selection[10] = 0...0
    #expect(selected.shift(from: old, wheelSign: 1, wheelAge: 0) == nil)
    var geometry = shifted
    geometry.cols += 1
    #expect(geometry.shift(from: old, wheelSign: 1, wheelAge: 0) == nil)
    var colors = shifted
    colors.background.r = 0
    #expect(colors.shift(from: old, wheelSign: 1, wheelAge: 0) == nil)
}
