import SwiftUI

/// What runs and what downloads, as menu lines.
struct StatusItems: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Text(state.status)
        if let download = state.downloadStatus { Text(download) }
    }
}

/// Stopping the model that runs, and the coding agents on it; models start on the Server screen.
struct ServerMenuItems: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let server = state.server
        if server.running, let model = server.next ?? server.model {
            Button("Stop \(state.displayName(of: model))") { state.stop() }
                .disabled(server.phase == .stopping && server.next == nil)
        }
        Menu("Coding Agents") { AgentMenuItems() }
    }
}

/// The coding agents, and the address other apps reach the model at.
struct AgentMenuItems: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section("Open in Terminal") {
            ForEach(Agent.allCases) { agent in
                Button("\(agent.title)…") {
                    NSApp.activate()
                    agent.open(runtime: state.runtime, port: state.server.settings.port)
                }
                .disabled(state.server.phase != .ready)
            }
        }
        Divider()
        Button("Copy API Address") { state.copyAPIAddress() }
    }
}

/// The menu bar item's menu.
struct MenuBarMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusItems()
        Divider()
        Button("Open Server") { show(.server) }
        Button("Open Chat") { show(.chat) }
        Divider()
        ServerMenuItems()
        Divider()
        Button("Quit Splash") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show(_ section: AppState.Section) {
        state.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}
