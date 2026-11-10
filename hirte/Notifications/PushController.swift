import Foundation
import HerdrKit
import Observation
import UIKit
import UserNotifications

/// The platform side of registering, so the controller's decisions run in tests without a prompt.
@MainActor
protocol PushRegistrar: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func register()
    func unregister()
}

@MainActor
final class SystemPushRegistrar: PushRegistrar {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { UIApplication.shared.unregisterForRemoteNotifications() }
}

/// Notifications when a main agent needs a decision: the opt-in, the device token, the token files on
/// the machines (the contract: HerdrKit's `Push.swift`) and where a tapped notification leads. The
/// sender runs on the person's machines; the token goes nowhere else. Off until the person opts in.
@MainActor @Observable
final class PushController {
    static let shared = PushController()
    static let enabledKey = "push.enabled"
    static let installationKey = "push.installationID"
    static let writtenKey = "push.writtenHosts"

    /// This install's file name on the machines: random, once per install.
    let installationID: String
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled { register() } else { unregister() }
        }
    }
    /// The person's answer to iOS's permission question, for the settings to show the denied state.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// The APNs device token as hex; nil until iOS hands it over in this run (it is not kept).
    private(set) var token: String?
    private(set) var errorMessage: String?
    /// A tapped notification's terminal, until the root view takes it.
    private(set) var pendingRoute: PushRoute?

    private let defaults: UserDefaults
    private let registrar: any PushRegistrar
    /// Machines with a token file of this install, also from earlier runs: the file goes when the
    /// person turns notifications off, at once when connected, else when the machine next connects.
    private var written: Set<UUID> { didSet { defaults.set(written.map(\.uuidString).sorted(), forKey: Self.writtenKey) } }
    /// The sessions up to each machine: more than one when iPad windows show it (each window's
    /// store connects for itself). The file goes through any of them.
    private(set) var live: [UUID: [HostSession]] = [:]
    private var operation: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, registrar: (any PushRegistrar)? = nil) {
        self.defaults = defaults
        self.registrar = registrar ?? SystemPushRegistrar()
        enabled = defaults.bool(forKey: Self.enabledKey)
        if let stored = defaults.string(forKey: Self.installationKey), RemotePush.isInstallationID(stored) {
            installationID = stored
        } else {
            installationID = UUID().uuidString.lowercased()
            defaults.set(installationID, forKey: Self.installationKey)
        }
        written = Set((defaults.stringArray(forKey: Self.writtenKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// `development` for Debug builds, `production` for TestFlight and the App Store: the build's
    /// `aps-environment` (project setting `HIRTE_APS_ENVIRONMENT`), which decides the APNs server.
    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    // MARK: Registering

    /// At launch: a token can change between runs, so iOS is asked again whenever it's on (and for
    /// permission, if that never happened: iOS answers without a prompt once it was decided).
    func launched() {
        if enabled { register() } else { refreshAuthorization() }
    }

    /// Back on screen, maybe from iOS Settings.
    func windowActive() { refreshAuthorization() }

    private func refreshAuthorization() {
        Task { authorization = await registrar.authorizationStatus() }
    }

    private func register() {
        errorMessage = nil
        Task {
            do {
                // The answer shows as the denied state in the settings; registering is independent
                // of it, and gives the token as soon as the person allows it in iOS Settings.
                _ = try await registrar.requestAuthorization()
            } catch {
                errorMessage = "iOS could not ask for notification permission. (\(error.localizedDescription))"
            }
            authorization = await registrar.authorizationStatus()
            guard enabled else { return }
            registrar.register()
        }
    }

    private func unregister() {
        registrar.unregister()
        token = nil
        errorMessage = nil
        for (hostID, sessions) in live where written.contains(hostID) {
            if let session = sessions.first { delete(on: session) }
        }
    }

    func tokenReceived(_ deviceToken: Data) {
        guard enabled else { return }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard hex != token else { return }
        token = hex
        errorMessage = nil
        for sessions in live.values {
            if let session = sessions.first, !session.host.isDemo { write(to: session) }
        }
    }

    func registrationFailed(_ error: any Error) {
        guard enabled else { return }
        errorMessage = "iOS could not register for notifications. (\(error.localizedDescription))"
    }

    // MARK: Token files

    enum FileAction: Equatable { case write, delete, nothing }

    /// What to do with a machine's token file when it connects. Waiting for the token keeps a file
    /// from an earlier run: the token mostly stays the same, and the new one replaces it on arrival.
    static func actionOnConnect(enabled: Bool, hasToken: Bool, isDemo: Bool, wasWritten: Bool) -> FileAction {
        if isDemo { return .nothing }
        if enabled { return hasToken ? .write : .nothing }
        return wasWritten ? .delete : .nothing
    }

    /// The machine is connected: its file gets this run's token, or goes if notifications are off.
    /// (The demo is known too, for the terminal on screen, but never gets a file.)
    func connected(_ session: HostSession) {
        if !live[session.host.id, default: []].contains(where: { $0 === session }) {
            live[session.host.id, default: []].append(session)
        }
        switch Self.actionOnConnect(
            enabled: enabled, hasToken: token != nil, isDemo: session.host.isDemo, wasWritten: written.contains(session.host.id)) {
        case .write: write(to: session)
        case .delete: delete(on: session)
        case .nothing: break
        }
    }

    /// Only this session: another window's may still be up.
    func disconnected(_ session: HostSession) {
        live[session.host.id]?.removeAll { $0 === session }
        if live[session.host.id]?.isEmpty == true { live.removeValue(forKey: session.host.id) }
    }

    /// The machine was removed or edited: its file goes while the line is still up. `SessionStore`
    /// stops the session right after; its teardown waits for this, in turn after a write in flight.
    func sessionRemoved(_ session: HostSession) {
        disconnected(session)
        guard written.contains(session.host.id), session.state == .connected else { return }
        session.farewell = delete(on: session)
    }

    /// Machines gone from the app can't be reached any more: forget their files.
    func hostsChanged(_ ids: Set<UUID>) {
        written = written.intersection(ids)
    }

    /// The file for `session`'s machine, with this run's token and the time.
    func file(for session: HostSession) -> PushTokenFile? {
        guard let token else { return nil }
        return PushTokenFile(
            token: token, environment: Self.environment, bundleID: Bundle.main.bundleIdentifier ?? "",
            hostID: session.host.id, device: UIDevice.current.model,
            updatedMs: UInt64(Date.now.timeIntervalSince1970 * 1000))
    }

    private func write(to session: HostSession) {
        guard let file = file(for: session) else { return }
        written.insert(session.host.id)
        let installationID = installationID
        enqueue { try? await session.writePushToken(file, installationID: installationID) }
    }

    /// Removes the file on `session`'s machine. The machine counts as clean only once that
    /// returned: a delete that didn't get through (the line closed first) is tried again when
    /// the machine next connects.
    @discardableResult
    private func delete(on session: HostSession) -> Task<Void, Never> {
        let installationID = installationID
        return enqueue {
            guard (try? await session.deletePushToken(installationID: installationID)) != nil else { return }
            self.written.remove(session.host.id)
        }
    }

    /// One at a time, in order: a delete right after a write must win.
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = operation
        let next = Task {
            await previous?.value
            await work()
        }
        operation = next
        return next
    }

    func waitForFiles() async { await operation?.value }

    // MARK: Arriving notifications

    /// Whether a notification shows while Hirte is in front: not for the terminal on screen.
    static func presents(_ route: PushRoute?, onScreen: (UUID, String) -> Bool) -> Bool {
        guard let route else { return true }
        return !onScreen(route.hostID, route.address)
    }

    func presents(_ route: PushRoute?) -> Bool {
        Self.presents(route) { hostID, address in live[hostID]?.contains { $0.isLooking(at: address) } ?? false }
    }

    /// A tapped notification: the root view opens its terminal once the machine is connected.
    func open(_ route: PushRoute) {
        pendingRoute = route
    }

    func takeRoute() -> PushRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }
}
