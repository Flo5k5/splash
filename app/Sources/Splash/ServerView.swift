import SwiftUI

/// The width of the Server screen's column.
private let column: CGFloat = 640

/// The Server screen, where the window opens: the models on this Mac to pick from, how they
/// start, the suggested ones this Mac can run to download, and, under them all, what runs with
/// Start, Stop and Switch. Models start and change only here.
struct ServerView: View {
    @Environment(AppState.self) private var state
    @State private var customModel = false
    @State private var width: CGFloat = 0
    /// For pictures of the screen: the launch options' Advanced group and the request log open.
    var advanced = false

    var body: some View {
        let suggestions = state.catalog.suggestions(memory: Catalog.memory)
        let installedNames = Set(state.installed.map { state.catalog.name(of: $0.id) })
        let available = suggestions.filter { !installedNames.contains($0.name) && $0.id != state.installer.model }
        let first = state.installed.isEmpty
        let failed = if case .failed = state.server.phase { true } else { false }
        Form {
            if state.server.phase == .ready {
                Section {
                    ActivityFigures(activity: state.server.activity)
                    RequestLog(lines: state.server.requestLog, open: advanced)
                } header: {
                    SectionTitle(text: "Activity")
                }
            }
            if first || failed || state.installer.failure != nil || state.installer.running {
                Section {
                    if case .failed(let message) = state.server.phase, let model = state.server.model {
                        ProblemRow(title: "\(state.displayName(of: model)) ran into a problem", message: message,
                                   log: Server.log, dismiss: state.server.dismissFailure)
                    }
                    if let failure = state.installer.failure {
                        ProblemRow(title: "\(state.displayName(of: failure.model)) couldn’t download",
                                   message: failure.message, log: Installer.log, dismiss: state.installer.dismissFailure,
                                   retry: ("Download Again", { state.download(failure.model) }))
                    }
                    if state.installer.running { DownloadRow() }
                } header: {
                    if first { welcome }
                }
            }
            if !first {
                Section {
                    ForEach(state.installed) { ModelRow(model: $0) }
                } header: {
                    SectionTitle(text: "Models on This Mac")
                } footer: {
                    otherModels
                }
                LaunchOptions(advanced: advanced)
            }
            Section {
                ForEach(available, id: \.id) { variant in
                    SuggestedRow(variant: variant, recommended: variant == suggestions.first,
                                 lead: first && !state.installer.running && variant == suggestions.first)
                }
            } header: {
                if !available.isEmpty { SectionTitle(text: "Available to Download") }
            } footer: {
                if suggestions.isEmpty, let minimum = state.catalog.minimumMemory {
                    Text("The suggested models need a Mac with at least \(minimum) GB of memory; this one has \(Catalog.memory) GB.")
                }
                if first { otherModels }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, max(0, (width - column) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !first || state.server.running {
                VStack(spacing: 0) {
                    Divider()
                    ControlBar()
                }
                .background(.bar)
            }
        }
        .onAppear { state.refresh() }
        .sheet(isPresented: $customModel) { CustomModelSheet() }
    }

    /// Ways to models the list doesn't offer: one from Hugging Face by its ID, or files on this Mac.
    private var otherModels: some View {
        HStack(spacing: 16) {
            Button("Download Another Model…") { customModel = true }
                .disabled(state.installer.running || !state.ready)
            Button("Add Model from This Mac…", action: addLocal)
                .disabled(!state.ready)
        }
        .buttonStyle(.link)
    }

    /// Asks for model files on this Mac: a GGUF file, or the folder of an MLX or GGUF model.
    private func addLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose a GGUF file, or the folder of an MLX or GGUF model."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.addLocal(url)
    }

    /// The screen's heading before a model is on this Mac.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Splash")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Splash runs AI models privately on this Mac. Download one to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

/// Under the screen, in two lines: the model running, or the one picked, and what it does, with
/// what to do next: start it or try again, cancel, stop, switch to the one picked, restart with
/// changed options, open a coding agent, or chat.
private struct ControlBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let server = state.server
        let model = server.running ? server.model : state.selection
        HStack(spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(model.map(state.displayName(of:)) ?? "").font(.headline)
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer()
            actions
        }
        .lineLimit(1)
        .controlSize(.large)
        .padding(.horizontal, 10)
        .frame(maxWidth: column - 40)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// Whether the model picked is the one that failed, so that Start tries it again.
    private var failedPicked: Bool {
        if case .failed = state.server.phase { state.server.model == state.selection } else { false }
    }

    @ViewBuilder private var indicator: some View {
        let server = state.server
        switch server.phase {
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .ready:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .failed where server.running || failedPicked:
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        default:
            Circle().fill(.quaternary).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder private var detail: some View {
        let server = state.server
        switch server.phase {
        case .starting:
            Text("Loading into memory…")
        case .stopping:
            if let next = server.next {
                Text(next == server.model ? "Restarting…" : "Switching to \(state.displayName(of: next))…")
            } else {
                Text("Stopping…")
            }
        case .ready:
            HStack(spacing: 4) {
                Text(server.asleep ? "Sleeping" : "Running")
                    .help(server.asleep ? "It freed its memory while idle and loads again with the next message." : "")
                Text(verbatim: "· Port \(server.settings.port)")
                Button { state.copyAPIAddress() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy API Address: \(server.settings.url.appending(path: "v1").absoluteString)")
                    .accessibilityLabel("Copy API Address")
            }
        case .failed where server.running:
            Text("Not responding")
        case .failed where failedPicked:
            Text("Ran into a problem")
        default:
            Text("Not running")
        }
    }

    @ViewBuilder private var actions: some View {
        let server = state.server
        switch server.phase {
        case .stopped, .failed:
            Button(failedPicked ? "Try Again" : "Start") { if let model = state.selection { state.start(model) } }
                .buttonStyle(.borderedProminent)
                .disabled(state.selection == nil || !state.ready)
        case .starting:
            Button("Cancel") { state.stop() }
        case .stopping:
            if server.next != nil { Button("Cancel") { state.stop() } }
        case .ready:
            if let selection = state.selection, selection != server.model {
                Button("Stop") { state.stop() }
                Button("Switch to \(state.displayName(of: selection))") { state.start(selection) }
                    .buttonStyle(.borderedProminent)
            } else {
                AgentsPopup()
                Button("Stop") { state.stop() }
                if state.optionsChanged, let model = server.model {
                    Button("Restart to Apply") { state.start(model) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Open Chat") { state.section = .chat }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// What the model that runs has done since it started, in two rows of figures: requests, how fast
/// it answers and reads prompts on average, how soon an answer starts; the tokens it generated,
/// read and took from its cache, and the memory it holds.
private struct ActivityFigures: View {
    let activity: Server.Activity

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 14) {
            GridRow {
                figure(activity.served.formatted(), activity.running > 0 ? "Requests · \(activity.running) running" : "Requests")
                figure(rate(activity.generation), "Answering", help: "Average since the model started")
                figure(rate(activity.reading), "Reading prompts", help: "Average since the model started")
                figure(activity.firstToken.map { $0.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)) } ?? "–",
                       "To first token", help: "Median since the model started")
            }
            GridRow {
                figure(count(activity.generated), "Tokens generated")
                figure(count(activity.read), "Prompt tokens read")
                figure(count(activity.cached), "Tokens from cache", help: "Prompt tokens taken from earlier requests rather than read again")
                figure(activity.memory.map(Format.size) ?? "–", "Memory", help: "What the engine holds in memory now")
            }
        }
        .padding(.vertical, 6)
    }

    private func rate(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) tok/s" } ?? "–"
    }

    private func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func figure(_ value: String, _ caption: String, help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// The server's line for each request since it started, folded until opened, in a box of its own
/// that scrolls, following the latest.
private struct RequestLog: View {
    let lines: [String]
    @State var open = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
                Text("Request Log")
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        if open {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        Text("No requests yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 180)
            // From the top down, following the latest once the box is full.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}

/// The coding agents to open in Terminal on the model that runs, and its API address to copy.
private struct AgentsPopup: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false
    private static let copy = "copy"

    var body: some View {
        PopupMenu(header: "Open in Terminal",
                  items: Agent.allCases.map { PopupItem(id: $0.rawValue, title: $0.title) }
                      + [PopupItem(id: Self.copy, title: "Copy API Address", separated: true)],
                  chosen: nil, above: true) { choice in
            if let agent = Agent(rawValue: choice) {
                NSApp.activate()
                agent.open(runtime: state.runtime, settings: state.server.settings)
            } else {
                state.copyAPIAddress()
            }
        } label: {
            HStack(spacing: 4) {
                Text("Coding Agents")
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Open a coding agent in Terminal, connected to this model")
    }
}

/// A section's title, the same in every state of the screen.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.headline).foregroundStyle(.primary).textCase(nil)
    }
}

/// A start or a download that failed: why, in a line or three, with the log and a way out.
private struct ProblemRow: View {
    let title: String
    let message: String
    let log: URL
    let dismiss: () -> Void
    /// A way to try again, with its button's title.
    var retry: (title: String, action: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .help(message)
            }
            Spacer(minLength: 12)
            Button("Show Log") { NSWorkspace.shared.open(log) }
            if let retry { Button(retry.title, action: retry.action) }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let installer = state.installer
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading \(installer.model.map(state.displayName(of:)) ?? "")").font(.headline)
                Spacer()
                Button("Cancel") { installer.cancel() }
            }
            if let progress = installer.progress {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(caption).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    private var caption: String {
        let installer = state.installer
        guard let progress = installer.progress else { return "Preparing download…" }
        let amount = "\(Format.size(progress.done)) of \(Format.size(progress.total))"
        guard let remaining = installer.remaining else { return amount }
        if remaining < .seconds(60) { return "\(amount) — less than a minute left" }
        let time = remaining.formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1))
        return "\(amount) — about \(time) left"
    }
}

/// A model on this Mac, to pick for Start: its name, and under it its Hugging Face ID, which tells
/// its variants apart, and its size. The one the server runs says so.
private struct ModelRow: View {
    @Environment(AppState.self) private var state
    let model: InstalledModel

    var body: some View {
        let selected = state.selection == model.id
        Button { state.selection = model.id } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                    .opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.catalog.name(of: model.id))
                    Text("\(model.id) · \(Format.size(model.bytes))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let phase {
                    HStack(spacing: 6) {
                        if state.server.phase == .ready && state.server.model == model.id {
                            Circle().fill(.green).frame(width: 7, height: 7)
                        }
                        Text(phase)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.displayName(of: model.id))
        .accessibilityValue(phase ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(state.catalog.about(of: model.id) ?? model.id)
        .contextMenu {
            if model.local {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: model.id)]) }
                Button("Remove from List") { state.removeLocal(model.id) }
            } else {
                CopyModelID(id: model.id)
            }
        }
    }

    /// What the server does with this model, if anything.
    private var phase: String? {
        let server = state.server
        if server.next == model.id && server.model != model.id { return "Up next" }
        guard server.running, server.model == model.id else { return nil }
        switch server.phase {
        case .ready: return server.asleep ? "Sleeping" : "Running"
        case .starting: return "Loading…"
        case .stopping: return server.next == model.id ? "Restarting…" : "Stopping…"
        case .failed: return "Not responding"
        case .stopped: return nil
        }
    }
}

private struct SuggestedRow: View {
    @Environment(AppState.self) private var state
    let variant: Catalog.Variant
    let recommended: Bool
    let lead: Bool

    var body: some View {
        LabeledContent {
            Button("Download") { state.download(variant.id) }
                .disabled(state.installer.running || !state.ready)
                .help(state.installer.running ? "One download at a time" : "")
                .prominent(lead)
        } label: {
            Text(variant.name)
            Text(([recommended ? "Recommended" : nil, variant.about, Format.size(Format.gigabytes(variant.size))]
                as [String?]).compactMap { $0 }.joined(separator: " · "))
        }
        .help(variant.id)
        .contextMenu { CopyModelID(id: variant.id) }
    }
}

private struct CopyModelID: View {
    let id: String

    var body: some View {
        Button("Copy Model ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        }
    }
}

/// Downloads any model `splash serve --model` takes.
private struct CustomModelSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Model", text: $model, prompt: Text("owner/model or owner/model:variant"))
                    .monospaced()
                    .focused($focused)
                    .onSubmit(download)
            } header: {
                Text("Download Another Model").font(.headline)
            } footer: {
                Text("Any Hugging Face model Splash runs, such as unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { focused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Download", action: download).disabled(id == nil)
            }
        }
    }

    /// The model typed or pasted, its Hugging Face address too, if `splash serve --model` takes it
    /// (`serve_options.parse_model_id`'s rules).
    private var id: String? {
        let text = model.trimmingCharacters(in: .whitespaces).trimmingPrefix("https://huggingface.co/")
        guard let match = text.wholeMatch(of: /([A-Za-z0-9_](?:[A-Za-z0-9._-]*[A-Za-z0-9_])?\/[A-Za-z0-9_](?:[A-Za-z0-9._-]{0,94}[A-Za-z0-9_])?)(?::[A-Za-z0-9][A-Za-z0-9._-]{0,63})?/),
              !text.contains(".."), !match.1.contains("--"), !match.1.hasSuffix(".git")
        else { return nil }
        return String(text)
    }

    private func download() {
        guard let id else { return }
        state.download(id)
        dismiss()
    }
}

extension View {
    /// The screen's one prominent button, which Return presses.
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) } else { self }
    }
}
