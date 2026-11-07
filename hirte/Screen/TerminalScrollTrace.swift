#if DEBUG
import UIKit
import HerdrKit

/// Opt-in, generic demo only. UIKit callbacks and offsets, never physical scanout or SSH RTT.
@MainActor
final class TerminalScrollTrace: NSObject {
    static let shared: TerminalScrollTrace? = {
        guard ProcessInfo.processInfo.environment["HIRTE_SCROLL_TRACE"] == "1",
              UserDefaults.standard.bool(forKey: "hirte.demo") else { return nil }
        return TerminalScrollTrace()
    }()
    private var file: FileHandle?
    private var link: CADisplayLink?
    private weak var canvas: TerminalCanvasView?
    private weak var sidebar: UIScrollView?

    override init() {
        super.init()
        let url = URL.documentsDirectory.appendingPathComponent("scroll-trace.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("time,event,state,touch_y,offset,cell_height\n".utf8))
        file = try? FileHandle(forWritingTo: url)
        try? file?.seekToEnd()
    }

    func attach(_ canvas: TerminalCanvasView) {
        self.canvas = canvas
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func record(_ event: String, state: Int = 0, touch: CGFloat = 0, offset: CGFloat = 0, height: CGFloat = 0) {
        let row = String(format: "%.6f,%@,%d,%.3f,%.3f,%.3f\n", CACurrentMediaTime(), event, state, touch, offset, height)
        try? file?.write(contentsOf: Data(row.utf8))
    }

    func content(_ event: String, frame: ScreenFrame) {
        guard let line = frame.lines.first else { return }
        let text = line.map(\.text).joined()
        guard let number = text.split(separator: " ").dropFirst().first.flatMap({ Double($0) }) else { return }
        record(event, offset: number)
    }

    @objc private func tick() {
        guard let canvas, let window = canvas.window else { return }
        if sidebar?.window == nil {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, !scroll.isDescendant(of: canvas),
                   scroll.contentSize.height > scroll.bounds.height, scroll.bounds.width < window.bounds.width / 2 {
                    return scroll
                }
                return view.subviews.lazy.compactMap(find).first
            }
            sidebar = find(window)
        }
        if let sidebar {
            let pan = sidebar.panGestureRecognizer
            record("sidebar", state: pan.state.rawValue, touch: pan.location(in: window).y, offset: sidebar.contentOffset.y)
        }
    }
}
#endif
