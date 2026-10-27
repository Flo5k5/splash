import SwiftUI

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
                    agent.open(runtime: state.runtime, settings: state.server.settings)
                }
                .disabled(state.server.phase != .ready)
            }
        }
        Divider()
        Button("Copy API Address") { state.copyAPIAddress() }
    }
}

/// The menu bar item's panel, in Splash's own style: what runs, with its totals while it serves,
/// any download, then the window's two parts, stopping the model, its coding agents, and quitting.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var agents = false

    var body: some View {
        let server = state.server
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 10) {
                Circle()
                    .fill(server.phase == .ready ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                    .frame(width: 8, height: 8)
                Text(state.status).font(.headline).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if server.phase == .ready {
                totals(server.activity)
            }
            if let download = state.downloadStatus {
                Text(download).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            PanelRow(title: "Open Server") { show(.server) }
            PanelRow(title: "Open Chat") { show(.chat) }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            if server.running, let model = server.next ?? server.model {
                PanelRow(title: "Stop \(state.displayName(of: model))") { state.stop() }
                    .disabled(server.phase == .stopping && server.next == nil)
            }
            if server.phase == .ready {
                PanelRow(title: "Coding Agents", open: agents) { withAnimation(.smooth(duration: 0.2)) { agents.toggle() } }
                if agents {
                    ForEach(Agent.allCases) { agent in
                        PanelRow(title: agent.title, indent: true) {
                            NSApp.activate()
                            agent.open(runtime: state.runtime, settings: server.settings)
                        }
                    }
                    PanelRow(title: "Copy API Address", indent: true) { state.copyAPIAddress() }
                }
            }
            if server.running {
                Divider().padding(.horizontal, 8).padding(.vertical, 4)
            }
            PanelRow(title: "Quit Splash", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 300)
    }

    /// What the model did since it started: requests, answering speed and memory; the tokens it
    /// generated, read and took from its cache.
    private func totals(_ activity: Server.Activity) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 8) {
            GridRow {
                figure(activity.served.formatted(), "Requests")
                figure(activity.generation.map { "\($0.formatted(.number.precision(.fractionLength(0)))) tok/s" } ?? "–", "Answering")
                figure(activity.memory.map(Format.size) ?? "–", "Memory")
            }
            GridRow {
                figure(activity.generated.formatted(.number.notation(.compactName)), "Generated")
                figure(activity.read.formatted(.number.notation(.compactName)), "Prompt read")
                figure(activity.cached.formatted(.number.notation(.compactName)), "From cache")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func show(_ section: AppState.Section) {
        state.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// A row of the menu bar's panel, highlighted under the pointer as the app's popups are; one that
/// opens rows under it shows a chevron.
private struct PanelRow: View {
    let title: String
    var shortcut: String?
    var open: Bool?
    var indent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(enabled ? .primary : .tertiary)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
                if let open {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.leading, indent ? 22 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.hoverFlush)
    }
}
