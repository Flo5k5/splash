import SwiftUI

/// The models on this Mac, to start, and the suggested ones it can run, to download.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @State private var customModel = false

    var body: some View {
        let suggestions = state.catalog.suggestions(memory: Catalog.memory)
        let available = suggestions.filter { !state.isInstalled($0.id) }
        Form {
            if state.installer.running || state.installer.failure != nil {
                Section { DownloadStatus() }
            }
            if !state.installed.isEmpty {
                Section("On This Mac") {
                    ForEach(state.installed) { InstalledRow(model: $0) }
                }
            }
            Section {
                ForEach(available, id: \.id) { variant in
                    SuggestedRow(variant: variant, recommended: variant == suggestions.first)
                }
                Button("Download Another Model…") { customModel = true }
                    .disabled(state.installer.running)
            } header: {
                Text(state.installed.isEmpty ? "Choose a Model to Download" : "More Models")
            } footer: {
                if suggestions.isEmpty, let minimum = state.catalog.minimumMemory {
                    Text("The suggested models need a Mac with at least \(minimum) GB of memory; this one has \(Catalog.memory) GB.")
                } else {
                    Text("Suggested for this Mac’s \(Catalog.memory) GB of memory. Models download from Hugging Face.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refresh() }
        .sheet(isPresented: $customModel) { CustomModelSheet() }
    }
}

private struct InstalledRow: View {
    @Environment(AppState.self) private var state
    let model: InstalledModel

    var body: some View {
        let server = state.server
        let current = server.model == model.id && server.running
        LabeledContent {
            if current {
                Text(server.phase == .ready ? "Running" : server.phase == .stopping ? "Stopping…" : "Starting…")
                    .foregroundStyle(.secondary)
                Button("Stop") { server.stop() }.disabled(server.phase == .stopping)
            } else {
                Button("Start") { state.start(model.id) }.disabled(state.blocker != nil)
            }
        } label: {
            Text(state.catalog.name(of: model.id))
            Text("\(model.id) · \(Format.bytes(model.bytes))")
        }
    }
}

private struct SuggestedRow: View {
    @Environment(AppState.self) private var state
    let variant: Catalog.Variant
    let recommended: Bool

    var body: some View {
        LabeledContent {
            if state.installer.model == variant.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") { state.installer.install(variant.id) }
                    .disabled(state.installer.running || state.blocker != nil)
            }
        } label: {
            HStack {
                Text(variant.name)
                if recommended {
                    Text("Recommended")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
            Text(variant.id)
        }
    }
}

/// The download under way, or the last one that failed.
private struct DownloadStatus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let installer = state.installer
        if let model = installer.model {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading \(state.catalog.name(of: model))").font(.headline)
                    Spacer()
                    Button("Cancel") { installer.cancel() }
                }
                if let progress = installer.progress {
                    ProgressView(value: progress.fraction)
                    Text("\(Format.bytes(progress.done)) of \(Format.bytes(progress.total))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView()
                    Text(installer.latest).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        } else if let failure = installer.failure {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(state.catalog.name(of: failure.model)) did not download",
                      systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(failure.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Show Log") { NSWorkspace.shared.open(Installer.log) }
                    Button("Try Again") { installer.install(failure.model) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Downloads any model `splash serve --model` takes.
private struct CustomModelSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""

    var body: some View {
        Form {
            Section {
                TextField("Model", text: $model, prompt: Text("owner/repo or owner/repo:VARIANT"))
                    .onSubmit(download)
            } footer: {
                Text("A Hugging Face repository of a model family Splash runs, as `splash serve --model` takes it, such as unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Download", action: download).disabled(!valid)
            }
        }
    }

    private var valid: Bool {
        model.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(:[A-Za-z0-9._-]+)?/) != nil
    }

    private func download() {
        guard valid else { return }
        state.installer.install(model)
        dismiss()
    }
}
