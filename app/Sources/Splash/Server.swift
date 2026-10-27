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
    /// The start to make once the model stopping has stopped.
    private var queued: (model: String, settings: ServeSettings)?
    /// The options of the model starting, served or last failed.
    private(set) var settings = ServeSettings()
    /// Once ready: whether the engine has given the weights back while idle.
    private(set) var asleep = false
    /// Once ready: whether the model takes images.
    private(set) var acceptsImages = false
    /// Once ready: what a reasoning effort does to the model.
    private(set) var reasoning: Reasoning?
    /// Once ready: the work the server reports, as its status gives it.
    private(set) var activity = Activity()

    /// The server's work since it started, from `/status`: requests served and running, the speed
    /// of answers and of reading prompts in tokens a second, the median time to an answer's first
    /// token, the memory the engine holds, and the context it serves.
    struct Activity: Equatable {
        var served = 0
        var running = 0
        var generation: Double?
        var reading: Double?
        var firstToken: Duration?
        var memory: Int64?
        var context: Int?
    }

    /// What a reasoning effort does to the served model, as `/v1/models` reports it from its
    /// template.
    struct Reasoning: Decodable, Equatable {
        /// Whether a message that asks for no effort makes the model think; nil for a model that
        /// decides itself.
        var thinks: Bool?
        /// The efforts besides none the model tells apart, least first; none where its thinking
        /// is only on or off.
        var efforts: [String]
        /// The one of them a message that asks for no effort gets.
        var `default`: String?
    }

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

    /// The model to start once the one stopping has stopped: another one, or the same one again.
    var next: String? { queued?.model }

    /// Starts installed `model` with `settings`, stopping the one being served first.
    func start(_ model: String, settings: ServeSettings) {
        if child != nil {
            stop()
            queued = (model, settings)
        } else {
            launch(model, settings: settings)
        }
    }

    /// Stops the model, and drops a switch to another one: SIGINT to the process group, as Ctrl+C
    /// sends; a second one after 10 s, on which the server stops the engine at once; SIGKILL if
    /// anything still runs 20 s later.
    func stop() {
        queued = nil
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

    private func launch(_ model: String, settings: ServeSettings) {
        self.model = model
        self.settings = settings
        asleep = false
        activity = Activity()
        acceptsImages = false
        reasoning = nil
        firstError = nil
        stopRequested = false
        resetLog(Self.log)
        if portInUse(settings.port) {
            return refuse("Port \(settings.port) is in use by another app. Quit that app, or choose another port in Launch Options › Advanced.")
        }
        phase = .starting
        do {
            child = try ChildProcess(
                command: runtime.command(settings.serveArguments(model: model)),
                environment: runtime.environment.merging(settings.environment) { $1 },
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
        if let queued {
            self.queued = nil
            launch(queued.model, settings: queued.settings)
        } else if stopRequested {
            phase = .stopped
        } else if phase == .starting, let firstError, let model {
            phase = .failed(Self.memoryProblem(firstError, settings: settings) ?? plainProblem(firstError, model: model))
        } else {
            phase = .failed("It stopped unexpectedly. The log has the details.")
        }
    }

    /// A start the engine refuses for want of memory, in the words of the launch options: the
    /// model, with its reserves, needs more than the budget, the memory limit set or this Mac's own;
    /// or the context length set is more than the memory left, or the SSD cache, holds.
    nonisolated static func memoryProblem(_ message: String, settings: ServeSettings) -> String? {
        if let match = message.firstMatch(of: /require (\d+) bytes but the Metal memory budget is (\d+) bytes/),
           let need = Int64(match.1), let budget = Int64(match.2) {
            let size = { (bytes: Int64) in
                "\((Double(bytes) / Double(1 << 30)).formatted(.number.precision(.fractionLength(0...1)))) GB"
            }
            if let limit = settings.memoryLimit, Int64(limit) << 30 == budget {
                return "It needs \(size(need)) of memory but the memory limit is \(size(budget)). Raise the memory limit in Launch Options."
            }
            return "It needs \(size(need)) of memory but this Mac can give it \(size(budget)). Choose a smaller model."
        }
        if let match = message.firstMatch(of: /exceeds the (\d+) tokens the model and (.+) allow/), let most = Int(match.1) {
            let tokens = most >= 1024 ? "\(most / 1024)K" : "\(most)"
            if match.2.contains("--max-memory") {
                return "Its context fits up to \(tokens) tokens within the memory limit. Choose a shorter context length, or raise the memory limit."
            }
            if match.2.contains("SSD cache") {
                return "Its context fits up to \(tokens) tokens in the SSD cache. Choose a shorter context length, or a larger SSD cache."
            }
            return "Its context fits up to \(tokens) tokens on this Mac. Choose a shorter context length, or Auto."
        }
        return nil
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
                let served = await servedModel()
                acceptsImages = served?.input_modalities?.contains("image") ?? false
                reasoning = served?.reasoning
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // The status, unless the server was started with an API key it asks for.
        while !Task.isCancelled, phase == .ready {
            if let status = await status(), phase == .ready { apply(status) }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func apply(_ status: Status) {
        asleep = status.weights?.released ?? false
        let metrics = status.metrics
        activity = Activity(
            served: status.requests?.completed ?? 0,
            running: status.active_requests?.count ?? 0,
            generation: metrics?.decode_tokens_per_second.flatMap { $0 > 0 ? $0 : nil },
            reading: metrics?.prefill_tokens_per_second.flatMap { $0 > 0 ? $0 : nil },
            firstToken: metrics?.ttft_ms?.p50.flatMap { $0 > 0 ? .milliseconds($0) : nil },
            memory: status.memory_actual?.current_bytes,
            context: status.maximum_context_tokens
        )
        if status.transport?.stopped == true {
            // The engine failed again and again; the server stays up but serves nothing.
            phase = .failed(status.transport?.error ?? "It stopped after failing repeatedly.")
        }
    }

    private struct Status: Decodable {
        struct Weights: Decodable { let released: Bool? }
        struct Transport: Decodable { let stopped: Bool?; let error: String? }
        struct Requests: Decodable { let completed: Int? }
        struct Request: Decodable {}
        struct Metrics: Decodable {
            struct Percentiles: Decodable { let p50: Double? }
            let decode_tokens_per_second: Double?
            let prefill_tokens_per_second: Double?
            let ttft_ms: Percentiles?
        }
        struct Memory: Decodable { let current_bytes: Int64? }
        let weights: Weights?
        let transport: Transport?
        let requests: Requests?
        let active_requests: [Request]?
        let metrics: Metrics?
        let memory_actual: Memory?
        let maximum_context_tokens: Int?
    }

    private struct ServedModel: Decodable {
        /// Text, and images and PDFs with vision.
        let input_modalities: [String]?
        let reasoning: Reasoning?
    }

    private func servedModel() async -> ServedModel? {
        struct Models: Decodable { let data: [ServedModel] }
        guard let (data, _) = try? await URLSession.shared.data(for: settings.request("v1/models")),
              let models = try? JSONDecoder().decode(Models.self, from: data)
        else { return nil }
        return models.data.first
    }

    private func status() async -> Status? {
        var request = settings.request("status")
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}
