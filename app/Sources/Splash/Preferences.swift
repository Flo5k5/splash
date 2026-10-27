import Foundation

/// The app's settings, kept in UserDefaults. Views bind to the same keys with @AppStorage; a model
/// reads them when it starts, so a change applies on the next start.
enum Preference {
    static let port = "port"
    static let idleRelease = "idleRelease"
    static let serveOptions = "serveOptions"
    static let startOnOpen = "startOnOpen"
    /// The model last started, and whether it reached Ready: only such a model starts on open.
    static let lastModel = "lastModel"
    static let lastModelServed = "lastModelServed"
    static let agentFolder = "agentFolder"
    /// The server the app runs, kept until it exits, to stop it on the next launch should the app
    /// quit without stopping it.
    static let serverPID = "serverPID"
    static let serverPort = "serverPort"

    static let defaultPort = 8000

    static func register() {
        UserDefaults.standard.register(defaults: [
            port: defaultPort,
            idleRelease: IdleRelease.tenMinutes.rawValue,
            serveOptions: "",
            startOnOpen: true,
        ])
    }
}

/// When the engine gives a model's memory back while nobody uses it; the next message loads the
/// model again.
enum IdleRelease: String, CaseIterable, Identifiable {
    case tenMinutes = "10m", oneHour = "1h", never = "off"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tenMinutes: "After 10 minutes"
        case .oneHour: "After 1 hour"
        case .never: "Never"
        }
    }
}

/// What a model starts with: `splash serve` on `port`, offline (the app downloads models itself),
/// with the settings that differ from its defaults.
struct ServeSettings: Equatable {
    var port = Preference.defaultPort
    var idleRelease = IdleRelease.tenMinutes
    /// More `splash serve` options, as typed in Settings.
    var options = ""

    static func current(_ defaults: UserDefaults = .standard) -> ServeSettings {
        let port = defaults.integer(forKey: Preference.port)
        return ServeSettings(
            port: (1...65535).contains(port) ? port : Preference.defaultPort,
            idleRelease: IdleRelease(rawValue: defaults.string(forKey: Preference.idleRelease) ?? "") ?? .tenMinutes,
            options: defaults.string(forKey: Preference.serveOptions) ?? ""
        )
    }

    func serveArguments(model: String) -> [String] {
        var arguments = ["serve", "--model", model, "--port", String(port), "--offline"]
        if idleRelease != .tenMinutes { arguments += ["--idle-release", idleRelease.rawValue] }
        return arguments + options.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The server's address. Always the loopback address and this port, so the chat page keeps one
    /// origin, and with it its saved chats.
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
}
