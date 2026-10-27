import AppKit

/// The coding agents `splash` connects to the model being served. Each is a terminal program, so
/// the app opens Terminal in a project folder running `splash AGENT --port PORT`, which finds the
/// agent on the shell's PATH and tells how to install it when it is missing.
enum Agent: String, CaseIterable, Identifiable {
    case claude, codex, opencode, hermes, pi

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .hermes: "Hermes"
        case .pi: "Pi"
        }
    }

    /// Asks for the project folder, then opens the agent there in Terminal.
    @MainActor
    func open(runtime: Runtime, settings: ServeSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open \(title)"
        panel.message = "Choose the project folder \(title) works in."
        if let folder = UserDefaults.standard.url(forKey: Preference.agentFolder) {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set(folder, forKey: Preference.agentFolder)
        let script = script(runtime: runtime, port: settings.port, folder: folder, apiKey: settings.apiKey != nil)
        do {
            let directory = FileManager.default.temporaryDirectory.appending(path: "Splash")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "\(rawValue).command")
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The Terminal script that runs the agent in `folder`; with `apiKey`, it reads the server's key
    /// from the Keychain as it runs, so that the key is never written to a file.
    func script(runtime: Runtime, port: Int, folder: URL, apiKey: Bool = false) -> String {
        let key = apiKey ? "export SPLASH_API_KEY=\"$(security find-generic-password -s Splash -a 'API key' -w)\"\n" : ""
        return """
        #!/bin/sh
        cd \(Self.quoted(folder.path)) || exit
        \(key)clear
        exec \(runtime.command([rawValue, "--port", String(port)]).map(Self.quoted).joined(separator: " "))

        """
    }

    private static func quoted(_ word: String) -> String {
        "'" + word.replacing("'", with: #"'\''"#) + "'"
    }
}
