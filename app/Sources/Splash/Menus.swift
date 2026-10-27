import SwiftUI

/// What runs and what downloads, as menu lines.
struct StatusItems: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Text(state.status)
        if let download = state.downloadStatus { Text(download) }
    }
}

/// The models on this Mac to run, and stopping the one running.
struct ModelMenuItems: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let server = state.server
        let current = server.running ? server.next ?? server.model : nil
        Picker("Model", selection: Binding(get: { current }, set: { model in
            if let model, model != current { state.start(model) }
        })) {
            ForEach(state.installed) { Text(state.displayName(of: $0.id)).tag(Optional($0.id)) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(!state.ready)
        Divider()
        if let current {
            Button("Stop \(state.displayName(of: current))") { state.stop() }
                .disabled(server.phase == .stopping)
        }
        Button("Download Models…") {
            openWindow(id: "main")
            NSApp.activate()
            state.showModels()
        }
        .disabled(!state.ready)
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
        Button("Open Splash") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        ModelMenuItems()
        Divider()
        Menu("Coding Agents") { AgentMenuItems() }
        Divider()
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Button("Quit Splash") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
