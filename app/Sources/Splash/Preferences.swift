import Foundation

/// The keys of what the app keeps in UserDefaults, besides the launch options (`ServeSettings`).
enum Preference {
    /// The model picked on the Server screen, the one Start starts.
    static let model = "model"
    static let agentFolder = "agentFolder"
    static let effort = "effort"
    /// The server and the download the app runs, kept until they exit, to stop them on the next
    /// launch should the app quit without stopping them.
    static let serverPID = "serverPID"
    static let serverPort = "serverPort"
    static let installerPID = "installerPID"
}

/// How long a model's context may grow: the server fits it to memory on Auto.
enum ContextLength: String, CaseIterable, Identifiable {
    case auto, k16 = "16K", k32 = "32K", k64 = "64K", k128 = "128K", k256 = "256K"

    var id: String { rawValue }
    var title: String { self == .auto ? "Auto" : "\(rawValue) tokens" }
}

/// When the engine gives a model's memory back while nobody uses it; the next message loads the
/// model again.
enum IdleRelease: String, CaseIterable, Identifiable {
    case tenMinutes = "10m", oneHour = "1h", never = "off"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tenMinutes: "After 10 Minutes"
        case .oneHour: "After 1 Hour"
        case .never: "Never"
        }
    }
}

/// How the engine stores the attention cache.
enum KVFormat: String, CaseIterable, Identifiable {
    case int8, bf16

    var id: String { rawValue }
    var title: String { self == .int8 ? "8-bit" : "16-bit" }
}

/// How the engine stores a hybrid model's recurrent state.
enum StateFormat: String, CaseIterable, Identifiable {
    case fp32, bf16

    var id: String { rawValue }
    var title: String { self == .fp32 ? "32-bit" : "16-bit" }
}

/// What the cache of earlier prompts may take on the SSD: Auto follows the volume's free space.
enum SSDCache: String, CaseIterable, Identifiable {
    case auto, off = "0", g16 = "16G", g32 = "32G", g64 = "64G"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        default: "\(rawValue.dropLast()) GB"
        }
    }
}

/// How a model starts: `splash serve` on `port`, offline (the app downloads models itself), with
/// the launch options that differ from the server's defaults. Each option has a key of its own in
/// UserDefaults; one that is missing or invalid there is the default.
struct ServeSettings: Equatable {
    static let defaultPort = 8000

    var port = defaultPort
    var context = ContextLength.auto
    /// The most memory the engine may plan for, in GB; nil for all it can have.
    var memoryLimit: Int?
    var idleRelease = IdleRelease.tenMinutes
    var kvFormat = KVFormat.int8
    var stateFormat = StateFormat.fp32
    var ssdCache = SSDCache.auto
    /// Whether the SSD cache outlives the server.
    var keepSSDCache = false
    var neuralEngine = true
    /// Whether the Mac stays awake while the model answers.
    var keepAwake = true

    private enum Key {
        static let port = "port", context = "context", memoryLimit = "memoryLimit", idleRelease = "idleRelease"
        static let kvFormat = "kvFormat", stateFormat = "stateFormat", ssdCache = "ssdCache"
        static let keepSSDCache = "keepSSDCache", neuralEngine = "neuralEngine", keepAwake = "keepAwake"
    }

    static func current(_ defaults: UserDefaults = .standard) -> ServeSettings {
        var settings = ServeSettings()
        if let port = defaults.object(forKey: Key.port) as? Int, (1...65535).contains(port) { settings.port = port }
        settings.context = defaults.string(forKey: Key.context).flatMap(ContextLength.init) ?? .auto
        settings.memoryLimit = (defaults.object(forKey: Key.memoryLimit) as? Int).flatMap { $0 > 0 ? $0 : nil }
        settings.idleRelease = defaults.string(forKey: Key.idleRelease).flatMap(IdleRelease.init) ?? .tenMinutes
        settings.kvFormat = defaults.string(forKey: Key.kvFormat).flatMap(KVFormat.init) ?? .int8
        settings.stateFormat = defaults.string(forKey: Key.stateFormat).flatMap(StateFormat.init) ?? .fp32
        settings.ssdCache = defaults.string(forKey: Key.ssdCache).flatMap(SSDCache.init) ?? .auto
        settings.keepSSDCache = defaults.object(forKey: Key.keepSSDCache) as? Bool ?? false
        settings.neuralEngine = defaults.object(forKey: Key.neuralEngine) as? Bool ?? true
        settings.keepAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(port, forKey: Key.port)
        defaults.set(context.rawValue, forKey: Key.context)
        defaults.set(memoryLimit, forKey: Key.memoryLimit)
        defaults.set(idleRelease.rawValue, forKey: Key.idleRelease)
        defaults.set(kvFormat.rawValue, forKey: Key.kvFormat)
        defaults.set(stateFormat.rawValue, forKey: Key.stateFormat)
        defaults.set(ssdCache.rawValue, forKey: Key.ssdCache)
        defaults.set(keepSSDCache, forKey: Key.keepSSDCache)
        defaults.set(neuralEngine, forKey: Key.neuralEngine)
        defaults.set(keepAwake, forKey: Key.keepAwake)
    }

    /// The memory limits to choose from on a Mac with `memory` GB, below what it has, and `kept`,
    /// the one chosen before, if it is another.
    static func memoryLimits(memory: Int, kept: Int?) -> [Int] {
        let sizes = [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384].filter { $0 < memory }
        return Set(sizes + [kept].compactMap { $0 }).sorted()
    }

    func serveArguments(model: String) -> [String] {
        var arguments = ["serve", "--model", model, "--port", String(port), "--offline"]
        if context != .auto { arguments += ["--max-context", context.rawValue] }
        if let memoryLimit { arguments += ["--max-memory", "\(memoryLimit)G"] }
        if idleRelease != .tenMinutes { arguments += ["--idle-release", idleRelease.rawValue] }
        if kvFormat != .int8 { arguments += ["--kv-format", kvFormat.rawValue] }
        if stateFormat != .fp32 { arguments += ["--state-format", stateFormat.rawValue] }
        if ssdCache != .auto { arguments += ["--max-cache-disk", ssdCache.rawValue] }
        if keepSSDCache && ssdCache != .off { arguments.append("--persistent-cache") }
        if !neuralEngine { arguments.append("--disable-ane") }
        if !keepAwake { arguments.append("--allow-idle-sleep") }
        return arguments
    }

    /// The server's address: it listens on the loopback address, where the app's chat, health and
    /// status requests go.
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
}
