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
    @State private var hovering = false

    /// The items' IDs of the default and of Custom…, which are no values.
    private static let none = "\u{0}default", other = "\u{0}custom"

    var body: some View {
        // A value typed in before, which the choices don't hold.
        let typed = value.flatMap { value in
            choices.contains { $0.value == value } ? nil : custom.map { PopupItem(id: value, title: $0.title(value)) }
        }
        let items = [PopupItem(id: Self.none, title: standard, badge: "Default")]
            + choices.map { PopupItem(id: $0.value, title: $0.title) }
            + [typed].compactMap { $0 }
            + (custom == nil ? [] : [PopupItem(id: Self.other, title: "Custom…", separated: true)])
        LabeledContent(title) {
            PopupMenu(header: title, items: items, chosen: value ?? Self.none) { choice in
                if choice == Self.other { typing = true } else { value = choice == Self.none ? nil : choice }
            } label: {
                HStack(spacing: 5) {
                    Text(items.first { $0.id == (value ?? Self.none) }?.title ?? standard)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(hovering ? 1 : 0.6), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .onHover { hovering = $0 }
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
