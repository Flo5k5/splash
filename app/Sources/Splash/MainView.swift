import SwiftUI

/// The main window: the chat with the model being served, or the models to choose from.
struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            if let blocker = state.blocker {
                ContentUnavailableView("Splash can’t run here", systemImage: "exclamationmark.triangle",
                                       description: Text(blocker))
            } else {
                // The chat stays, hidden, under the models: leaving it would end the reply it is
                // streaming, and the chat page saves an exchange only once it is complete.
                ZStack {
                    ChatPane()
                        .opacity(state.tab == .chat ? 1 : 0)
                        .allowsHitTesting(state.tab == .chat)
                        .accessibilityHidden(state.tab != .chat)
                    if state.tab == .models { ModelsView() }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .navigationTitle("Splash")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $state.tab) {
                    Text("Chat").tag(AppState.Tab.chat)
                    Text("Models").tag(AppState.Tab.models)
                }
                .pickerStyle(.segmented)
                .disabled(state.blocker != nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                AgentsMenu()
                ServerButton()
            }
        }
    }

    private var subtitle: String {
        let server = state.server
        guard let model = server.model.map(state.catalog.name(of:)) else { return "No model running" }
        switch server.phase {
        case .starting: return "Starting \(model)…"
        case .stopping: return "Stopping \(model)…"
        case .stopped: return "No model running"
        case .failed: return "\(model) stopped"
        case .ready:
            if server.asleep { return "\(model) · resting, wakes on the next message" }
            return [model, server.contextTokens.map { "\(Format.tokens($0)) context" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Starts the last model, or stops the one running.
struct ServerButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let server = state.server
        if server.running {
            Button("Stop", systemImage: "stop.fill") { server.stop() }
                .help("Stop the model and free its memory")
                .disabled(server.phase == .stopping)
        } else {
            Button("Start", systemImage: "play.fill") { lastModel.map(state.start) }
                .help(lastModel.map { "Start \(state.catalog.name(of: $0))" } ?? "Choose a model to start")
                .disabled(lastModel == nil || state.blocker != nil)
        }
    }

    private var lastModel: String? {
        (state.server.model ?? UserDefaults.standard.string(forKey: Preference.lastModel))
            .flatMap { state.isInstalled($0) ? $0 : nil }
    }
}

/// Opens a coding agent on the model being served.
struct AgentsMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Menu("Coding Agents", systemImage: "terminal") {
            ForEach(Agent.allCases) { agent in
                Button("\(agent.title)…") {
                    agent.open(runtime: state.runtime, port: state.server.settings.port)
                }
            }
        }
        .help("Open a coding agent on this model in Terminal")
        .disabled(state.server.phase != .ready)
    }
}

/// The chat page once the model is ready; until then, what the start is doing.
struct ChatPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let server = state.server
        let name = server.model.map(state.catalog.name(of:)) ?? ""
        switch server.phase {
        case .ready:
            ChatWebView(url: server.settings.url, generation: server.generation)
        case .starting:
            StatusPanel(title: "Starting \(name)", detail: server.latest, progress: true) {
                Button("Cancel") { server.stop() }
            }
        case .stopping:
            StatusPanel(title: "Stopping \(name)", detail: "Freeing the model’s memory…", progress: true) {}
        case .failed(let message):
            StatusPanel(title: "\(name) stopped", detail: message, systemImage: "exclamationmark.triangle") {
                Button("Show Log") { NSWorkspace.shared.open(Server.log) }
                Button("Choose Another Model") { state.tab = .models }
                if let model = server.model {
                    Button("Try Again") { state.start(model) }.keyboardShortcut(.defaultAction)
                }
            }
        case .stopped:
            StatusPanel(title: "No model running", detail: "Start a model to chat with it here.",
                        systemImage: "bolt") {
                Button("Choose a Model") { state.tab = .models }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A centred title, detail line and actions, with a spinner or a symbol above.
struct StatusPanel<Actions: View>: View {
    let title: String
    let detail: String
    var progress = false
    var systemImage: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            if progress {
                ProgressView().controlSize(.large)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            }
            Text(title).font(.title2.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
            HStack { actions }.padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Format {
    static func tokens(_ count: Int) -> String {
        count >= 1024 && count % 1024 == 0 ? "\(count / 1024)K" : count.formatted()
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}
