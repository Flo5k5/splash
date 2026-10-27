import SwiftUI

/// The main window: the welcome until a model is on this Mac, the chats after. Its toolbar holds
/// the model being talked to and, while one runs, the coding agents.
struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        screen
            .transition(.opacity)
            .frame(minWidth: 800, minHeight: 560)
            .navigationTitle("Splash")
            .toolbar(removing: .title)
            .toolbar {
                if state.screen == .chat {
                    ToolbarItem(placement: .navigation) { ModelMenu() }
                        .sharedBackgroundVisibility(.hidden)
                }
                if state.installer.running && state.screen != .models && !state.showingModels {
                    ToolbarItem { DownloadButton() }
                }
                if state.server.running {
                    ToolbarItem { AgentsMenu() }
                }
            }
            .animation(.smooth(duration: 0.25), value: state.screen)
            .sheet(isPresented: $state.showingModels) { ModelsSheet() }
            .onChange(of: state.screen) { _, screen in
                if screen == .models { state.showingModels = false }
            }
            .onChange(of: state.status) { _, status in
                AccessibilityNotification.Announcement(status).post()
            }
    }

    @ViewBuilder private var screen: some View {
        switch state.screen {
        case .launching:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .blocked:
            if let blocker = state.blocker {
                ContentUnavailableView(blocker.title, systemImage: blocker.symbol, description: Text(blocker.message))
            }
        case .models:
            ModelsView()
        case .chat:
            ChatScreen()
        }
    }
}

/// The model being talked to, as the window's heading, opening the models and the actions on it.
struct ModelMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let server = state.server
        Menu {
            StatusItems()
            Divider()
            ModelMenuItems()
        } label: {
            Text(server.running ? (server.next ?? server.model).map(state.displayName(of:)) ?? "" : "Choose a Model")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280)
        }
        .menuIndicator(.visible)
        .help("Choose the model to talk to")
        .accessibilityLabel("Model")
        .accessibilityValue(state.status)
    }
}

/// A download under way while the models are not on screen; opens them.
struct DownloadButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button { state.showModels() } label: {
            ProgressView(value: state.installer.progress?.fraction ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .help(state.downloadStatus ?? "")
        .accessibilityLabel("Download")
        .accessibilityValue(state.downloadStatus ?? "")
    }
}

/// Opens a coding agent on the running model.
struct AgentsMenu: View {
    var body: some View {
        Menu {
            AgentMenuItems()
        } label: {
            Label("Coding Agents", systemImage: "terminal")
        }
        .help("Open a coding agent in Terminal, connected to this model")
    }
}

enum Format {
    /// Decimal units, as Finder counts: 120 MB, 6.7 GB, 21 GB. Whole GB from 10 GB up, so a
    /// model's size reads the same everywhere.
    static func size(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1e9
        guard gigabytes >= 1 else { return bytes.formatted(.byteCount(style: .file)) }
        return "\(gigabytes.formatted(.number.precision(.fractionLength(gigabytes < 10 ? 1 : 0)))) GB"
    }

    static func gigabytes(_ count: Int) -> Int64 { Int64(count) * 1_000_000_000 }
}
