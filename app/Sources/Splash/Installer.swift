import Darwin
import Foundation
import Observation

/// Downloads and installs models, one at a time, with the installer `splash serve` runs before it
/// serves. A model can download while another one serves.
@MainActor @Observable
final class Installer {
    /// What the installer reports while it downloads one repository: the model's, after its draft's.
    struct Progress: Equatable {
        let repo: String
        let done: Int64
        let total: Int64

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

        /// The progress a line of the installer's output reports, if it is a download event.
        init?(line: String) {
            struct Event: Decodable {
                let event: String
                let repo: String
                let done: Int64
                let total: Int64
            }
            guard line.hasPrefix("{"),
                  let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)),
                  event.event == "download"
            else { return nil }
            (repo, done, total) = (event.repo, event.done, event.total)
        }
    }

    /// The model installing.
    private(set) var model: String?
    /// The download under way, if the installer is downloading.
    private(set) var progress: Progress?
    /// The latest line the installer printed.
    private(set) var latest = ""
    /// The last installation that failed: its model and why.
    private(set) var failure: (model: String, message: String)?

    static let log = URL.libraryDirectory.appending(path: "Logs/Splash/install.log")

    /// Gets each model once it is installed.
    @ObservationIgnored var installed: (String) -> Void = { _ in }

    private let runtime: Runtime
    private var child: ChildProcess?
    private var tail: LogTail?
    private var cancelled = false
    private var firstError: String?
    private var activity: NSObjectProtocol?

    init(runtime: Runtime) {
        self.runtime = runtime
    }

    var running: Bool { child != nil }

    func install(_ model: String) {
        guard child == nil else { return }
        self.model = model
        progress = nil
        latest = "Preparing \(model)…"
        failure = nil
        firstError = nil
        cancelled = false
        resetLog(Self.log)
        do {
            child = try ChildProcess(
                command: runtime.installCommand(model),
                environment: runtime.environment,
                log: Self.log,
                exited: { [weak self] in self?.exited($0) }
            )
        } catch {
            failure = (model, "The download could not start: \(error.localizedDescription)")
            self.model = nil
            return
        }
        tail = LogTail(Self.log) { [weak self] in self?.received($0) }
        // A download takes long; the Mac must not sleep through it.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading \(model)")
    }

    /// Stops the download: SIGINT, as Ctrl+C sends, then SIGKILL if it is still running 5 s later.
    /// The installer removes what a killed download left behind the next time it downloads.
    func cancel() {
        guard let child else { return }
        cancelled = true
        child.signal(SIGINT)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.child === child { child.signal(SIGKILL) }
        }
    }

    private func received(_ line: String) {
        if let progress = Progress(line: line) {
            self.progress = progress
            if progress.done == 0 { checkSpace(progress) }
            return
        }
        latest = line
        if firstError == nil { firstError = errorMessage(line) }
    }

    /// Stops a download the disk has no room for, before it fills the disk. macOS frees purgeable
    /// space as it is needed, so what counts is the capacity for important use.
    private func checkSpace(_ progress: Progress) {
        let cache = URL.homeDirectory.appending(path: ".cache")
        guard let available = try? cache.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
            progress.total > available, let model
        else { return }
        cancel()
        failure = (model, "Not enough disk space: the download needs \(Format.bytes(progress.total)), "
            + "and \(Format.bytes(available)) is available.")
    }

    private func exited(_ status: Int32) {
        tail?.finish()
        tail = nil
        child = nil
        activity.map(ProcessInfo.processInfo.endActivity)
        activity = nil
        let model = self.model!
        self.model = nil
        progress = nil
        if status == 0 {
            installed(model)
        } else if !cancelled {
            failure = (model, firstError ?? "The download failed (exit status \(status)).")
        }
    }
}
