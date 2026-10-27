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
    private(set) var truncated = false
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - data.count
        if chunk.count > room { truncated = true }
        if room > 0 { data.append(chunk.prefix(room)) }
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
        if chunk.isEmpty { handle.readabilityHandler = nil } else { buffer.append(chunk) }
    }
    return handle
}

// Runs a program without a terminal or standard input, in a new process group. There is no working
// folder option, because the spawn call for one differs between macOS SDKs; change folders in the command.
// When the program ends, or when the timeout passes, the whole group is killed, so nothing it started keeps running.
// `onTimeout` runs first on a timeout, for example to kill a container.
func runProcess(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                timeout: TimeInterval, outputLimit: Int, onTimeout: (() -> Void)? = nil) throws -> RunResult {
    var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw SpawnFailure(description: "Could not create pipes.") }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // A new process group lets a timeout signal every process the command starts. Closing every
    // other descriptor by default keeps the server's own pipes out of the command.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)

    let env = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = env.map { strdup($0) } + [nil]
    defer { (argv + envp).forEach { free($0) } }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
    close(outPipe[1]); close(errPipe[1])
    guard spawned == 0 else {
        close(outPipe[0]); close(errPipe[0])
        throw SpawnFailure(description: "Could not start \(executable): \(String(cString: strerror(spawned))).")
    }

    let stdout = CappedBuffer(limit: outputLimit), stderr = CappedBuffer(limit: outputLimit)
    let outHandle = readPipe(outPipe[0], into: stdout), errHandle = readPipe(errPipe[0], into: stderr)
    let started = Date()
    let deadline = started.addingTimeInterval(timeout)
    var status: Int32 = 0
    var timedOut = false
    var exited = false
    while !exited {
        if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }
        if Date() >= deadline {
            timedOut = true
            onTimeout?()
            kill(-pid, SIGTERM)
            let grace = Date().addingTimeInterval(2)
            while Date() < grace, waitpid(pid, &status, WNOHANG) != pid { usleep(50_000) }
            kill(-pid, SIGKILL)
            waitpid(pid, &status, 0)
            exited = true
            break
        }
        usleep(20_000)
    }
    // Background processes the command left behind still belong to its group.
    kill(-pid, SIGKILL)
    // Let the handlers take the last output, then stop reading.
    usleep(100_000)
    outHandle.readabilityHandler = nil
    errHandle.readabilityHandler = nil

    let exitCode: Int32
    if status & 0x7f == 0 { exitCode = (status >> 8) & 0xff } // exited normally
    else { exitCode = 128 + (status & 0x7f) }                 // ended by a signal
    return RunResult(exitCode: exitCode, stdout: stdout.text, stderr: stderr.text,
                     timedOut: timedOut, truncated: stdout.truncated || stderr.truncated,
                     durationMs: Int(Date().timeIntervalSince(started) * 1000))
}
