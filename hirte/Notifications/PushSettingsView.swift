import SwiftUI
import UIKit

/// Embedded by the settings owner, next to the Live Activity. Off until the person opts in.
struct PushSettingsView: View {
    @Bindable private var push = PushController.shared

    var body: some View {
        Section {
            Toggle("Notifications (Beta)", isOn: $push.enabled)
            if push.enabled, push.authorization == .denied {
                Text("Notifications are off for Hirte in iOS Settings.")
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open iOS Settings", destination: settings)
                }
            }
            if let error = push.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get told when an agent waits for your decision, also while Hirte is closed. Hirte leaves its notification address in ~/.config/hirte/push on each machine you connect to, for a sender there to use; it goes nowhere else, and is removed when you turn this off. Helpers started by an agent don't notify.")
        }
    }
}
