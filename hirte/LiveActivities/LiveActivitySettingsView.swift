import HerdrKit
import SwiftUI

/// Embedded by the settings owner. Everything is off until the person opts in.
struct LiveActivitySettingsView: View {
    @Bindable private var follow = FollowController.shared

    var body: some View {
        Section {
            Toggle("Follow on Lock Screen (Beta)", isOn: $follow.enabled)
            if follow.enabled {
                Toggle("Show task title", isOn: $follow.showTitle)
                Text("Task titles may contain private information and can also appear on your other Apple devices.")
                    .font(.footnote).foregroundStyle(.secondary)
                if follow.selection != nil {
                    Button("Stop Following", role: .destructive) { follow.stop() }
                }
                if !follow.isAvailable {
                    Text("Allow Live Activities for Hirte in iOS Settings to start following.")
                }
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("Choose one working agent from its terminal. The activity refreshes while Hirte is open and connected. When you leave Hirte or lose the connection, it shows the last known state. Open Hirte to refresh. If the task changed while you were away, choose it again.")
        }
    }
}

struct LiveActivityFollowMenu: View {
    let session: HostSession
    let terminal: HerdrKit.Terminal?
    @Binding var showingSettings: Bool
    @Bindable private var follow = FollowController.shared

    var body: some View {
        let following = follow.follows(hostID: session.host.id, address: terminal?.address ?? "")
        Menu("Lock Screen", systemImage: following ? "lock.rectangle.fill" : "lock.rectangle") {
            LiveActivityFollowActions(session: session, terminal: terminal, showingSettings: $showingSettings)
        }
        .accessibilityValue(following ? "Following" : "")
    }
}

/// What the Lock Screen offers for a terminal: for a menu of their own, or a section of another menu.
/// (As a submenu of one, a status update arriving while it's open could lose the tap that opens it.)
struct LiveActivityFollowActions: View {
    let session: HostSession
    let terminal: HerdrKit.Terminal?
    /// Held outside: inside a menu, this view's own sheet could not present.
    @Binding var showingSettings: Bool
    @Bindable private var follow = FollowController.shared

    var body: some View {
        if follow.follows(hostID: session.host.id, address: terminal?.address ?? "") {
            Button("Stop Following", role: .destructive) { follow.stop() }
        } else if follow.enabled, follow.isAvailable, let terminal, FollowTask.canFollow(terminal) {
            Button("Follow on Lock Screen") { follow.start(session: session, terminal: terminal) }
                .disabled(session.state != .connected)
        }
        Button("Live Activity Settings…") { showingSettings = true }
    }
}

private struct LiveActivityFollowPresentation: ViewModifier {
    @Binding var showingSettings: Bool
    @Bindable private var follow = FollowController.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    Form { LiveActivitySettingsView() }
                        .navigationTitle("Live Activity")
                        .toolbar { Button("Done") { showingSettings = false } }
                }
            }
            .alert("Live Activity", isPresented: Binding(
                get: { follow.errorMessage != nil }, set: { if !$0 { follow.dismissError() } })) {
                    Button("OK") { follow.dismissError() }
            } message: { Text(follow.errorMessage ?? "") }
    }
}

extension View {
    /// What `LiveActivityFollowMenu` opens.
    func liveActivityFollowPresentation(showingSettings: Binding<Bool>) -> some View {
        modifier(LiveActivityFollowPresentation(showingSettings: showingSettings))
    }
}
