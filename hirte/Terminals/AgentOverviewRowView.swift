import HerdrKit
import SwiftUI

struct AgentOverviewRowView: View {
    let terminal: Terminal
    let state: AgentOverviewState
    let context: TerminalContext
    let preferences: AgentOverviewPreferences
    var space: String?
    var rails = FamilyRails()
    /// The agent it's shown under: what that row already says isn't repeated, except who runs it.
    var parent: TerminalContext?
    var reason: Terminal?
    var familyState: AgentOverviewState?
    var childCount = 0
    var expanded: Binding<Bool>?
    @State private var explaining = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SidebarRow(rails: rails) {
            if preferences.fields.contains(.icon) {
                AgentProviderIcon(terminal: terminal)
            } else if rails.inFamily {
                // The family's line needs its column.
                Color.clear.frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            }
        } content: {
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                Text(terminal.headline(inSpace: true))
                    .lineLimit(large ? nil : 2)
                    .foregroundStyle(Color.rowPrimary)
                if large { statusButton }
                if let message { Text(message).sidebarDetail().lineLimit(large ? nil : 1) }
                // Where it works, then who runs it: each line keeps its facts together, and a
                // long branch can't take the account with it.
                if !contextLine.isEmpty { factLine(contextLine) }
                if !identityLine.isEmpty { factLine(identityLine) }
                if let directory {
                    Text(directory).sidebarDetail().lineLimit(large ? nil : 1).truncationMode(.middle)
                }
                if let reason {
                    Text("Family: \(AgentOverview.title(reason)) — \((familyState ?? AgentOverviewState(terminal: reason)).title)")
                        .sidebarDetail().lineLimit(large ? nil : 2)
                }
                if preferences.fields.contains(.progress), let progress = terminal.status?.progress,
                   state == .working {
                    ProgressView(value: Double(min(max(progress, 0), 100)), total: 100)
                        .tint(.blue).scaleEffect(y: 0.6).padding(.top, 2)
                        .accessibilityLabel("Progress")
                        .accessibilityValue(terminal.status?.msg ?? "\(min(max(progress, 0), 100)) percent")
                }
                if large { familyControl }
            }
        } trailing: {
            // The end of a row has room to spare next to its lines: the family's control needs no
            // line of its own there.
            if !large {
                VStack(alignment: .trailing, spacing: 0) {
                    statusButton
                    familyControl
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(terminal.address)
    }

    /// At accessibility sizes a column at the row's end would take the text's width: what's there
    /// moves under the title.
    private var large: Bool { typeSize.isAccessibilitySize }

    /// The time and the dot, which explain themselves when tapped.
    private var statusButton: some View {
        Button { explaining = true } label: {
            HStack(spacing: 6) {
                if preferences.fields.contains(.time), let since = terminal.statusSince {
                    TimelineView(.periodic(from: .now, by: 30)) { date in
                        Text(Terminal.shortAge(since, now: date.date))
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.rowSecondary)
                    }
                }
                StatusDot(state: state.statusWord)
            }
            .padding(.top, large ? 0 : SidebarMetrics.titleLineInset)
            .frame(minWidth: SidebarMetrics.touchTarget, minHeight: SidebarMetrics.touchTarget,
                   alignment: large ? .leading : .topTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.rowPrimary)
        .accessibilityLabel(state.title)
        .popover(isPresented: $explaining) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.explanation)
                if let since = terminal.statusSince {
                    Text("Since \(since.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                }
            }
            .font(.callout).padding().presentationCompactAdaptation(.popover)
        }
    }

    /// Wraps at the separators: a hyphen inside a name like claude-code doesn't break. Not at
    /// accessibility sizes, where such a name may not fit a line and has to break somewhere.
    private func factLine(_ facts: [String]) -> some View {
        let text = facts.joined(separator: Terminal.detailSeparator)
        return Text(large ? text : text.replacingOccurrences(of: "-", with: "\u{2011}"))
            .sidebarDetail()
            .accessibilityLabel(text)
    }

    @ViewBuilder private var familyControl: some View {
        if let expanded, childCount > 0 {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("\(childCount) \(childCount == 1 ? "child" : "children")")
                        .font(.caption)
                        .fixedSize()
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        // Room for the wider of the two chevrons, whatever the text size.
                        .frame(minWidth: 12)
                }
                .foregroundStyle(Color.rowPrimary)
                .frame(minHeight: SidebarMetrics.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(expanded.wrappedValue ? "Collapse" : "Expand") children of \(AgentOverview.title(terminal))")
            .accessibilityIdentifier("children-\(terminal.address)")
        }
    }

    private func enabled(_ field: AgentOverviewField, _ value: String?) -> String? {
        guard preferences.fields.contains(field),
              let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private var message: String? { enabled(.message, terminal.status?.msg) }

    private var directory: String? {
        guard context.directory != parent?.directory else { return nil }
        return enabled(.directory, context.directory.map { Terminal.abbreviate($0) })
    }

    /// Where it works; what its parent right above says isn't repeated. A space usually is the
    /// project: once is enough.
    private var contextLine: [String] {
        var parts: [String] = []
        let values: [(AgentOverviewField, String?)] = [
            (.space, space == parent?.project ? nil : space),
            (.project, context.project == parent?.project ? nil : context.project),
            (.branch, context.branch == parent?.branch ? nil : context.branch),
        ]
        for case let part? in values.map({ enabled($0, $1) }) where !parts.contains(part) { parts.append(part) }
        return parts
    }

    /// Who runs it, which stays on a child too.
    private var identityLine: [String] {
        let values: [(AgentOverviewField, String?)] = [
            (.name, terminal.status?.title?.isEmpty == false ? terminal.nameInSpace : nil),
            (.agent, context.agent), (.account, context.account),
        ]
        let parts = values.compactMap { enabled($0, $1) }
        // The status remains readable even when every optional field is hidden.
        if parts.isEmpty, contextLine.isEmpty, message == nil, directory == nil, parent == nil { return [state.title] }
        return parts
    }
}

/// Only bundled original assets are used; anything else gets a neutral system symbol. All of them
/// share one tile, so the list keeps a calm column whichever programs are running.
struct AgentProviderIcon: View {
    let terminal: Terminal
    var neutralSymbol = "sparkles"

    private var provider: String {
        let raw = TerminalContext(terminal: terminal).agent ?? terminal.foreground?.name ?? terminal.argv.first ?? ""
        return URL(fileURLWithPath: raw).lastPathComponent.lowercased()
    }

    private var asset: String? {
        switch provider {
        case "claude", "claude-code": "AgentIcon-Claude"
        case "codex": "AgentIcon-Codex"
        case "grok": "AgentIcon-Grok"
        case "gemini": "AgentIcon-Gemini"
        default: nil
        }
    }

    private static let shape = RoundedRectangle(cornerRadius: SidebarMetrics.iconRadius, style: .continuous)

    var body: some View {
        ZStack {
            Self.shape.fill(Color.rowFill)
            if let asset, let image = UIImage(named: asset) {
                Image(uiImage: image)
                    .renderingMode(asset == "AgentIcon-Grok" ? .template : .original)
                    .resizable().scaledToFit().foregroundStyle(Color.rowPrimary)
                    // Codex's original is a tile itself; the others are marks to place on one.
                    .padding(asset == "AgentIcon-Codex" ? 0 : 4)
            } else {
                // A fixed size like the tile's: at large text it would outgrow it.
                Image(systemName: neutralSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.rowSecondary)
            }
            Self.shape.strokeBorder(Color.rowFill, lineWidth: 1)
        }
        .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
        .clipShape(Self.shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset == nil && neutralSymbol == "terminal" ? "Terminal" : provider.isEmpty ? "Agent" : provider)
    }
}

extension AgentOverviewState {
    var title: String { AgentState(rawValue: rawValue)?.title ?? "Unknown" }
    var explanation: String {
        AgentState(rawValue: rawValue)?.explanation ?? "Unknown: this agent has not reported a recognized status."
    }
    var statusWord: String? { AgentState(rawValue: rawValue)?.statusWord }
}

extension AgentOverviewMode {
    var title: String { self == .individual ? "Individual" : "Nested" }
}

extension AgentOverviewSort {
    var title: String {
        switch self {
        case .lastStateChange: "Last state change"
        case .longestWaiting: "Longest waiting"
        case .title: "Title"
        }
    }
}

extension AgentOverviewField {
    var title: String {
        switch self {
        case .icon: "Agent icon"
        case .space: "Space"
        case .name: "Name"
        case .message: "Status message"
        case .time: "Time"
        case .progress: "Progress"
        case .branch: "Branch"
        case .project: "Project"
        case .directory: "Directory"
        case .agent: "Agent / provider"
        case .account: "Account"
        }
    }
}
