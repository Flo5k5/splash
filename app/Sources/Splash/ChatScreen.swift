import SwiftUI

extension Font {
    /// What answers, messages and the composer are written in.
    static let reading = Font.system(size: 15)
}

/// The width of the conversation and of the composer under it.
private let column: CGFloat = 680

/// The conversations beside the open one.
struct ChatScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            ChatList()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
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
        List(selection: $chats.selection) {
            if !shown.isEmpty {
                Section(query.isEmpty ? "Recents" : "Results") {
                    ForEach(shown) { conversation in
                        Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
                            .lineLimit(1)
                            .tag(conversation.id)
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
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .onDeleteCommand { deleting = chats.current }
        .toolbar {
            ToolbarItem {
                Button {
                    chats.newChat()
                    state.draft.focus()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat")
            }
        }
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

/// What keeps the chat from answering now, or what it can do next, in one line above the
/// composer: a model starting or stopping, a problem, none running, another one downloaded.
private struct StatusLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let server = state.server
        let name = server.model.map(state.displayName(of:)) ?? ""
        HStack(spacing: 8) {
            switch server.phase {
            case .starting:
                ProgressView().controlSize(.small)
                Text(loading(name))
                Button("Cancel") { state.stop() }
            case .stopping:
                ProgressView().controlSize(.small)
                if let next = server.next {
                    Text("Switching to \(state.displayName(of: next))…")
                    Button("Cancel") { state.stop() }
                } else {
                    Text("Stopping \(name)…")
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                Text("\(name) ran into a problem.")
                Button("Details…") { state.showModels() }
                if let model = server.model { Button("Try Again") { state.start(model) } }
            case .stopped:
                Text("No model is running.")
                if let last = state.lastModel {
                    Button("Start \(state.displayName(of: last))") { state.start(last) }
                } else {
                    Button("Choose a Model…") { state.showModels() }
                }
            case .ready:
                if let model = state.downloaded {
                    Text("\(state.displayName(of: model)) is ready.")
                    Button("Switch to It") { state.start(model) }
                } else if let failure = state.installer.failure {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    Text("\(state.displayName(of: failure.model)) couldn’t download.")
                    Button("Details…") { state.showModels() }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .buttonStyle(.link)
        .padding(.horizontal, 4)
    }

    private func loading(_ name: String) -> String {
        let size = state.installed.first { $0.id == state.server.model }.map { Format.size($0.bytes) }
        return size.map { "Loading \(name) (\($0)) into memory…" } ?? "Loading \(name) into memory…"
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
                    ProgressView().controlSize(.small)
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
