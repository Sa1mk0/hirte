import ActivityKit
import Foundation

/// A narrow platform boundary lets lifecycle tests run without requesting a system activity.
@MainActor
protocol LiveActivityDriver: AnyObject {
    var isAvailable: Bool { get }
    func start(id: UUID, state: AgentActivityAttributes.ContentState) throws
    func update(_ state: AgentActivityAttributes.ContentState) async
    func end(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) async
    func removeAll() async
    func observeDismissal(_ dismissed: @escaping @MainActor () -> Void)
}

@MainActor
final class ActivityKitDriver: LiveActivityDriver {
    private var activity: Activity<AgentActivityAttributes>?
    private var observer: Task<Void, Never>?

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(id: UUID, state: AgentActivityAttributes.ContentState) throws {
        activity = try Activity.request(
            attributes: AgentActivityAttributes(followID: id),
            content: content(state), pushType: nil)
    }

    func update(_ state: AgentActivityAttributes.ContentState) async {
        await activity?.update(content(state))
    }

    func end(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) async {
        observer?.cancel()
        observer = nil
        // Retain the ended handle until replacement/opt-out so its remaining UI can be removed.
        await activity?.end(state.map(content), dismissalPolicy: seconds > 0 ? .after(.now + seconds) : .immediate)
    }

    func removeAll() async {
        observer?.cancel()
        observer = nil
        let known = activity
        activity = nil
        var activities = Activity<AgentActivityAttributes>.activities
        if let known, !activities.contains(where: { $0.id == known.id }) { activities.append(known) }
        for old in activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
    }

    func observeDismissal(_ dismissed: @escaping @MainActor () -> Void) {
        observer?.cancel()
        guard let activity else { return }
        observer = Task {
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    dismissed()
                    return
                }
            }
        }
    }

    private func content(_ state: AgentActivityAttributes.ContentState) -> ActivityContent<AgentActivityAttributes.ContentState> {
        // A short lease also covers a crash or suspension before the explicit stale update.
        ActivityContent(state: state, staleDate: state.isLastKnown ? .now : state.asOf + 45)
    }
}
