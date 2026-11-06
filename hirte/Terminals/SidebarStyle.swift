import SwiftUI

/// The sidebar's measures, one for each role, shared by both views. A selected row's fill, cards
/// and materials stay the system's own.
enum SidebarMetrics {
    static let iconSize: CGFloat = 26
    static let iconRadius: CGFloat = 7
    /// Between the icon, the text and what's at the end of a row.
    static let columnGap: CGFloat = 10
    static let lineGap: CGFloat = 3
    /// Brings small trailing content level with the first line of a row's title.
    static let titleLineInset: CGFloat = 4
    static let touchTarget: CGFloat = 44
    /// How far a child sits in from its parent: its line runs under the middle of the parent's icon.
    static let familyStep: CGFloat = 26
    static let maxFamilyDepth = 3
    /// How far a family's line reaches past its row, over the list's own margins, to meet the next.
    static let railOverreach: CGFloat = 16
}

extension Color {
    /// A terminal waits for you: quiet enough for a dot and a glyph, and never a fill of its own.
    /// Readable on the sidebar and on a selected row, together with the dot's ring.
    static let needsYou = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xe9 / 255, green: 0xa2 / 255, blue: 0x6b / 255, alpha: 1)
            : UIColor(red: 0xa8 / 255, green: 0x54 / 255, blue: 0x00 / 255, alpha: 1)
    })
    /// Behind the sidebar next to the detail column: app chrome, whatever the terminal's theme.
    static let sidebarBackground = Color(uiColor: .secondarySystemBackground)
    /// The fill of a selected sidebar row. Rows set their text colors below themselves, so that
    /// the system's white labels for a selected row don't have to work on every fill.
    static let sidebarSelection = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x4a / 255, green: 0x4f / 255, blue: 0x55 / 255, alpha: 1)
            : UIColor(red: 0xc9 / 255, green: 0xcd / 255, blue: 0xd2 / 255, alpha: 1)
    })
    /// The app's accent where a surrounding tint means something else, or for a primary action.
    /// By name: `Color.accentColor` follows the surrounding tint.
    static let appControl = Color("AccentColor")
    /// Text in a sidebar row, the same selected or not.
    static let rowPrimary = Color(uiColor: .label)
    static let rowSecondary = Color(uiColor: UIColor.label.withAlphaComponent(0.65))
    /// Behind pills and icons.
    static let rowFill = Color(uiColor: UIColor.label.withAlphaComponent(0.1))
    /// Lines: a family's rail, a status dot's ring. Opaque, so that lines meeting don't add up.
    static let rowRule = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x7a / 255, green: 0x7e / 255, blue: 0x84 / 255, alpha: 1)
            : UIColor(red: 0x8f / 255, green: 0x92 / 255, blue: 0x97 / 255, alpha: 1)
    })
}

extension Text {
    /// A status or space name: the list's structure, stronger than a row's second line.
    func sidebarSectionTitle() -> Text {
        font(.subheadline.weight(.semibold)).foregroundStyle(Color.rowPrimary)
    }

    /// Facts under a row's title, and anything of the same weight next to it.
    func sidebarDetail() -> Text {
        font(.caption).foregroundStyle(Color.rowSecondary)
    }
}

/// How many rows a section has, readable on its own rather than dimmed twice by the header.
struct SidebarCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Color.rowSecondary)
    }
}

/// How many terminals wait for you: the hand and a number, the form says it as well as the color.
struct NeedsYouBadge: View {
    let count: Int

    static func text(_ count: Int) -> String { "\(count) \(count == 1 ? "needs" : "need") you" }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.raised.fill")
                .font(.caption2)
                .foregroundStyle(Color.needsYou)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.rowPrimary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.rowFill, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text(count))
    }
}

/// Where a row sits in its family: which lines pass through it, so that a parent and its children
/// read as one thing while each stays its own row.
struct FamilyRails: Equatable {
    var depth = 0
    /// The levels, from 1, whose line goes on below this row to a later sibling.
    var continuing: Set<Int> = []
    /// Its children come right after it.
    var opensDown = false

    var inFamily: Bool { depth > 0 || opensDown }
    /// The list's lines between the members of a family, not those around it.
    var hiddenSeparators: VerticalEdge.Set {
        var edges: VerticalEdge.Set = []
        if depth > 0 { edges.insert(.top) }
        if opensDown || !continuing.isEmpty { edges.insert(.bottom) }
        return edges
    }
    var indent: CGFloat { CGFloat(depth) * SidebarMetrics.familyStep }

    /// For rows in display order, from how deep each one is.
    static func layout(depths: [Int]) -> [FamilyRails] {
        let depths = depths.map { min($0, SidebarMetrics.maxFamilyDepth) }
        return depths.indices.map { index in
            let depth = depths[index]
            let after = depths[(index + 1)...]
            let continuing = depth < 1 ? [] : (1...depth).filter { level in
                // The next row no deeper than this level: its sibling, or the end of the branch.
                after.first { $0 <= level } == level
            }
            return FamilyRails(depth: depth, continuing: Set(continuing), opensDown: (after.first ?? 0) > depth)
        }
    }
}

/// One row's layout in both of the sidebar's views: icon, text, and what's at its end.
struct SidebarRow<Icon: View, Content: View, Trailing: View>: View {
    var rails = FamilyRails()
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: SidebarMetrics.columnGap) {
            icon.overlay {
                if rails.depth > 0 {
                    Color.clear.accessibilityElement().accessibilityLabel("Started by its parent")
                }
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, rails.indent)
        .background { FamilyRailsView(rails: rails) }
    }
}

private struct FamilyRailsView: View {
    let rails: FamilyRails

    var body: some View {
        if rails.inFamily {
            Canvas { context, size in
                var path = Path()
                let step = SidebarMetrics.familyStep
                let reach = SidebarMetrics.railOverreach
                let iconMiddle = reach + SidebarMetrics.iconSize / 2
                func line(_ level: Int) -> CGFloat { CGFloat(level - 1) * step + SidebarMetrics.iconSize / 2 }
                for level in rails.continuing {
                    path.move(to: CGPoint(x: line(level), y: 0))
                    path.addLine(to: CGPoint(x: line(level), y: size.height))
                }
                if rails.depth > 0 {
                    let x = line(rails.depth)
                    let corner: CGFloat = 6
                    if rails.continuing.contains(rails.depth) {
                        path.move(to: CGPoint(x: x, y: iconMiddle))
                    } else {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: iconMiddle - corner))
                        path.addQuadCurve(to: CGPoint(x: x + corner, y: iconMiddle), control: CGPoint(x: x, y: iconMiddle))
                    }
                    path.addLine(to: CGPoint(x: rails.indent - 2, y: iconMiddle))
                }
                if rails.opensDown {
                    let x = line(rails.depth + 1)
                    path.move(to: CGPoint(x: x, y: reach + SidebarMetrics.iconSize + 2))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(.rowRule), lineWidth: 1.5)
            }
            // The list keeps margins between rows that a row can't remove; the lines have to cross them.
            .padding(.vertical, -SidebarMetrics.railOverreach)
            // Hidden, or the row counts as reaching over its neighbours, for VoiceOver and hit tests.
            .accessibilityHidden(true)
        }
    }
}
