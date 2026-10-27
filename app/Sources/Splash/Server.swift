import Darwin
import Foundation
import Observation

/// The one `splash serve` this app runs. It starts an installed model, follows it to Ready, stops
/// it as Ctrl+C would, and switches models by stopping one and starting the next.
@MainActor @Observable
final class Server {
    enum Phase: Equatable {
        case stopped, starting, ready, stopping
        case failed(String)
    }

    private(set) var phase = Phase.stopped
    /// The model starting, served or last failed.
    private(set) var model: String?
    /// The model to start once the one stopping has stopped.
    private(set) var next: String?
    private(set) var settings = ServeSettings()
    /// Once ready: whether the engine has given the weights back while idle.
    private(set) var asleep = false
    /// Once ready: whether the model takes images.
    private(set) var acceptsImages = false

    static let log = URL.libraryDirectory.appending(path: "Logs/Splash/server.log")

    private let runtime: Runtime
    private var child: ChildProcess?
    private var tail: LogTail?
    private var stopRequested = false
    private var firstError: String?
    private var watch: Task<Void, Never>?

    init(runtime: Runtime) {
        self.runtime = runtime
    }

    var running: Bool { child != nil }

    /// Starts installed `model`, stopping the one being served first.
    func start(_ model: String) {
        if child != nil {
            stop()
            next = model
        } else {
            launch(model)
        }
    }

    /// Stops the model, and drops a switch to another one: SIGINT to the process group, as Ctrl+C
    /// sends; a second one after 10 s, on which the server stops the engine at once; SIGKILL if
    /// anything still runs 20 s later.
    func stop() {
        next = nil
        guard let child, phase != .stopping else { return }
        stopRequested = true
        phase = .stopping
        watch?.cancel()
        child.signal(SIGINT)
        Task { [weak self] in
            for (delay, signal) in [(10, SIGINT), (20, SIGKILL)] {
                try? await Task.sleep(for: .seconds(delay))
                guard self?.child === child else { return }
                child.signal(signal)
            }
        }
    }

    /// Clears a failure the user has read, stopping a server that still runs but serves nothing.
    func dismissFailure() {
        guard case .failed = phase else { return }
        if child != nil { stop() } else { phase = .stopped }
    }

    /// Stops the server this app started before it quit or crashed, if it still serves, and waits
    /// until it has given its port and memory back.
    func stopLeftover() async {
        let defaults = UserDefaults.standard
        let pid = pid_t(defaults.integer(forKey: Preference.serverPID))
        let port = defaults.integer(forKey: Preference.serverPort)
        defaults.removeObject(forKey: Preference.serverPID)
        guard pid > 0, runtime.serveLockOwner(port: port) == pid, runtime.runsPython(pid) else { return }
        await stopProcessGroup(pid)
    }

    private func launch(_ model: String) {
        self.model = model
        settings = .current()
        asleep = false
        acceptsImages = false
        firstError = nil
        stopRequested = false
        resetLog(Self.log)
        if let option = settings.reservedOption {
            return refuse("The server options in Settings can’t include \(option): Splash sets it itself.")
        }
        if portInUse(settings.port) {
            return refuse("Port \(settings.port) is in use by another app. Choose another port in Settings › Advanced.")
        }
        phase = .starting
        do {
            child = try ChildProcess(
                command: runtime.command(settings.serveArguments(model: model)),
                environment: runtime.environment,
                log: Self.log,
                exited: { [weak self] in self?.exited($0) }
            )
        } catch {
            phase = .failed("Splash couldn’t start it: \(error.localizedDescription)")
            return
        }
        tail = LogTail(Self.log) { [weak self] in self?.received($0) }
        let pid = child!.pid
        UserDefaults.standard.set(Int(pid), forKey: Preference.serverPID)
        UserDefaults.standard.set(settings.port, forKey: Preference.serverPort)
        watch = Task { [weak self] in await self?.follow(pid) }
    }

    /// Fails a start before it runs anything, saying why in the log too.
    private func refuse(_ message: String) {
        try? Data((message + "\n").utf8).write(to: Self.log)
        phase = .failed(message)
    }

    private func received(_ line: String) {
        // Why a start fails; once serving, error lines are about requests.
        if phase == .starting, firstError == nil { firstError = errorMessage(line) }
    }

    private func exited(_ status: Int32) {
        tail?.finish()
        tail = nil
        child = nil
        watch?.cancel()
        UserDefaults.standard.removeObject(forKey: Preference.serverPID)
        if let model = next {
            next = nil
            launch(model)
        } else if stopRequested {
            phase = .stopped
        } else if phase == .starting, let firstError, let model {
            phase = .failed(plainProblem(firstError, model: model))
        } else {
            phase = .failed("It stopped unexpectedly. The log has the details.")
        }
    }

    /// Waits until this start's server answers, then follows its status. The port's lock names the
    /// process serving it, and the server answers only once ready.
    private func follow(_ pid: pid_t) async {
        let health = settings.url.appending(path: "health")
        while !Task.isCancelled, phase == .starting {
            if runtime.serveLockOwner(port: settings.port) == pid,
               let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200,
               !Task.isCancelled, phase == .starting, let model {
                phase = .ready
                // The model to start when Splash next opens, until the user stops it.
                UserDefaults.standard.set(model, forKey: Preference.lastModel)
                UserDefaults.standard.set(true, forKey: Preference.resume)
                acceptsImages = await inputModalities().contains("image")
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // The status, unless the server was started with an API key it asks for.
        while !Task.isCancelled, phase == .ready {
            if let status = await status(), phase == .ready { apply(status) }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func apply(_ status: Status) {
        asleep = status.weights?.released ?? false
        if status.transport?.stopped == true {
            // The engine failed again and again; the server stays up but serves nothing.
            phase = .failed(status.transport?.error ?? "It stopped after failing repeatedly.")
        }
    }

    private struct Status: Decodable {
        struct Weights: Decodable { let released: Bool? }
        struct Transport: Decodable { let stopped: Bool?; let error: String? }
        let weights: Weights?
        let transport: Transport?
    }

    /// What the served model takes: text, and images and PDFs with vision.
    private func inputModalities() async -> [String] {
        struct Models: Decodable {
            struct Model: Decodable { let input_modalities: [String]? }
            let data: [Model]
        }
        guard let (data, _) = try? await URLSession.shared.data(from: settings.url.appending(path: "v1/models")),
              let models = try? JSONDecoder().decode(Models.self, from: data)
        else { return [] }
        return models.data.first?.input_modalities ?? []
    }

    private func status() async -> Status? {
        var request = URLRequest(url: settings.url.appending(path: "status"))
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}
