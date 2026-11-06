import HerdrKit
import SwiftUI

struct AgentOverviewSettingsView: View {
    @AppStorage(AgentOverviewPreferences.storageKey) private var stored = ""

    private var preferences: AgentOverviewPreferences { .init(rawValue: stored) }

    var body: some View {
        Form {
            Section("Preview") {
                if let terminal = Self.previewTerminal {
                    AgentOverviewRowView(
                        terminal: terminal, state: .working,
                        context: TerminalContext(terminal: terminal, project: "sample-project"),
                        preferences: preferences, space: "sample-project")
                }
            }
            Section {
                LabeledContent("Title and status", value: "Always shown")
                ForEach(AgentOverviewField.allCases, id: \.self) { field in
                    Toggle(field.title, isOn: Binding(
                        get: { preferences.fields.contains(field) },
                        set: { enabled in
                            var updated = preferences
                            if enabled { updated.fields.insert(field) } else { updated.fields.remove(field) }
                            stored = updated.rawValue
                        }))
                }
            } header: {
                Text("Row fields")
            } footer: {
                Text("Missing values are hidden. Branch and account appear when the host provides them.")
            }
            Section {
                Picker("Agent view", selection: binding(\.mode)) {
                    ForEach(AgentOverviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Sort by", selection: binding(\.sort)) {
                    ForEach(AgentOverviewSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Button("Reset to Defaults") { stored = AgentOverviewPreferences().rawValue }
                .disabled(preferences == AgentOverviewPreferences())
        }
        .navigationTitle("Agent Overview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentOverviewPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { value in
            var updated = preferences
            updated[keyPath: keyPath] = value
            stored = updated.rawValue
        })
    }

    private static var previewTerminal: Terminal? {
        // A generic fixture uses the same row and context path as the live overview.
        let json = #"{"address":"preview","argv":["agent"],"cwd":"/workspace/sample-project","state":"live","name":"agent","status":{"state":"working","app":"agent","title":"Improve the mobile overview","msg":"12 of 20 files","progress":60},"labels":{"context.project":"sample-project","context.agent":"agent","context.account":"sample-account","context.branch":"feature/mobile","context.directory":"/workspace/sample-project","context.created_ms":"1"},"cols":80,"rows":24,"created_ms":1}"#
        return try? JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }
}
