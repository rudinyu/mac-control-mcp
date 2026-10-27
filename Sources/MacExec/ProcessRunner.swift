import Foundation

struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let truncated: Bool
    let durationMs: Int
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

// Runs a program without a terminal or standard input. When the timeout passes, `onTimeout` runs
// (for example to kill a container) and the process is terminated.
func runProcess(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil,
                timeout: TimeInterval, outputLimit: Int, onTimeout: (() -> Void)? = nil) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let stdout = CappedBuffer(limit: outputLimit), stderr = CappedBuffer(limit: outputLimit)
    out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
    err.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

    let started = Date()
    try process.run()
    let deadline = started.addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning {
        if Date() >= deadline {
            timedOut = true
            onTimeout?()
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning, Date() < grace { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            break
        }
        usleep(20_000)
    }
    process.waitUntilExit()
    // Let the handlers take the last output. Reading to end of file instead would hang if the command
    // left a background child holding the pipe open.
    usleep(100_000)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    return RunResult(exitCode: process.terminationStatus, stdout: stdout.text, stderr: stderr.text,
                     timedOut: timedOut, truncated: stdout.truncated || stderr.truncated,
                     durationMs: Int(Date().timeIntervalSince(started) * 1000))
}
