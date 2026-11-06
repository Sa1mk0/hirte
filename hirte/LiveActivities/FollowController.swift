import Foundation
import HerdrKit
import Observation
import SwiftUI
import UIKit

/// One explicit follow across all windows. No remote identity is put in ActivityKit or the URL.
@MainActor @Observable
final class FollowController {
    static let shared = FollowController()
    static let enabledKey = "liveActivity.enabled"
    static let titleKey = "liveActivity.showTitle"

    private(set) var selection: FollowTask?
    private(set) var lastState: AgentActivityAttributes.ContentState?
    private(set) var errorMessage: String?
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled { stop() }
        }
    }
    var showTitle: Bool {
        didSet {
            defaults.set(showTitle, forKey: Self.titleKey)
            // Removing permission must remove even an already-ended title from the Lock Screen.
            stop()
        }
    }

    private let defaults: UserDefaults
    private let driver: any LiveActivityDriver
    private weak var source: HostSession?
    private var completed: FollowTask?
    private var completedPhase: AgentActivityAttributes.ContentState.Phase?
    private var activeWindows: Set<UUID> = []
    private var routes: [UUID: FollowTask] = [:]
    private var operation: Task<Void, Never>?
    private var prepared = false
    private var observedTurn: UInt64?
    private var needsReconciliation = false

    init(defaults: UserDefaults = .standard, driver: (any LiveActivityDriver)? = nil) {
        self.defaults = defaults
        self.driver = driver ?? ActivityKitDriver()
        enabled = defaults.bool(forKey: Self.enabledKey)
        showTitle = defaults.bool(forKey: Self.titleKey)
    }

    var isAvailable: Bool { driver.isAvailable }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        enqueue { await self.driver.removeAll() }
    }

    func window(_ id: UUID, phase: ScenePhase) {
        prepare()
        if phase == .active { activeWindows.insert(id) } else { activeWindows.remove(id) }
        if activeWindows.isEmpty { markLastKnown() }
    }

    func removeWindow(_ id: UUID) {
        activeWindows.remove(id)
        if activeWindows.isEmpty { markLastKnown() }
    }

    func follows(hostID: UUID, address: String) -> Bool {
        selection?.hostID == hostID && selection?.address == address
    }

    func start(session: HostSession, terminal: Terminal) {
        prepare()
        guard enabled, isAvailable, !activeWindows.isEmpty,
              session.state == .connected, FollowTask.canFollow(terminal) else { return }
        stop()
        let task = FollowTask(hostID: session.host.id, terminal: terminal, now: .now)
        guard case .update(let state) = task.reduce(
            hostID: session.host.id, terminal: terminal, showTitle: showTitle, now: .now) else { return }
        selection = task
        source = session
        observedTurn = terminal.turn
        needsReconciliation = false
        lastState = state
        errorMessage = nil
        routes = routes.filter { Date.now.timeIntervalSince($0.value.startedAt) < 8.5 * 60 * 60 }
        routes[task.followID] = task
        let dismissed: @MainActor () -> Void = { [weak self] in
            guard self?.selection?.followID == task.followID else { return }
            self?.stop()
        }
        enqueue {
            guard self.selection?.followID == task.followID else { return }
            guard self.enabled, !self.activeWindows.isEmpty else {
                self.selection = nil
                self.lastState = nil
                self.source = nil
                return
            }
            await self.driver.removeAll()
            do {
                try self.driver.start(id: task.followID, state: state)
                self.driver.observeDismissal(dismissed)
            } catch {
                self.selection = nil
                self.lastState = nil
                self.source = nil
                self.errorMessage = "The Lock Screen activity could not start. Check Live Activities in iOS Settings and try again."
            }
        }
    }

    func dismissError() { errorMessage = nil }

    func stop() {
        completed = nil
        completedPhase = nil
        selection = nil
        lastState = nil
        source = nil
        // Also removes completed activities, e.g. when opting out or replacing the follow.
        enqueue { await self.driver.removeAll() }
    }

    func terminalOpened(hostID: UUID, address: String) {
        if follows(hostID: hostID, address: address) || (completed?.hostID == hostID && completed?.address == address) {
            stop()
        }
    }

    func hostsChanged(_ ids: Set<UUID>) {
        routes = routes.filter { ids.contains($0.value.hostID) }
        if let task = selection ?? completed, !ids.contains(task.hostID) { stop() }
    }

    func sessionRemoved(_ session: HostSession) {
        if source === session { stop() }
    }

    func disconnected(_ session: HostSession) {
        if source === session { markLastKnown() }
    }

    func received(_ session: HostSession, message: EventMessage? = nil) {
        guard source === session else { return }
        if let completed {
            if case .event(let event) = message, event.terminal == completed.address {
                switch event.change {
                case .restarted, .removed: stop(); return
                default: break
                }
            }
            guard let terminal = session.terminal(completed.address),
                  completed.matches(hostID: session.host.id, terminal: terminal) else { stop(); return }
            let isRead: Bool
            if let turn = terminal.turn, let seen = terminal.seenTurn { isRead = seen >= turn } else { isRead = false }
            if case .event(let event) = message, event.terminal == completed.address,
               case .labels = event.change, isRead {
                stop()
                return
            }
            let errorRead = completedPhase == .error && terminal.turn != completed.startTurn && isRead
            let doneRead = completedPhase == .done && terminal.agentState == .idle
            let newTask = completedPhase != .ended && terminal.agentState == .working
            if doneRead || newTask || errorRead { stop() }
            return
        }
        guard let task = selection else { return }
        guard !activeWindows.isEmpty, session.state == .connected else { markLastKnown(); return }
        let terminal = session.terminal(task.address)
        if needsReconciliation, let terminal, !FollowTask.canResume(terminal, observedTurn: observedTurn) {
            stop()
            return
        }
        needsReconciliation = false
        observedTurn = terminal?.turn
        if case .event(let event) = message, event.terminal == task.address {
            if FollowTask.awaitsTurn(after: event.change, previous: lastState?.phase, terminal: session.terminal(task.address)) {
                return
            }
            switch event.change {
            case .restarted, .removed:
                stop()
                return
            case .lost:
                finish(lastState.map {
                    var state = $0
                    state.phase = .ended
                    state.progress = nil
                    state.asOf = .now
                    return state
                }, seconds: 900)
                return
            default: break
            }
        }
        switch task.reduce(hostID: session.host.id, terminal: session.terminal(task.address), showTitle: showTitle, now: .now) {
        case .update(let state):
            lastState = state
            enqueue {
                guard self.selection?.followID == task.followID else { return }
                await self.driver.update(state)
            }
        case .end(let state, let seconds): finish(state, seconds: seconds)
        }
    }

    private func finish(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) {
        completed = seconds > 0 ? selection : nil
        completedPhase = state?.phase
        selection = nil
        lastState = nil
        if seconds <= 0 { source = nil }
        enqueue { await self.driver.end(state, seconds: seconds) }
    }

    private func markLastKnown() {
        guard var state = lastState, let id = selection?.followID else { return }
        state.isLastKnown = true
        needsReconciliation = true
        lastState = state
        // Keep a little time for ActivityKit to accept the final snapshot before iOS suspends us.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Mark activity last known")
        enqueue {
            if self.selection?.followID == id { await self.driver.update(state) }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    func route(for url: URL) -> FollowTask? {
        guard let id = AgentActivityAttributes.followID(from: url), let task = routes[id],
              Date.now.timeIntervalSince(task.startedAt) < 8.5 * 60 * 60 else { return nil }
        return task
    }

    /// Serialized platform calls keep stop/replacement/background updates in their original order.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task {
            await previous?.value
            await work()
        }
    }

    func waitForUpdates() async { await operation?.value }
}
