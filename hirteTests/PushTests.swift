import Foundation
@testable import HerdrKit
import Testing
import UIKit
import UserNotifications
@testable import hirte

@MainActor
private final class FakeRegistrar: PushRegistrar {
    var status: UNAuthorizationStatus = .notDetermined
    var grants = true
    var registered = 0
    var unregistered = 0

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        status = grants ? .authorized : .denied
        return grants
    }

    func register() { registered += 1 }
    func unregister() { unregistered += 1 }
}

@MainActor
struct PushControllerTests {
    private let hostID = UUID()
    private let token = Data([0xde, 0xad, 0xbe, 0xef, 0x01])

    private func defaults() throws -> UserDefaults {
        let suite = "hirteTests.push.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func machine() -> HostSession {
        HostSession(host: Host(id: hostID, name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel")),
                    knownHosts: InMemoryKnownHosts())
    }

    /// The controller's platform calls run in tasks of their own: give them a moment.
    private func settle(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func installationIDIsMadeOnceAndKept() throws {
        let defaults = try defaults()
        let first = PushController(defaults: defaults, registrar: FakeRegistrar())
        #expect(RemotePush.isInstallationID(first.installationID))
        #expect(UUID(uuidString: first.installationID) != nil)
        #expect(PushController(defaults: defaults, registrar: FakeRegistrar()).installationID == first.installationID)
        // A damaged value never reaches a command: a new id replaces it.
        defaults.set("../X", forKey: PushController.installationKey)
        let replaced = PushController(defaults: defaults, registrar: FakeRegistrar())
        #expect(replaced.installationID != "../X")
        #expect(RemotePush.isInstallationID(replaced.installationID))
        #expect(defaults.string(forKey: PushController.installationKey) == replaced.installationID)
    }

    @Test func fileActionOnConnect() {
        typealias Action = PushController.FileAction
        #expect(PushController.actionOnConnect(enabled: true, hasToken: true, isDemo: false, wasWritten: false) == .write)
        #expect(PushController.actionOnConnect(enabled: true, hasToken: true, isDemo: false, wasWritten: true) == .write)
        // Waiting for this run's token: the last run's file stays until it arrives.
        #expect(PushController.actionOnConnect(enabled: true, hasToken: false, isDemo: false, wasWritten: true) == .nothing)
        #expect(PushController.actionOnConnect(enabled: true, hasToken: false, isDemo: false, wasWritten: false) == .nothing)
        // Turned off while this machine was away: its file goes now.
        #expect(PushController.actionOnConnect(enabled: false, hasToken: false, isDemo: false, wasWritten: true) == .delete)
        #expect(PushController.actionOnConnect(enabled: false, hasToken: false, isDemo: false, wasWritten: false) == .nothing)
        // The demo never gets a file, whatever the setting.
        #expect(PushController.actionOnConnect(enabled: true, hasToken: true, isDemo: true, wasWritten: false) == .nothing)
        #expect(PushController.actionOnConnect(enabled: false, hasToken: true, isDemo: true, wasWritten: true) == .nothing)
    }

    @Test func turningOnAsksIOSAndRegisters() async throws {
        let registrar = FakeRegistrar()
        let push = PushController(defaults: try defaults(), registrar: registrar)
        #expect(!push.enabled, "off by default")
        push.enabled = true
        await settle { registrar.registered == 1 }
        #expect(push.authorization == .authorized)
        // Denied: the settings show it; the registration still happens, for when it's allowed later.
        let denied = FakeRegistrar()
        denied.grants = false
        let refused = PushController(defaults: try defaults(), registrar: denied)
        refused.enabled = true
        await settle { denied.registered == 1 }
        #expect(refused.authorization == .denied)
        // A launch with it on registers again (the token can change), off never asks.
        let again = PushController(defaults: try defaults(), registrar: registrar)
        again.launched()
        #expect(registrar.registered == 1)
        again.enabled = true
        await settle { registrar.registered == 2 }
        let relaunch = PushController(defaults: try defaults(), registrar: registrar)
        relaunch.enabled = true
        await settle { registrar.registered == 3 }
        relaunch.launched()
        await settle { registrar.registered == 4 }
    }

    @Test func tokenGoesToConnectedMachinesButNeverToTheDemo() async throws {
        let defaults = try defaults()
        defaults.set(true, forKey: PushController.enabledKey)
        let registrar = FakeRegistrar()
        let push = PushController(defaults: defaults, registrar: registrar)
        let demo = HostSession(host: .makeDemo())
        let machine = machine()
        push.connected(demo)
        push.connected(machine)
        #expect(push.file(for: machine) == nil, "nothing to write before the token")
        push.tokenReceived(token)
        #expect(push.token == "deadbeef01")
        let file = try #require(push.file(for: machine))
        #expect(file.token == "deadbeef01")
        #expect(file.environment == "development")
        #expect(file.bundleID == Bundle.main.bundleIdentifier)
        #expect(file.hostID == hostID)
        #expect(file.device == UIDevice.current.model)
        #expect(file.v == 1)
        #expect(abs(Double(file.updatedMs) / 1000 - Date.now.timeIntervalSince1970) < 5)
        await push.waitForFiles()
        // The demo has no machine behind it; the real one is remembered as having the file (its
        // write over the line fails here, which is the best effort the contract asks for).
        #expect(defaults.stringArray(forKey: PushController.writtenKey) == [hostID.uuidString])
        // The same token again changes nothing; off removes the file and the registration.
        push.tokenReceived(token)
        push.enabled = false
        await push.waitForFiles()
        #expect(registrar.unregistered == 1)
        #expect(push.token == nil)
        #expect(defaults.stringArray(forKey: PushController.writtenKey) == [])
        // A token arriving after turning off is ignored.
        push.tokenReceived(token)
        #expect(push.token == nil)
    }

    @Test func filesOfMachinesGoneAreForgotten() async throws {
        let defaults = try defaults()
        defaults.set(true, forKey: PushController.enabledKey)
        let push = PushController(defaults: defaults, registrar: FakeRegistrar())
        let machine = machine()
        push.tokenReceived(token)
        push.connected(machine)
        await push.waitForFiles()
        #expect(defaults.stringArray(forKey: PushController.writtenKey) == [hostID.uuidString])
        // Remembered across runs: the file goes when the machine next connects with it off.
        let later = PushController(defaults: defaults, registrar: FakeRegistrar())
        later.hostsChanged([hostID, UUID()])
        #expect(defaults.stringArray(forKey: PushController.writtenKey) == [hostID.uuidString])
        later.sessionRemoved(machine)
        #expect(defaults.stringArray(forKey: PushController.writtenKey) == [])
        push.connected(machine)
        await push.waitForFiles()
        push.hostsChanged([])
        #expect(defaults.stringArray(forKey: PushController.writtenKey) == [])
    }

    @Test func foregroundBannersSkipTheTerminalOnScreen() throws {
        let push = PushController(defaults: try defaults(), registrar: FakeRegistrar())
        let machine = machine()
        push.connected(machine)
        let route = PushRoute(hostID: hostID, address: "t3", createdMs: nil)
        #expect(push.presents(route), "not on screen yet")
        machine.startLooking(at: "t3")
        #expect(!push.presents(route))
        #expect(push.presents(PushRoute(hostID: hostID, address: "t4", createdMs: nil)))
        #expect(push.presents(PushRoute(hostID: UUID(), address: "t3", createdMs: nil)), "another machine's t3")
        #expect(push.presents(nil), "a notification without a route shows")
        machine.stopLooking(at: "t3")
        #expect(push.presents(route))
        // Seen twice at once (the screen and a peek): on screen until both are gone.
        machine.startLooking(at: "t3")
        machine.startLooking(at: "t3")
        machine.stopLooking(at: "t3")
        #expect(!push.presents(route))
        machine.stopLooking(at: "t3")
        #expect(push.presents(route))
        push.disconnected(machine)
        machine.startLooking(at: "t3")
        #expect(push.presents(route), "a machine that lost its line can't be showing it")
    }

    @Test func aTapIsTakenOnce() throws {
        let push = PushController(defaults: try defaults(), registrar: FakeRegistrar())
        #expect(push.takeRoute() == nil)
        let route = PushRoute(hostID: hostID, address: "t3", createdMs: 7)
        push.open(route)
        #expect(push.pendingRoute == route)
        #expect(push.takeRoute() == route)
        #expect(push.pendingRoute == nil)
        #expect(push.takeRoute() == nil)
    }
}

@MainActor
struct TerminalRouteTests {
    private let hostID = UUID()

    private func terminal(_ address: String, created: UInt64, turn: UInt64? = nil) throws -> Terminal {
        var json = #"{"address":"\#(address)","created_ms":\#(created),"state":"live""#
        if let turn { json += #","turn":\#(turn)"# }
        return try JSONDecoder().decode(Terminal.self, from: Data((json + "}").utf8))
    }

    @Test func aNotificationLeadsToItsTerminalWhileItIsTheSameOne() throws {
        let terminals = [try terminal("t1", created: 100), try terminal("t3", created: 300)]
        let route = TerminalRoute(PushRoute(hostID: hostID, address: "t3", createdMs: 300))
        #expect(route.hostID == hostID)
        #expect(route.destination(in: terminals) == "t3")
        #expect(TerminalRoute(PushRoute(hostID: hostID, address: "t3", createdMs: nil)).destination(in: terminals) == "t3")
        #expect(TerminalRoute(PushRoute(hostID: hostID, address: "t3", createdMs: 0)).destination(in: terminals) == "t3")
        // Gone, or replaced by a new terminal with the same address: stay on the list.
        #expect(TerminalRoute(PushRoute(hostID: hostID, address: "t9", createdMs: nil)).destination(in: terminals) == nil)
        #expect(TerminalRoute(PushRoute(hostID: hostID, address: "t3", createdMs: 301)).destination(in: terminals) == nil)
        #expect(route.destination(in: []) == nil)
    }

    @Test func aFollowKeepsItsTurnCheck() throws {
        let original = try terminal("t3", created: 300, turn: 4)
        let route = TerminalRoute(FollowTask(hostID: hostID, terminal: original, now: .now))
        #expect(route.destination(in: [original]) == "t3")
        #expect(route.destination(in: [try terminal("t3", created: 300, turn: 5)]) == "t3")
        #expect(route.destination(in: [try terminal("t3", created: 300, turn: 3)]) == nil)
        #expect(route.destination(in: [try terminal("t3", created: 300)]) == nil, "a core without turns can't confirm it")
        #expect(route.destination(in: [try terminal("t3", created: 301, turn: 4)]) == nil)
    }

    @Test func everyTapIsItsOwnRoute() {
        let push = PushRoute(hostID: hostID, address: "t3", createdMs: 300)
        #expect(TerminalRoute(push) != TerminalRoute(push), "so tapping twice opens the terminal again")
    }
}
