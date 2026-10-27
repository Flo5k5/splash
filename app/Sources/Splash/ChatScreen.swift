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
            // Up through the toolbar, as far as the sidebar's background goes.
            Divider().ignoresSafeArea(edges: .top)
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
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
            .padding(.horizontal, 10)
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

    /// The conversations, the latest first, the open one held highlighted; a conversation that
    /// gets a message moves to the top, and one deleted closes its gap.
    private func list(_ shown: [Conversation]) -> some View {
        let chats = state.chats
        return List {
            ForEach(shown) { conversation in
                ChatRow(conversation: conversation, open: chats.selection == conversation.id) {
                    chats.selection = conversation.id
                }
                .contextMenu {
                    Button("Rename…") {
                        title = conversation.title
                        renaming = conversation
                    }
                    Button("Delete…", role: .destructive) { deleting = conversation }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .animation(Motion.settle, value: shown.map(\.id))
    }
}

/// A conversation in the list: its title, highlighted as the app's buttons are, held while open;
/// its text in line with the search field's.
private struct ChatRow: View {
    let conversation: Conversation
    let open: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(HoverStyle(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8), held: open))
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

private struct ConversationView: View {
    @Environment(AppState.self) private var state
    @State private var position = ScrollPosition()
    /// Whether the conversation follows the latest message: until the reader scrolls up, and again
    /// once they scroll back to the bottom.
    @State private var atBottom = true
    @State private var scrolling = false

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
                // The reader's own scrolling: a drag, the wheel, and the glide after them; not the
                // conversation's own following.
                .onScrollPhaseChange { _, phase in scrolling = [.tracking, .interacting, .decelerating].contains(phase) }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                } action: { _, bottom in
                    // A reply that grows leaves the bottom behind; only the reader's scrolling
                    // stops the following.
                    if bottom || scrolling { atBottom = bottom }
                }
                .onChange(of: conversation.messages.count) {
                    atBottom = true
                    withAnimation(Motion.glide) { position.scrollTo(edge: .bottom) }
                }
                .onChange(of: conversation.messages.last.map { $0.text.count + $0.reasoning.count }) {
                    if atBottom && !scrolling { position.scrollTo(edge: .bottom) }
                }
                .onChange(of: conversation.id) {
                    atBottom = true
                    position.scrollTo(edge: .bottom)
                }
                .overlay(alignment: .bottom) { latest.padding(.bottom, 12) }
                footer
            } else {
                // A new chat: the mark, showing what the Server does, over the composer.
                Spacer()
                StatusMark(look: state.markLook == .failed ? .off : state.markLook, since: state.server.since, size: 44)
                    .padding(.bottom, 28)
                footer
                Spacer()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var footer: some View {
        Composer(draft: state.draft)
            .frame(maxWidth: column)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
    }

    /// Back to the latest message, once the reader has scrolled up from it.
    private var latest: some View {
        Button {
            withAnimation(Motion.glide) { position.scrollTo(edge: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(HoverStyle(padding: EdgeInsets(), shape: AnyShape(.circle)))
        .background(.regularMaterial, in: .circle)
        .overlay { Circle().strokeBorder(.separator) }
        .help("Scroll to Latest")
        .accessibilityLabel("Scroll to Latest")
        .opacity(atBottom ? 0 : 1)
        .allowsHitTesting(!atBottom)
        .accessibilityHidden(atBottom)
        .animation(Motion.quick, value: atBottom)
    }
}

private struct MessageView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    let last: Bool
    let streaming: Bool
    @State private var hovering = false

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
            // The reply's actions keep their place, so that the reply doesn't grow as it ends; they
            // show under the pointer and on the latest reply, a little slower to come than to go.
            let shown = !live && (hovering || last)
            VStack(alignment: .leading, spacing: 10) {
                if (live && message.text.isEmpty) || !message.reasoning.isEmpty {
                    ReplyLine(message: message, live: live ? state.chats.live : nil)
                }
                if !message.text.isEmpty {
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
                actions
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    // For VoiceOver, which never hovers, they are there but while the reply streams.
                    .accessibilityHidden(live)
                    .animation(shown ? Motion.quick.delay(0.08) : Motion.quick, value: shown)
            }
            .onHover { hovering = $0 }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            CopyButton(copy: { NSPasteboard.put(message.text) })
            .help("Copy")
            .accessibilityLabel("Copy Reply")
            if last {
                Button { state.retry() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(state.server.phase != .ready || state.chats.streaming != nil)
                    .help("Ask \(state.server.model.map(state.displayName(of:)) ?? "the model") Again")
                    .accessibilityLabel("Ask Again")
            }
            Text(details)
                .font(.subheadline)
                .monospacedDigit()
                .padding(.leading, 6)
        }
        .buttonStyle(.hover)
        .padding(.leading, -6)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// The model that answered, how fast, and whether it was stopped.
    private var details: String {
        [message.model.map(state.displayName(of:)), message.tokensPerSecond.map { "\(Format.whole($0)) tok/s" },
         message.stopped == true ? "Stopped" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The line over a reply, of what comes before its answer: Reading while the prompt is read, then
/// Thinking while the model thinks, and once it answers, what the thinking took. Only numbers move,
/// once a second. It shows half a second into a wait, so that a quick answer doesn't flash it, and
/// opens to the thinking, of which it shows the latest lines while the model thinks.
private struct ReplyLine: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    /// The reply as it streams, for this message while it is the one streaming.
    let live: ChatStore.Live?
    @State private var expanded: Bool?
    @State private var held = false
    @State private var tall = false

    var body: some View {
        let reasoned = !message.reasoning.isEmpty
        let thinking = live != nil && message.text.isEmpty && reasoned
        let open = reasoned && (expanded ?? thinking)
        VStack(alignment: .leading, spacing: 8) {
            Button { if reasoned { expanded = !open } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(reasoned ? 1 : 0)
                        .accessibilityHidden(true)
                    if let live, message.text.isEmpty {
                        TimelineView(.periodic(from: live.asked, by: 1)) { context in
                            words(live: live, at: context.date)
                        }
                    } else {
                        words(live: nil, at: .now)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .buttonStyle(.hover)
            .padding(.leading, -6)
            .allowsHitTesting(reasoned)
            .accessibilityValue(reasoned ? (open ? "Expanded" : "Collapsed") : "")
            if open {
                Text(message.reasoning)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: Bool.self) { $0.size.height > 96 } action: { tall = $0 }
                    // While it thinks, its latest lines, faded at the top; all of it after.
                    .frame(maxWidth: .infinity, maxHeight: thinking ? 96 : nil, alignment: .bottomLeading)
                    .clipped()
                    .mask {
                        if thinking && tall {
                            VStack(spacing: 0) {
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                                Rectangle()
                            }
                        } else {
                            Rectangle()
                        }
                    }
                    .setApart()
            }
        }
        .opacity(live == nil || held || reasoned ? 1 : 0)
        .animation(Motion.settle, value: open)
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(Motion.quick) { held = true }
        }
    }

    /// Reading or Thinking, and its figures in a fainter tone.
    private func words(live: ChatStore.Live?, at date: Date) -> some View {
        let (verb, facts): (String, String?) = if let live, message.reasoning.isEmpty {
            if state.server.asleep {
                // After the idle release, the model loads again before it reads.
                ("Loading into memory", Self.elapsed(since: live.asked, at: date))
            } else {
                ("Reading", live.read.map { "\(Int($0 * 100))%" } ?? Self.elapsed(since: live.asked, at: date))
            }
        } else if let live, let started = live.thinking {
            ("Thinking", Self.elapsed(since: started, at: date))
        } else {
            ("Thinking", [message.reasoningTokens.map { "\(Format.count($0)) tokens" }, message.thinkingTime.map(Format.seconds)]
                .compactMap { $0 }.joined(separator: " · "))
        }
        return HStack(spacing: 6) {
            Text(verb)
            if let facts, !facts.isEmpty { Text("· \(facts)").foregroundStyle(.tertiary) }
        }
    }

    /// Whole seconds since `start`, from the first.
    private static func elapsed(since start: Date, at date: Date) -> String? {
        let seconds = Int(date.timeIntervalSince(start))
        return seconds < 1 ? nil : "\(seconds)s"
    }
}
