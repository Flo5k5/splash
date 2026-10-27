import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Preference.idleRelease) private var idleRelease = IdleRelease.tenMinutes
    @AppStorage(Preference.startOnOpen) private var startOnOpen = true
    @AppStorage(Preference.port) private var port = Preference.defaultPort
    @AppStorage(Preference.serveOptions) private var serveOptions = ""
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: Error?
    @State var advanced = false

    var body: some View {
        Form {
            Section {
                Picker("Free memory when idle", selection: $idleRelease) {
                    ForEach(IdleRelease.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Start the last model when Splash opens", isOn: $startOnOpen)
                Toggle("Open Splash at login", isOn: Binding(
                    get: { login == .enabled || login == .requiresApproval },
                    // A closure, not the method: Swift 6.3's compiler crashes on the method's thunk.
                    set: { setLogin($0) }
                ))
                if login == .requiresApproval {
                    LabeledContent("Splash needs your approval to open at login.") {
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } footer: {
                Text("An idle model sleeps: it frees its memory and wakes with your next message.")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .monospacedDigit()
                        .onChange(of: port) { old, new in if !(1...65535).contains(new) { port = old } }
                    LabeledContent("Server options") {
                        TextField("Server options", text: $serveOptions, prompt: Text("None"))
                            .labelsHidden()
                            .monospaced()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("API address") {
                        HStack {
                            Text(verbatim: "http://127.0.0.1:\(port)/v1").monospaced().textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("http://127.0.0.1:\(port)/v1", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy API Address")
                        }
                    }
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Couldn’t Change Login Items", isPresented: Binding(
            get: { loginError != nil }, set: { if !$0 { loginError = nil } }
        )) {} message: {
            Text(loginError?.localizedDescription ?? "")
        }
    }

    private var note: String {
        if let option = ServeSettings(options: serveOptions).reservedOption {
            return "Leave out \(option): Splash sets it itself. Server options are flags for splash serve, such as --max-context 128K."
        }
        return "Server options are flags for splash serve, such as --max-context 128K. Changes apply the next time a model starts."
    }

    private func setLogin(_ enabled: Bool) {
        do {
            try enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            loginError = error
        }
        login = SMAppService.mainApp.status
    }
}
