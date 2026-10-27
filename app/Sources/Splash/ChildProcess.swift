import Darwin
import Foundation

/// A program run as a terminal runs a foreground job: in a process group of its own, so a signal
/// reaches it and every program it starts (the installer, the engine), the way Ctrl+C does. Its
/// output goes to a log file rather than a pipe, so it never waits on this app, and keeps working
/// if the app quits or crashes.
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    private let exitSource: DispatchSourceProcess

    /// Starts `command` with `environment`, standard input from /dev/null and standard output and
    /// error appended to `log`. `exited` gets the exit status, as a shell reports it, on the main
    /// queue once the program has ended.
    init(
        command: [String],
        environment: [String: String],
        log: URL,
        exited: @escaping @MainActor (Int32) -> Void
    ) throws {
        let output = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(output) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group; no descriptor but 0-2 inherited; default signal handling and an
        // empty signal mask, whatever this app set for itself.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, command[0], &actions, &attributes, argv, envp)
        guard status == 0 else { throw POSIXError(.init(rawValue: status) ?? .EIO) }
        self.pid = pid

        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [exitSource] in
            exitSource.cancel()
            // The event can come just before the program can be reaped, and comes once: wait for
            // it, which takes no time now that it has ended.
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            let code = reaped != pid ? -1 : (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            MainActor.assumeIsolated { exited(code) }
        }
        exitSource.resume()
    }

    /// Sends `signal` to the program's process group.
    func signal(_ signal: Int32) {
        killpg(pid, signal)
    }
}

/// Follows a log file as it grows, one call per complete line, on the main queue.
@MainActor
final class LogTail {
    private let handle: FileHandle
    private let source: DispatchSourceFileSystemObject
    private let line: (String) -> Void
    private var pending = Data()

    init?(_ url: URL, line: @escaping (String) -> Void) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        self.line = line
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.extend, .write], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        // The source watches the descriptor until it is cancelled, so only then is it closed.
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    /// Reads what the file holds now, the last line too if it lacks its newline, and stops.
    func finish() {
        read()
        if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
        source.cancel()
    }

    private func read() {
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        pending.append(data)
        while let end = pending.firstIndex(of: 0x0A) {
            let text = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...end)
            if !text.isEmpty { line(text) }
        }
    }
}

/// Creates `url` empty, with its folder, for a run's log.
func resetLog(_ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
}

/// The message of an error line, without its prefix: `error: ...` from the launcher, installer
/// and engine, `HH:MM:SS Error · ...` from the server, `PROGRAM: error: ...` from an argument
/// parser refusing its command line.
func errorMessage(_ line: String) -> String? {
    line.firstMatch(of: /^(?:error: |\d\d:\d\d:\d\d Error · |[\w.\- ]+: error: )(.+)/).map { String($0.1) }
}
