import SwiftUI

/// The models: what failed or downloads, the models on this Mac to start, and the suggested ones
/// it can run to download. The window's welcome before a model is on this Mac, and a sheet over
/// the chat after.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @State private var customModel = false

    /// The one action the screen leads with, also bound to Return; none while a model runs.
    enum Lead: Equatable { case retry(String), start(String), download(String) }

    var body: some View {
        let suggestions = state.catalog.suggestions(memory: Catalog.memory)
        let installedNames = Set(state.installed.map { state.catalog.name(of: $0.id) })
        let available = suggestions.filter { !installedNames.contains($0.name) && $0.id != state.installer.model }
        let lead = lead(suggestions)
        Form {
            Section {
                if case .failed(let message) = state.server.phase, let model = state.server.model {
                    ProblemRow(title: "\(state.displayName(of: model)) ran into a problem", message: message,
                               log: Server.log, lead: lead == .retry(model), retry: { state.start(model) },
                               dismiss: state.server.dismissFailure)
                }
                if let failure = state.installer.failure {
                    ProblemRow(title: "\(state.displayName(of: failure.model)) couldn’t download",
                               message: failure.message, log: Installer.log, lead: lead == .retry(failure.model),
                               retry: { state.download(failure.model) }, dismiss: state.installer.dismissFailure)
                }
                if state.installer.running { DownloadRow() }
            } header: {
                header
            }
            if !state.installed.isEmpty {
                Section {
                    ForEach(state.installed) { InstalledRow(model: $0, lead: lead == .start($0.id)) }
                } header: {
                    SectionTitle(text: "On This Mac")
                }
            }
            Section {
                ForEach(available, id: \.id) { variant in
                    SuggestedRow(variant: variant, recommended: variant == suggestions.first,
                                 lead: lead == .download(variant.id))
                }
            } header: {
                if !available.isEmpty { SectionTitle(text: "Available to Download") }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if suggestions.isEmpty, let minimum = state.catalog.minimumMemory {
                        Text("The suggested models need a Mac with at least \(minimum) GB of memory; this one has \(Catalog.memory) GB.")
                    } else {
                        Text("Suggested for this Mac’s \(Catalog.memory) GB of memory. Models download from Hugging Face.")
                    }
                    Button("Download Another Model…") { customModel = true }
                        .buttonStyle(.link)
                        .disabled(state.installer.running || !state.ready)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refresh() }
        .sheet(isPresented: $customModel) { CustomModelSheet() }
    }

    private var header: some View {
        let (title, subtitle) = state.installed.isEmpty
            ? ("Welcome to Splash", "Splash runs AI models privately on this Mac. Download one to start chatting.")
            : state.server.running
            ? ("Models", "Switch to another model, or download one. Models run privately on this Mac.")
            : ("Choose a Model", "Start a model to chat with it. Models run privately on this Mac.")
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func lead(_ suggestions: [Catalog.Variant]) -> Lead? {
        let server = state.server
        guard !server.running else { return nil }
        if case .failed = server.phase, let model = server.model { return .retry(model) }
        if let failure = state.installer.failure { return .retry(failure.model) }
        if let last = state.lastModel { return .start(last) }
        if state.installed.isEmpty, !state.installer.running, let first = suggestions.first {
            return .download(first.id)
        }
        return nil
    }
}

/// A section's title, the same in every state of the screen.
private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.headline).foregroundStyle(.primary).textCase(nil)
    }
}

private struct ProblemRow: View {
    let title: String
    let message: String
    let log: URL
    let lead: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .help(message)
            HStack {
                Spacer()
                Button("Show Log") { NSWorkspace.shared.open(log) }
                Button("Try Again", action: retry).prominent(lead)
            }
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

private struct InstalledRow: View {
    @Environment(AppState.self) private var state
    let model: InstalledModel
    let lead: Bool

    var body: some View {
        let server = state.server
        LabeledContent {
            if server.model == model.id && server.running {
                Text(phase).foregroundStyle(.secondary)
                Button("Stop") { state.stop() }.disabled(server.phase == .stopping)
            } else {
                Button("Start") { state.start(model.id) }.disabled(!state.ready).prominent(lead)
            }
        } label: {
            Text(state.displayName(of: model.id))
            Text([state.catalog.about(of: model.id), Format.size(model.bytes)].compactMap { $0 }.joined(separator: " · "))
        }
        .help(model.id)
        .contextMenu { CopyModelID(id: model.id) }
    }

    private var phase: String {
        switch state.server.phase {
        case .ready: state.server.asleep ? "Sleeping" : "Running"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .failed: "Not responding"
        case .stopped: ""
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

/// The models over the chat.
struct ModelsSheet: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ModelsView()
            .frame(width: 560, height: 600)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { state.showingModels = false }
                }
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
