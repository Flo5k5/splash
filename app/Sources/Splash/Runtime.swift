import Foundation

/// The Splash runtime the app runs: the packaged release tree inside the app bundle, or, for
/// development, the tree `SPLASH_RUNTIME` names (a packaged tree or a source checkout). Its layout
/// and data folders are the ones `install/paths.py` resolves.
struct Runtime: Sendable {
    let root: URL

    static func locate() -> Runtime? {
        let candidates = [
            ProcessInfo.processInfo.environment["SPLASH_RUNTIME"].map { URL(filePath: $0) },
            Bundle.main.resourceURL?.appending(path: "splash"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "install/launcher.py").path) }
            .map(Runtime.init)
    }

    /// Whether this is a packaged tree (`release.json`) rather than a source checkout.
    var packaged: Bool { FileManager.default.fileExists(atPath: root.appending(path: "release.json").path) }

    var python: URL { root.appending(path: packaged ? "python/bin/python3" : ".venv/bin/python") }
    var engine: URL { root.appending(path: packaged ? "engine/splash" : "build/splash") }
    var suggestedModels: URL { root.appending(path: "install/suggested-models.tsv") }

    private var data: URL { packaged ? URL.applicationSupportDirectory.appending(path: "Splash") : root }
    /// Where installed models' selection links live.
    var models: URL { data.appending(path: packaged ? "models" : "install/models") }
    /// Where `splash serve` keeps its locks.
    var locks: URL { packaged ? data.appending(path: "runtime") : root.appending(path: "build/runtime") }

    /// The command line of `splash ARGUMENTS`. Isolated from the user's Python settings and
    /// site-packages, and never writing bytecode into the signed bundle.
    func command(_ arguments: [String]) -> [String] {
        [python.path, "-I", "-B", "-u", root.appending(path: "install/launcher.py").path] + arguments
    }

    /// The command line that downloads and installs `model`, the installer `splash serve` runs
    /// before it serves, reporting download progress as JSON lines.
    func installCommand(_ model: String) -> [String] {
        [python.path, "-I", "-B", "-u", root.appending(path: "install/models.py").path,
         "--model", model, "prepare", "--json-progress"]
    }

    /// The environment of the programs the app runs: the app's own (an app does not get the shell's),
    /// kept from writing bytecode and from the user's site-packages in the programs Python starts.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.removeValue(forKey: "SPLASH_RUNTIME")
        return environment
    }

    /// The models installed here: each selection link's assembly record names its model.
    func installedModels() -> [InstalledModel] {
        struct Record: Decodable {
            struct File: Decodable { let bytes: Int64 }
            let model: String
            let files: [String: File]
        }
        let manager = FileManager.default
        let owners = (try? manager.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? []
        return owners.filter { !$0.lastPathComponent.hasPrefix(".") }
            .flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .compactMap { link in
                guard let data = try? Data(contentsOf: link.appending(path: "model.json")),
                      let record = try? JSONDecoder().decode(Record.self, from: data)
                else { return nil }
                return InstalledModel(id: record.model, bytes: record.files.values.reduce(0) { $0 + $1.bytes })
            }
            .sorted { $0.id < $1.id }
    }

    /// The process serving `port`, as `splash serve` records it in the port's lock: it holds the
    /// lock from before it checks the port until it exits, so a server answering the port is it.
    func serveLockOwner(port: Int) -> pid_t? {
        struct Owner: Decodable { let pid: Int32 }
        guard let data = try? Data(contentsOf: locks.appending(path: "serve-\(port).lock")) else { return nil }
        return (try? JSONDecoder().decode(Owner.self, from: data))?.pid
    }

    /// Whether `pid` runs this runtime's Python.
    func runsPython(_ pid: pid_t) -> Bool {
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return false }
        return URL(filePath: String(decoding: path.prefix(Int(length)), as: UTF8.self)).resolvingSymlinksInPath()
            == python.resolvingSymlinksInPath()
    }

    /// Why this Mac cannot run Splash, or nil when it can: the engine's own check, which the
    /// launcher repeats before every start.
    func unsupportedReason() -> String? {
        let process = Process()
        process.executableURL = engine
        process.arguments = ["device-check"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(decoding: message, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(#/^error: /#, with: "")
    }
}

struct InstalledModel: Identifiable, Hashable {
    let id: String
    /// What its files take on disk, shared with any other installation of the same files.
    let bytes: Int64
}
