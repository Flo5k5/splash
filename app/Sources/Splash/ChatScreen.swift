import SwiftUI

extension Font {
    /// What answers, messages and the composer are written in.
    static let reading = Font.system(size: 15)
}

/// The width of the conversation and of the composer under it.
private let column: CGFloat = 680

/// The conversations at the side of the open one. The window's toolbar is the Server's, so the
/// switch between the two stays where it is.
struct ChatScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            ChatList()
                .frame(width: 260)
            Divider()
            ConversationView()
        }
        .onAppear { state.draft.focus() }
    }
}

private struct ChatList: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var deleting: Conversation?
    @State private var renaming: Conversation?
    @State private var title = ""

    var body: some View {
        @Bindable var chats = state.chats
        let shown = query.isEmpty ? chats.conversations : chats.conversations.filter { conversation in
            conversation.title.localizedStandardContains(query)
                || conversation.messages.contains { $0.text.localizedStandardContains(query) }
        }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query, prompt: Text("Search"))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            list(shown)
        }
        .background(.background.secondary)
        .confirmationDialog("Delete this chat?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { conversation in
            Button("Delete", role: .destructive) { chats.delete(conversation.id) }
        } message: { conversation in
            Text("“\(conversation.title)” will be deleted from this Mac.")
        }
        .alert("Rename Chat", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { conversation in
            TextField("Name", text: $title)
            Button("Rename") { chats.rename(conversation.id, to: title) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The conversations, the open one on a soft highlight.
    private func list(_ shown: [Conversation]) -> some View {
        let chats = state.chats
        return List {
            if !shown.isEmpty {
                Section(query.isEmpty ? "Recents" : "Results") {
                    ForEach(shown) { conversation in
                        let open = chats.selection == conversation.id
                        Button { chats.selection = conversation.id } label: {
                            Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(open ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                                .padding(.horizontal, 10)
                        )
                        .accessibilityAddTraits(open ? .isSelected : [])
                        .contextMenu {
                            Button("Rename…") {
                                title = conversation.title
                                renaming = conversation
                            }
                            Button("Delete…", role: .destructive) { deleting = conversation }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct ConversationView: View {
    @Environment(AppState.self) private var state
    @State private var position = ScrollPosition()
    @State private var atBottom = true

    var body: some View {
        let conversation = state.chats.current
        VStack(spacing: 0) {
            if let conversation, !conversation.messages.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(conversation.messages) { message in
                            MessageView(message: message, last: message.id == conversation.messages.last?.id,
                                        streaming: state.chats.streaming == conversation.id)
                        }
                    }
                    .frame(maxWidth: column)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition($position)
                // Opens at the latest message and follows a reply while the reader is at the
                // bottom; a short conversation still reads from the top.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(atBottom ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                } action: { _, bottom in
                    atBottom = bottom
                }
                .onChange(of: conversation.messages.count) { position.scrollTo(edge: .bottom) }
                .onChange(of: conversation.id) {
                    atBottom = true
                    position.scrollTo(edge: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        Button {
                            withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: .circle)
                        .overlay { Circle().strokeBorder(.separator) }
                        .padding(.bottom, 12)
                        .help("Scroll to Latest")
                        .transition(.opacity)
                    }
                }
                footer
            } else {
                Spacer()
                Text("How can I help?")
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.bottom, 24)
                footer
                Spacer()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLine()
            Composer(draft: state.draft)
        }
        .frame(maxWidth: column)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
}

/// What keeps the chat from answering now, in one line above the composer: a model starting or
/// stopping, a problem, none running. Models start on the Server screen.
private struct StatusLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            switch state.server.phase {
            case .starting, .stopping:
                ProgressView().controlSize(.small)
                Text(state.status).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                Text("\(state.status).").foregroundStyle(.secondary)
                Button("Open Server") { state.section = .server }
            case .stopped:
                Text(state.installed.isEmpty ? "Download a model to start chatting." : "No model is running.")
                    .foregroundStyle(.secondary)
                Button("Open Server") { state.section = .server }
            case .ready:
                EmptyView()
            }
        }
        .font(.callout)
        .buttonStyle(.link)
        .padding(.horizontal, 4)
    }
}

private struct MessageView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    let last: Bool
    let streaming: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                                if let image = NSImage(data: data) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipShape(.rect(cornerRadius: 12))
                                }
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.reading)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 18))
                    }
                }
            }
        case .assistant:
            let live = streaming && last
            VStack(alignment: .leading, spacing: 10) {
                if !message.reasoning.isEmpty {
                    Thinking(text: message.reasoning, live: live && message.text.isEmpty)
                }
                if message.isEmpty && live {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        // After the idle release, the model loads again before it answers.
                        if state.server.asleep, let model = state.server.model {
                            Text("Loading \(state.displayName(of: model)) back into memory…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !message.text.isEmpty {
                    MarkdownView(text: message.text)
                }
                if let error = message.error {
                    Label {
                        Text(error).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                    .font(.callout)
                }
                if !live {
                    actions
                }
            }
            .onHover { hovering = $0 }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
            }
            .help("Copy")
            .accessibilityLabel("Copy Reply")
            if last {
                Button { state.retry() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(state.server.phase != .ready || state.chats.streaming != nil)
                    .help("Ask \(state.server.model.map(state.displayName(of:)) ?? "the model") Again")
                    .accessibilityLabel("Ask Again")
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
                .help(message.tokensPerSecond.map { "\($0.formatted(.number.precision(.fractionLength(0)))) tokens per second" } ?? "")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
        .opacity(hovering || last ? 1 : 0)
    }

    private var details: String {
        [message.model.map(state.displayName(of:)), message.stopped == true ? "Stopped" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// What the model thought, open while it thinks and folded once it answers, set apart from the
/// answer by a rule.
private struct Thinking: View {
    let text: String
    let live: Bool
    @State private var expanded: Bool?

    var body: some View {
        let open = expanded ?? live
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded = !open } label: {
                HStack(spacing: 4) {
                    Text(live ? "Thinking…" : "Thought process")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
            }
        }
        .animation(.smooth(duration: 0.2), value: open)
    }
}
