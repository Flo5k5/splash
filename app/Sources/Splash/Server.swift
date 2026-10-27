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
    private(set) var settings = ServeSettings()
    /// The latest line the server printed, which tells what a start is doing.
    private(set) var latest = ""
    /// Once ready: the context window the engine sized.
    private(set) var contextTokens: Int?
    /// Once ready: whether the engine has given the weights back while idle.
    private(set) var asleep = false
    /// Once ready: requests being answered.
    private(set) var activeRequests = 0
    /// Counts the starts that reached Ready, so the chat page reloads for each.
    private(set) var generation = 0

    static let log = URL.libraryDirectory.appending(path: "Logs/Splash/server.log")

    private let runtime: Runtime
    private var child: ChildProcess?
    private var tail: LogTail?
    private var next: String?
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

    /// Stops the server this app started before it quit or crashed, if it still serves, and waits
    /// until it has given its port and memory back.
    func stopLeftover() async {
        let defaults = UserDefaults.standard
        let pid = pid_t(defaults.integer(forKey: Preference.serverPID))
        let port = defaults.integer(forKey: Preference.serverPort)
        defaults.removeObject(forKey: Preference.serverPID)
        guard pid > 0, runtime.serveLockOwner(port: port) == pid, runtime.runsPython(pid) else { return }
        killpg(pid, SIGINT)
        for tick in 1...300 where kill(pid, 0) == 0 {
            if tick == 200 { killpg(pid, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func launch(_ model: String) {
        self.model = model
        settings = .current()
        phase = .starting
        latest = "Starting \(model)…"
        firstError = nil
        contextTokens = nil
        asleep = false
        activeRequests = 0
        stopRequested = false
        UserDefaults.standard.set(model, forKey: Preference.lastModel)
        UserDefaults.standard.set(false, forKey: Preference.lastModelServed)
        resetLog(Self.log)
        do {
            child = try ChildProcess(
                command: runtime.command(settings.serveArguments(model: model)),
                environment: runtime.environment,
                log: Self.log,
                exited: { [weak self] in self?.exited($0) }
            )
        } catch {
            phase = .failed("Splash could not start: \(error.localizedDescription)")
            return
        }
        tail = LogTail(Self.log) { [weak self] in self?.received($0) }
        let pid = child!.pid
        UserDefaults.standard.set(Int(pid), forKey: Preference.serverPID)
        UserDefaults.standard.set(settings.port, forKey: Preference.serverPort)
        watch = Task { [weak self] in await self?.follow(pid) }
    }

    private func received(_ line: String) {
        latest = line
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
        } else if phase == .starting, let firstError {
            phase = .failed(firstError)
        } else {
            phase = .failed("Splash stopped unexpectedly (exit status \(status)); its log tells why.")
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
               !Task.isCancelled, phase == .starting {
                phase = .ready
                generation += 1
                UserDefaults.standard.set(true, forKey: Preference.lastModelServed)
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
        contextTokens = status.maximum_context_tokens ?? contextTokens
        asleep = status.weights?.released ?? false
        activeRequests = status.http?.requests?.active ?? 0
        if status.transport?.stopped == true {
            // The engine failed again and again; the server stays up but serves nothing.
            phase = .failed(status.transport?.error ?? "The model stopped after repeated failures.")
        }
    }

    private struct Status: Decodable {
        struct Weights: Decodable { let released: Bool? }
        struct Transport: Decodable { let stopped: Bool?; let error: String? }
        struct HTTP: Decodable {
            struct Requests: Decodable { let active: Int? }
            let requests: Requests?
        }
        let maximum_context_tokens: Int?
        let weights: Weights?
        let transport: Transport?
        let http: HTTP?
    }

    private func status() async -> Status? {
        var request = URLRequest(url: settings.url.appending(path: "status"))
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}
