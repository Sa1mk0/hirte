import HerdrKit
import SwiftUI

struct AgentOverviewRowView: View {
    let terminal: Terminal
    let state: AgentOverviewState
    let context: TerminalContext
    let preferences: AgentOverviewPreferences
    var space: String?
    var depth = 0
    var reason: Terminal?
    var familyState: AgentOverviewState?
    var childCount = 0
    var expanded: Binding<Bool>?
    @State private var explaining = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(min(depth - 1, 3)) * 12)
                    .accessibilityLabel("Started by its parent")
            }
            if preferences.fields.contains(.icon) { AgentProviderIcon(terminal: terminal) }
            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.headline(inSpace: true)).lineLimit(1)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                }
                if let reason {
                    Text("Family: \(AgentOverview.title(reason)) — \((familyState ?? AgentOverviewState(terminal: reason)).title)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if preferences.fields.contains(.progress), let progress = terminal.status?.progress,
                   state == .working {
                    ProgressView(value: Double(min(max(progress, 0), 100)), total: 100)
                        .tint(.blue).scaleEffect(y: 0.6).padding(.top, 2)
                }
                if let expanded, childCount > 0 {
                    Button {
                        expanded.wrappedValue.toggle()
                    } label: {
                        Label("\(childCount) \(childCount == 1 ? "child" : "children")",
                              systemImage: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(expanded.wrappedValue ? "Collapse" : "Expand") children of \(AgentOverview.title(terminal))")
                    .accessibilityIdentifier("children-\(terminal.address)")
                }
            }
            Spacer(minLength: 2)
            Button { explaining = true } label: {
                HStack(spacing: 6) {
                    if preferences.fields.contains(.time), let since = terminal.statusSince {
                        TimelineView(.periodic(from: .now, by: 30)) { date in
                            Text(Terminal.shortAge(since, now: date.date))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    StatusDot(state: state.statusWord)
                }
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(terminal.address)
    }

    private var details: [String] {
        let fields = preferences.fields
        let values: [(AgentOverviewField, String?)] = [
            (.space, space),
            (.name, terminal.status?.title?.isEmpty == false ? terminal.nameInSpace : nil),
            (.message, terminal.status?.msg),
            (.project, context.project), (.branch, context.branch),
            (.directory, context.directory.map { Terminal.abbreviate($0) }),
            (.agent, context.agent), (.account, context.account),
        ]
        var parts = values.compactMap { field, value -> String? in
            guard fields.contains(field), let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        // The status remains readable even when every optional field is hidden.
        if parts.isEmpty { parts = [state.title] }
        return parts
    }
}

/// Only bundled original assets are used; unknown providers get a neutral system symbol.
struct AgentProviderIcon: View {
    let terminal: Terminal

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

    var body: some View {
        Group {
            if let asset, let image = UIImage(named: asset) {
                Image(uiImage: image)
                    .renderingMode(asset == "AgentIcon-Grok" ? .template : .original)
                    .resizable().scaledToFit().foregroundStyle(.primary)
            } else {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(provider.isEmpty ? "Agent" : provider)
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
