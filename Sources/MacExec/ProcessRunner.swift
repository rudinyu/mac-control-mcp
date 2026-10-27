import Foundation

struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let truncated: Bool
    let durationMs: Int
}

struct SpawnFailure: Error, CustomStringConvertible {
    let description: String
}

// Collects up to `limit` bytes of a pipe and drains the rest, so a chatty command can neither
// fill memory nor block on a full pipe.
private final class CappedBuffer {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private(set) var truncated = false
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - data.count
        if chunk.count > room { truncated = true }
        if room > 0 { data.append(chunk.prefix(room)) }
    }

    func markEnded() {
        lock.lock(); defer { lock.unlock() }
        ended = true
    }

    var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private func readPipe(_ fd: Int32, into buffer: CappedBuffer) -> FileHandle {
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    handle.readabilityHandler = { handle in
        let chunk = handle.availableData
        // An empty read means end of file; stop, or the handler would fire again forever.
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            buffer.markEnded()
        } else {
            buffer.append(chunk)
        }
    }
    return handle
}

// Waits up to `seconds` for the process to exit, without reaping it. While the exited leader is
// not reaped, its process group ID stays reserved, so signalling the group cannot reach a
// different group that reused the ID.
private func waitForExitWithoutReaping(_ pid: pid_t, seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0, info.si_pid == pid { return true }
        if result == -1, errno != EINTR { return true } // ECHILD: nothing left to wait for
        usleep(20_000)
    } while Date() < deadline
    return false
}

// Runs a program without a terminal or standard input, in a new process group. There is no working
// folder option, because the spawn call for one differs between macOS SDKs; change folders in the command.
// When the program ends, or when the timeout passes, its whole process group is killed, so nothing it
// started keeps running unless it moved itself to another group. `onTimeout` runs first on a timeout,
// for example to kill a container.
func runProcess(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                timeout: TimeInterval, outputLimit: Int, onTimeout: (() -> Void)? = nil) throws -> RunResult {
    var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
    guard pipe(&outPipe) == 0 else { throw SpawnFailure(description: "Could not create a pipe.") }
    guard pipe(&errPipe) == 0 else {
        close(outPipe[0]); close(outPipe[1])
        throw SpawnFailure(description: "Could not create a pipe.")
    }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
    // A new process group lets one signal reach every process the command starts. Closing every
    // other descriptor by default keeps the server's own pipes out of the command.
    let setup = [
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1),
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2),
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
        posix_spawnattr_setpgroup(&attributes, 0),
    ]
    let env = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = env.map { strdup($0) } + [nil]
    defer { (argv + envp).forEach { free($0) } }

    var pid: pid_t = 0
    var spawned = setup.first { $0 != 0 } ?? 0
    if spawned == 0, argv.dropLast().contains(where: { $0 == nil }) || envp.dropLast().contains(where: { $0 == nil }) {
        spawned = ENOMEM
    }
    if spawned == 0 { spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp) }
    close(outPipe[1]); close(errPipe[1])
    guard spawned == 0 else {
        close(outPipe[0]); close(errPipe[0])
        throw SpawnFailure(description: "Could not start \(executable): \(String(cString: strerror(spawned))).")
    }

    let stdout = CappedBuffer(limit: outputLimit), stderr = CappedBuffer(limit: outputLimit)
    let outHandle = readPipe(outPipe[0], into: stdout), errHandle = readPipe(errPipe[0], into: stderr)
    let started = Date()

    var timedOut = false
    if !waitForExitWithoutReaping(pid, seconds: timeout) {
        timedOut = true
        onTimeout?()
        kill(-pid, SIGTERM)
        _ = waitForExitWithoutReaping(pid, seconds: 2)
    }
    // The leader has exited or is about to be killed, and is not reaped yet, so the group ID is still
    // ours. This also ends background processes the command left behind.
    kill(-pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}

    // Every writer is gone, so both pipes reach end of file soon; wait for that, with a limit in
    // case a process escaped the group and still holds a pipe open.
    let drainDeadline = Date().addingTimeInterval(2)
    while !(stdout.isEnded && stderr.isEnded), Date() < drainDeadline { usleep(10_000) }
    outHandle.readabilityHandler = nil
    errHandle.readabilityHandler = nil

    let exitCode: Int32
    if status & 0x7f == 0 { exitCode = (status >> 8) & 0xff } // exited normally
    else { exitCode = 128 + (status & 0x7f) }                 // ended by a signal
    return RunResult(exitCode: exitCode, stdout: stdout.text, stderr: stderr.text,
                     timedOut: timedOut, truncated: stdout.truncated || stderr.truncated,
                     durationMs: Int(Date().timeIntervalSince(started) * 1000))
}
