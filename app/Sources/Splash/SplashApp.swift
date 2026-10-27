import AppKit
import SwiftUI

@main
struct SplashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Splash", id: "main") {
            MainView()
                .environment(delegate.state)
        }
        .defaultSize(width: 1120, height: 780)

        Settings {
            SettingsView()
                .environment(delegate.state)
        }

        MenuBarExtra {
            MenuBarMenu()
                .environment(delegate.state)
        } label: {
            Image(systemName: delegate.state.server.phase == .ready ? "bolt.fill" : "bolt")
        }
    }
}

/// Owns the app's state, starts it on launch, and stops what runs before the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState

    override init() {
        Preference.register()
        guard let runtime = Runtime.locate() else {
            let alert = NSAlert()
            alert.messageText = "Splash is damaged"
            alert.informativeText = "Its runtime is missing. Download Splash again."
            alert.runModal()
            exit(1)
        }
        state = AppState(runtime: runtime)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await state.launch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let server = state.server
        let installer = state.installer
        guard server.running || installer.running else { return .terminateNow }
        if installer.running || server.activeRequests > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit Splash?"
            alert.informativeText = installer.running
                ? "The download of \(installer.model ?? "a model") stops, and starts over next time."
                : "Splash is answering a request, which stops."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        state.quit()
        Task {
            while server.running || installer.running {
                try? await Task.sleep(for: .milliseconds(200))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
