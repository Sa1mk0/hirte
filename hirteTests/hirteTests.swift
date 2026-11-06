import Foundation
import HerdrKit
import Testing
import UIKit
@testable import hirte

@MainActor
struct ThemeTests {
    @Test func bundledThemesLoad() {
        // More than the built-in fallback: themes.json is in the app and decodes.
        #expect(TerminalTheme.all.count > 1)
        #expect(!TerminalTheme.darkThemes.isEmpty)
        #expect(!TerminalTheme.lightThemes.isEmpty)
    }

    @Test func everyThemeHasSixteenColors() {
        for theme in TerminalTheme.all {
            #expect(theme.ansi.count == 16, "\(theme.id)")
        }
    }

    @Test func defaultsExistAndUnknownIdsFallBack() {
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: true).id == TerminalTheme.defaultDark)
        #expect(TerminalTheme.find(TerminalTheme.defaultLight, dark: false).id == TerminalTheme.defaultLight)
        #expect(TerminalTheme.find("no-such-theme", dark: true).id == TerminalTheme.defaultDark)
        // A dark theme's id asked for as light falls back to the light default.
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: false).id == TerminalTheme.defaultLight)
    }
}

@MainActor
struct HostTests {
    @Test func subtitleShowsPortOnlyWhenNotDefault() {
        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        #expect(host.subtitle == "pavel@mini.local")
        host.target.port = 2222
        #expect(host.subtitle == "pavel@mini.local:2222")
    }

    @Test func hostsSavedBeforeTheDemoExistedStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.isDemo == false)
    }

    @Test func storePersistsAndAddsTheDemoOnce() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel")))
        let demo = store.addDemo()
        #expect(store.addDemo().id == demo.id)

        let reloaded = HostStore(defaults: defaults)
        #expect(reloaded.hosts.map(\.name) == ["Mini", "Demo machine"])
        #expect(reloaded.hasDemo)
    }
}

struct AgeTests {
    @Test func shortAgesLikeHerdrApp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seconds: TimeInterval) -> String { Terminal.shortAge(now.addingTimeInterval(-seconds), now: now) }
        #expect(age(59) == "now")
        #expect(age(-30) == "now")  // the machine's clock is ahead
        #expect(age(60) == "1m")
        #expect(age(47 * 60 + 59) == "47m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(23 * 3600 + 3599) == "23h")
        #expect(age(2 * 86_400) == "2d")
    }
}

@MainActor
struct TerminalLayoutTests {
    @Test(.timeLimit(.minutes(1)))
    func resizingTheViewUpdatesTheEmulatorAndRemoteTerminal() async throws {
        let session = HostSession(host: .makeDemo(), knownHosts: InMemoryKnownHosts())
        session.start(keys: KeyLibrary(store: KeyStore(storage: InMemoryKeyStorage())))
        defer { session.stop() }
        try await waitUntil { session.state == .connected }

        let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true))
        defer { model.stop() }
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        canvas.model = model
        canvas.onGridSize = { cols, rows in
            if case .attaching = model.phase {
                model.start(session: session, address: "t5", cols: cols, rows: rows)
            } else {
                model.viewSizeChanged(cols: cols, rows: rows)
            }
        }
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        try await waitUntil { model.phase == .live && model.frame.cols > 0 }
        let wideColumns = model.frame.cols

        for size in [CGSize(width: 360, height: 600), CGSize(width: 1280, height: 720)] {
            let previousColumns = model.frame.cols
            canvas.frame.size = size
            canvas.setNeedsLayout()
            canvas.layoutIfNeeded()
            try await waitUntil {
                model.frame.cols != previousColumns
                    && session.terminal("t5")?.cols == model.frame.cols
                    && session.terminal("t5")?.rows == model.frame.rows
            }
            if size.width < 1024 {
                #expect(model.frame.cols < wideColumns)
            } else {
                #expect(model.frame.cols > wideColumns)
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}
