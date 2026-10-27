import SwiftUI

/// The main window: the Server or the Chat, as the switch at the toolbar's start picks. Its toolbar
/// holds, besides, a download under way while the Chat shows.
struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        content
            .frame(minWidth: 800, minHeight: 560)
            .navigationTitle("Splash")
            .toolbar(removing: .title)
            .toolbar {
                if state.available {
                    ToolbarItem(placement: .navigation) { SectionSwitch() }
                        .sharedBackgroundVisibility(.hidden)
                }
                if state.available && state.section == .chat {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            state.chats.newChat()
                            state.draft.focus()
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .help("New Chat (⌘N)")
                    }
                }
                if state.installer.running && state.section == .chat {
                    ToolbarItem { DownloadButton() }
                }
            }
            .onChange(of: state.status) { _, status in
                AccessibilityNotification.Announcement(status).post()
            }
    }

    @ViewBuilder private var content: some View {
        if let blocker = state.blocker {
            ContentUnavailableView(blocker.title, systemImage: blocker.symbol, description: Text(blocker.message))
        } else if !state.launched {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch state.section {
            case .server: ServerView()
            case .chat: ChatScreen()
            }
        }
    }
}

/// The switch between the Server and the Chat.
struct SectionSwitch: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            segment("Server", .server, help: "Models and how they run (⌘1)")
            segment("Chat", .chat, help: "Chat with the model that runs (⌘2)")
        }
        .padding(2)
        .background(.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), in: .capsule)
    }

    private func segment(_ title: String, _ section: AppState.Section, help: String) -> some View {
        let selected = state.section == section
        return Button { state.section = section } label: {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    if selected {
                        Capsule()
                            .fill(colorScheme == .dark ? AnyShapeStyle(.white.opacity(0.16)) : AnyShapeStyle(.white))
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A download under way while the Chat shows; opens the Server.
struct DownloadButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button { state.section = .server } label: {
            ProgressView(value: state.installer.progress?.fraction ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .help(state.downloadStatus ?? "")
        .accessibilityLabel("Download")
        .accessibilityValue(state.downloadStatus ?? "")
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
