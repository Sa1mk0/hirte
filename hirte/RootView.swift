import HerdrKit
import SwiftUI

/// Two columns when unfolded (terminals | terminal), a stack when folded. The machine is picked
/// from the sidebar's title, so it doesn't need a column of its own.
struct RootView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.scenePhase) private var scenePhase
    /// The window's: inside the split view's sidebar column it always reads compact.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sessions = SessionStore()
    @State private var windowID = UUID()
    /// A terminal to open once its machine is connected (a tapped Live Activity or notification).
    @State private var pendingRoute: TerminalRoute?
    private let follow = FollowController.shared
    private let push = PushController.shared
    /// The machine shown in the sidebar, remembered across launches.
    @AppStorage("selectedHost") private var storedHost = ""
    @State private var selectedTerminal: String?
    @State private var columns = NavigationSplitViewVisibility.all

    private var selectedHost: Binding<Host.ID?> {
        Binding(
            get: {
                let ids = hosts.hosts.map(\.id)
                if let stored = UUID(uuidString: storedHost), ids.contains(stored) { return stored }
                return ids.first
            },
            set: { storedHost = $0?.uuidString ?? "" })
    }

    private var pendingSessionConnected: Bool {
        guard let route = pendingRoute else { return false }
        return sessions.existing(route.hostID)?.state == .connected
    }

    private func openRoute() {
        guard let route = pendingRoute,
              let session = sessions.existing(route.hostID), session.state == .connected else { return }
        pendingRoute = nil
        // Gone, or another terminal took its address: the machine's list is where it leads.
        guard let address = route.destination(in: session.terminals) else { return }
        selectedTerminal = address
    }

    /// Shows the route's machine and connects it; its terminal opens once the list is known.
    private func follow(_ route: TerminalRoute) {
        guard let host = hosts.hosts.first(where: { $0.id == route.hostID }) else { return }
        pendingRoute = route
        selectedHost.wrappedValue = host.id
        sessions.session(for: host).start(keys: keys)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(sessions: sessions, selectedHost: selectedHost, selectedTerminal: $selectedTerminal,
                        besideDetail: sizeClass == .regular)
                .modifier(PadSidebarWidth())
                // The detail column runs under the sidebar: its default material would take on the
                // colors of what's selected.
                .containerBackground(Color.sidebarBackground, for: .navigation)
        } detail: {
            if let host = hosts.hosts.first(where: { $0.id == selectedHost.wrappedValue }),
               let address = selectedTerminal {
                TerminalScreenView(
                    session: sessions.session(for: host), address: address,
                    expanded: Binding(
                        get: { columns == .detailOnly },
                        set: { columns = $0 ? .detailOnly : .all }))
                    .id("\(host.id)/\(address)")
            } else {
                ContentUnavailableView(
                    "No terminal selected", systemImage: "terminal",
                    description: Text("Pick a terminal to see what it is doing."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onDisappear { follow.removeWindow(windowID) }
        // A follow that outlived the last run needs its machine connected to keep updating.
        .task {
            follow.hostsChanged(Set(hosts.hosts.map(\.id)))
            guard let id = follow.selection?.hostID,
                  let host = hosts.hosts.first(where: { $0.id == id }) else { return }
            sessions.session(for: host).start(keys: keys)
        }
        .onOpenURL { url in
            if let task = follow.route(for: url) { follow(TerminalRoute(task)) }
        }
        // A tapped notification, from cold too: the delegate keeps it until a window takes it.
        .onChange(of: push.pendingRoute, initial: true) {
            if let route = push.takeRoute() { follow(TerminalRoute(route)) }
        }
        .onChange(of: selectedHost.wrappedValue) {
            // Reset before a connected route selects the new host's terminal.
            selectedTerminal = nil
        }
        .onChange(of: pendingSessionConnected) { openRoute() }
        .task(id: pendingRoute) {
            guard pendingRoute != nil else { return }
            // Let the host selection settle before opening its detail.
            await Task.yield()
            openRoute()
        }
        #if DEBUG
        // `-hirte.demo YES` (videos, UI tests on a device with real machines): open the demo machine.
        .task {
            if UserDefaults.standard.bool(forKey: "hirte.demo") { storedHost = hosts.addDemo().id.uuidString }
        }
        #endif
        .onChange(of: hosts.hosts) { _, current in
            follow.hostsChanged(Set(current.map(\.id)))
            // Edited or deleted machines get a fresh session.
            for host in current where sessions.existing(host.id).map({ $0.host != host }) ?? false {
                sessions.remove(host.id)
            }
            for id in sessions.ids where !current.contains(where: { $0.id == id }) {
                sessions.remove(id)
            }
            // After the removals: a removed machine's token file goes with its session, while
            // the machine is still known to have one.
            push.hostsChanged(Set(current.map(\.id)))
        }
        .onChange(of: hosts.passwordRevisions) { old, new in
            // A new password: start over with it (Host doesn't hold it, so the check above misses it).
            for (id, revision) in new where old[id] != revision { sessions.remove(id) }
        }
        // Initial, not a `.task`: one runs later with the phase of its view's body, and could
        // overwrite a newer `.active` with it. Starting a follow needs an active window.
        .onChange(of: scenePhase, initial: true) { _, phase in
            follow.window(windowID, phase: phase)
            switch phase {
            case .background: sessions.pauseAll()
            case .active:
                sessions.resumePaused(keys: keys)
                push.windowActive()
            default: break
            }
        }
    }
}

/// An iPad has room for the rows' titles in the list column; elsewhere (the unfolded Duo) the
/// column keeps the system's width.
private struct PadSidebarWidth: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
        } else {
            content
        }
    }
}
