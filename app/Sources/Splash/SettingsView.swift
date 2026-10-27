import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Preference.idleRelease) private var idleRelease = IdleRelease.tenMinutes
    @AppStorage(Preference.startOnOpen) private var startOnOpen = true
    @AppStorage(Preference.port) private var port = Preference.defaultPort
    @AppStorage(Preference.serveOptions) private var serveOptions = ""
    @State private var login = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                Picker("Free the model’s memory when idle", selection: $idleRelease) {
                    ForEach(IdleRelease.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Start the last model when Splash opens", isOn: $startOnOpen)
                Toggle("Open Splash at login", isOn: Binding(
                    get: { login != .notRegistered && login != .notFound },
                    set: { enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        login = SMAppService.mainApp.status
                    }
                ))
                if login == .requiresApproval {
                    LabeledContent("macOS asks you to allow Splash to open at login.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } footer: {
                Text("A model whose memory was freed loads again with the next message.")
            }
            Section {
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("More serve options", text: $serveOptions, prompt: Text("--max-context 128K"))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Apps and coding agents reach the model at http://127.0.0.1:\(String(port))/v1. Chats are saved per port. More serve options are passed to splash serve as typed; see splash serve --help. Changes apply when a model next starts.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu bar item's menu: what runs, and the quick actions.
struct MenuBarMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let server = state.server
        Text(status)
        Divider()
        Button("Open Splash") {
            openWindow(id: "main")
            NSApp.activate()
        }
        if server.running {
            Button("Stop Model") { server.stop() }.disabled(server.phase == .stopping)
        }
        Button("Copy API Address") {
            let settings = server.running ? server.settings : ServeSettings.current()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(settings.url.appending(path: "v1").absoluteString, forType: .string)
        }
        Menu("Coding Agents") {
            ForEach(Agent.allCases) { agent in
                Button("\(agent.title)…") {
                    NSApp.activate()
                    agent.open(runtime: state.runtime, port: server.settings.port)
                }
            }
        }
        .disabled(server.phase != .ready)
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Splash") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var status: String {
        let server = state.server
        let name = server.model.map(state.catalog.name(of:)) ?? ""
        switch server.phase {
        case .ready: return server.asleep ? "\(name) — resting" : "\(name) — ready"
        case .starting: return "Starting \(name)…"
        case .stopping: return "Stopping \(name)…"
        case .failed: return "\(name) stopped"
        case .stopped: return "No model running"
        }
    }
}
