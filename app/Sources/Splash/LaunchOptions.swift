import SwiftUI

/// How a model starts: the `splash serve` options worth changing, each on Auto or the server's own
/// default until changed. A change applies the next time a model starts.
struct LaunchOptions: View {
    @Environment(AppState.self) private var state
    @State var advanced = false

    var body: some View {
        @Bindable var state = state
        Section {
            Picker("Context length", selection: $state.options.context) {
                ForEach(ContextLength.allCases) { Text($0.title).tag($0) }
            }
            .help("How much of a conversation the model keeps in mind. Auto fits it to this Mac’s memory.")
            Picker("Memory limit", selection: $state.options.memoryLimit) {
                Text("Auto").tag(Int?.none)
                ForEach(ServeSettings.memoryLimits(memory: Catalog.memory, kept: state.options.memoryLimit), id: \.self) {
                    Text("\($0) GB").tag(Int?.some($0))
                }
            }
            .help("The most memory the model may use, to leave room for other apps. Auto gives it what this Mac can.")
            Picker("Free memory when idle", selection: $state.options.idleRelease) {
                ForEach(IdleRelease.allCases) { Text($0.title).tag($0) }
            }
            .help("An idle model frees its memory and loads again with the next message.")
            Button {
                withAnimation(.smooth(duration: 0.2)) { advanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(advanced ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Advanced")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(advanced ? "Expanded" : "Collapsed")
            if advanced {
                LabeledContent("Port") {
                    TextField("Port", value: $state.options.port, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                }
                .help("Where other apps reach the model: http://127.0.0.1:\(String(state.options.port))/v1")
                .onChange(of: state.options.port) { old, new in
                    if !(1...65535).contains(new) { state.options.port = old }
                }
                Picker("KV cache", selection: $state.options.kvFormat) {
                    ForEach(KVFormat.allCases) { Text($0.title).tag($0) }
                }
                .help("How the model keeps what it has read. 16-bit takes twice the memory.")
                Picker("Recurrent state", selection: $state.options.stateFormat) {
                    ForEach(StateFormat.allCases) { Text($0.title).tag($0) }
                }
                .help("How a hybrid model such as Qwen3.6 keeps its state. 16-bit takes half the memory.")
                Picker("SSD cache", selection: $state.options.ssdCache) {
                    ForEach(SSDCache.allCases) { Text($0.title).tag($0) }
                }
                .help("Room on the SSD for earlier prompts, so a long conversation goes on without reading it again. Auto follows the free space.")
                Toggle("Keep SSD cache after stopping", isOn: $state.options.keepSSDCache)
                    .disabled(state.options.ssdCache == .off)
                    .help("The next start of the model goes on from the prompts it kept.")
                Toggle("Neural Engine for long prompts", isOn: $state.options.neuralEngine)
                    .help("Reads long prompts faster on models that can use it.")
                Toggle("Keep Mac awake while answering", isOn: $state.options.keepAwake)
                    .help("The Mac doesn’t sleep in the middle of an answer; the display still may.")
            }
        } header: {
            SectionTitle(text: "Launch Options")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text("Options on Auto fit themselves to this Mac. Changes apply the next time a model starts.")
                Spacer()
                if state.options != ServeSettings() {
                    Button("Restore Defaults") { state.options = ServeSettings() }
                        .buttonStyle(.link)
                }
            }
        }
    }
}
