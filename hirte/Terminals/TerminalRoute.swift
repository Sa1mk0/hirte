import Foundation
import HerdrKit

/// A terminal to open once its machine is connected: from a tapped Live Activity or notification.
/// Unknown machines are dropped before one is made; a terminal that's gone leaves the person on the
/// machine's list, without an error.
struct TerminalRoute: Equatable {
    let hostID: UUID
    let address: String
    /// The terminal's identity, when known; nil or 0 matches by address only.
    let createdMs: UInt64?
    /// A follow's: only a turn at or after it is still the same task.
    let startTurn: UInt64?
    /// Each tap is a route of its own, also to the terminal already open.
    private let tap = UUID()

    init(hostID: UUID, address: String, createdMs: UInt64?, startTurn: UInt64? = nil) {
        self.hostID = hostID
        self.address = address
        self.createdMs = createdMs
        self.startTurn = startTurn
    }

    init(_ task: FollowTask) {
        self.init(hostID: task.hostID, address: task.address, createdMs: task.createdMs, startTurn: task.startTurn)
    }

    init(_ route: PushRoute) {
        self.init(hostID: route.hostID, address: route.address, createdMs: route.createdMs)
    }

    /// The terminal to select on `hostID`'s connected machine, or nil when it's gone or another one
    /// took its address. Either way the route is done.
    func destination(in terminals: [Terminal]) -> String? {
        guard let terminal = terminals.first(where: { $0.address == address }) else { return nil }
        if let createdMs, createdMs != 0, terminal.createdMs != createdMs { return nil }
        if let startTurn {
            guard let turn = terminal.turn, turn >= startTurn else { return nil }
        }
        return terminal.address
    }
}
