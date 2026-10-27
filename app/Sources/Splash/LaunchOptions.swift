import SwiftUI

/// How a model starts: every `splash serve` option of `LaunchOption.all`, the main ones in a card
/// and the others under Advanced, by their part. Each is on Auto or the server's own default until
/// changed; a change applies the next time a model starts.
struct LaunchOptions: View {
    @Environment(AppState.self) private var state
    @State var advanced = false
    /// Brings the Advanced options into view once they open.
    var reveal: () -> Void = {}

    /// The Advanced row's ID, to scroll to.
    static let advancedID = "advanced"

    var body: some View {
        Section {
            ForEach(Self.options(.main)) { OptionRow(option: $0) }
            Button {
                withAnimation(.smooth(duration: 0.2)) { advanced.toggle() }
                // Once the options are laid out under the row.
                if advanced { Task { reveal() } }
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
            .id(Self.advancedID)
        } header: {
            SectionTitle(text: LaunchOption.Section.main.rawValue)
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
        if advanced {
            ForEach(LaunchOption.Section.allCases.dropFirst(), id: \.self) { section in
                Section {
                    ForEach(Self.options(section)) { OptionRow(option: $0) }
                } header: {
                    Text(section.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
                }
            }
        }
    }

    private static func options(_ section: LaunchOption.Section) -> [LaunchOption] {
        LaunchOption.all.filter { $0.section == section }
    }
}

/// One launch option, with the control its kind takes; dimmed where the others leave it no effect.
private struct OptionRow: View {
    @Environment(AppState.self) private var state
    let option: LaunchOption

    var body: some View {
        @Bindable var state = state
        let value = Binding(get: { state.options[option.flag] }, set: { state.options[option.flag] = $0 })
        Group {
            switch option.kind {
            case .toggle(let on):
                Toggle(option.title, isOn: Binding(get: { (value.wrappedValue == "true") == on },
                                                    set: { value.wrappedValue = $0 == on ? "true" : nil }))
            case .choice(let standard, let choices, let custom):
                ChoicePicker(title: option.title, standard: standard, choices: choices, custom: custom, value: value)
            case .text(let custom, _):
                TextRow(title: option.title, custom: custom, value: value)
            case .folder:
                FolderRow(title: option.title, value: value)
            case .secret:
                SecretRow(title: option.title, value: $state.options.apiKey)
            }
        }
        .help(option.help)
        .disabled(!option.applies(state.options))
    }
}

/// A menu of the server's default, the choices, the value set, and Custom… to type another.
private struct ChoicePicker: View {
    let title: String
    let standard: String
    let choices: [(value: String, title: String)]
    let custom: LaunchOption.Value?
    @Binding var value: String?
    @State private var typing = false

    /// The tag of Custom…, which is no value.
    private static let other = "\u{0}custom"

    var body: some View {
        Picker(title, selection: Binding(get: { value }, set: { choice in
            if choice == Self.other { typing = true } else { value = choice }
        })) {
            Text(standard).tag(String?.none)
            ForEach(choices, id: \.value) { Text($0.title).tag(Optional($0.value)) }
            if let value, let custom, !choices.contains(where: { $0.value == value }) {
                Text(custom.title(value)).tag(Optional(value))
            }
            if custom != nil {
                Divider()
                Text("Custom…").tag(Optional(Self.other))
            }
        }
        .sheet(isPresented: $typing) {
            if let custom {
                CustomValueSheet(title: title, custom: custom, initial: value.map(custom.text) ?? "") { value = $0 }
            }
        }
    }
}

/// A value typed in a field, kept once it is one the option takes; empty for the default.
private struct TextRow: View {
    let title: String
    let custom: LaunchOption.Value
    @Binding var value: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(custom.prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240)
                .focused($focused)
                .onSubmit(commit)
        }
        .onAppear { text = value.map(custom.text) ?? "" }
        .onChange(of: value) { text = value.map(custom.text) ?? "" }
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            value = nil
        } else if let parsed = custom.parse(text) {
            value = parsed
        }
        text = value.map(custom.text) ?? ""
    }
}

/// A folder picked, or the server's default.
private struct FolderRow: View {
    let title: String
    @Binding var value: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(value.map { URL(filePath: $0).lastPathComponent } ?? "Default")
                    .foregroundStyle(.secondary)
                    .help(value ?? "")
                if value != nil { Button("Default") { value = nil } }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { value = url.path }
                }
            }
        }
    }
}

/// The API key, typed in a secure field; empty for none.
private struct SecretRow: View {
    let title: String
    @Binding var value: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            SecureField(title, text: $text, prompt: Text("None"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .focused($focused)
                .onSubmit(commit)
        }
        .onAppear { text = value ?? "" }
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        value = text.isEmpty ? nil : text
    }
}

/// Asks for a value the menu doesn't offer.
private struct CustomValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let custom: LaunchOption.Value
    let initial: String
    let set: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(title, text: $text, prompt: Text(custom.prompt))
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(done)
            } header: {
                Text(title).font(.headline)
            } footer: {
                Text(custom.message)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear {
            text = initial
            focused = true
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Set", action: done).disabled(custom.parse(text) == nil)
            }
        }
    }

    private func done() {
        guard let value = custom.parse(text) else { return }
        set(value)
        dismiss()
    }
}
