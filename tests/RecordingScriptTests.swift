// Unit tests for the script that runs and times a recording. Built with Sources/MacControl/RecordingScript.swift by
// scripts/ci.sh. This program also stands in for screencapture: started with "fake-recorder", it records until
// SIGINT and then writes to the file it is given, as screencapture without -V does.

import Foundation

private var failures = 0

private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    print(passed ? "ok   \(name)" : "FAIL \(name) \(detail())")
    if !passed { failures += 1 }
}

private var fakeFile = ""

// Waits $FAKE_START_DELAY seconds before handling SIGINT, like a recorder that is still starting, and exits 3 at
// once for a file named "fail". A program the script starts in the background begins with SIGINT ignored; this
// sets its own handler, as screencapture does.
private func fakeRecorder(_ arguments: [String]) -> Never {
    fakeFile = arguments.last ?? ""
    if (fakeFile as NSString).lastPathComponent == "fail" { exit(3) }
    if let delay = ProcessInfo.processInfo.environment["FAKE_START_DELAY"].flatMap(Double.init) {
        usleep(useconds_t(delay * 1_000_000))
    }
    signal(SIGINT) { _ in
        FileManager.default.createFile(atPath: fakeFile, contents: Data("stopped by SIGINT".utf8))
        exit(0)
    }
    while true { pause() }
}

private struct Run {
    let status: Int32
    let seconds: Double
    let file: String?
}

@main
private enum RecordingScriptTests {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "fake-recorder" { fakeRecorder(arguments) }
        let me = Bundle.main.executableURL!.path
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-script-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The script passes "-x -m -v file" to $1, so a one-line wrapper adds the mode.
        let recorder = folder.appendingPathComponent("fake-recorder")
        try! "#!/bin/sh\nexec \"\(me)\" fake-recorder \"$@\"\n".write(to: recorder, atomically: true, encoding: .utf8)
        chmod(recorder.path, 0o755)

        func record(_ name: String, limit: Int, signal: Int32? = nil, after delay: Double = 0.5, startDelay: Double? = nil) -> Run {
            let file = folder.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", recordingScript, "mac-control-recording", recorder.path, file.path, String(limit)]
            var environment = ProcessInfo.processInfo.environment
            if let startDelay { environment["FAKE_START_DELAY"] = String(startDelay) }
            process.environment = environment
            let start = Date()
            try! process.run()
            if let signal {
                usleep(useconds_t(delay * 1_000_000))
                kill(process.processIdentifier, signal)
            }
            process.waitUntilExit()
            return Run(status: process.terminationStatus, seconds: Date().timeIntervalSince(start),
                       file: try? String(contentsOf: file, encoding: .utf8))
        }

        // Times allow a slow machine several seconds; a recording that is not stopped would run for 60.
        let timed = record("timed", limit: 1)
        check("the time limit stops the recording with SIGINT", timed.file == "stopped by SIGINT" && timed.status == 0, "\(timed)")
        check("at the limit", timed.seconds >= 0.9 && timed.seconds < 10, "\(timed)")

        for (name, signal) in [("SIGINT", SIGINT), ("SIGTERM", SIGTERM), ("SIGHUP", SIGHUP)] {
            let stopped = record("stopped-\(name)", limit: 60, signal: signal)
            check("\(name) to the script stops the recording with SIGINT, so it keeps the file",
                  stopped.file == "stopped by SIGINT" && stopped.status == 0, "\(stopped)")
            check("\(name) stops it at once, not at the limit", stopped.seconds < 10, "\(stopped)")
        }

        let starting = record("starting", limit: 60, signal: SIGINT, after: 0.1, startDelay: 1)
        check("a recorder still starting when asked to stop is stopped once it can be",
              starting.file == "stopped by SIGINT" && starting.seconds < 10, "\(starting)")
        // A signal that arrives before the script's first line, which sets the traps, ends the shell before it
        // starts the recorder, so nothing is left recording.
        let early = record("early", limit: 60, signal: SIGINT, after: 0)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", folder.appendingPathComponent("early").path]
        pgrep.standardOutput = FileHandle.nullDevice
        try! pgrep.run()
        pgrep.waitUntilExit()
        check("a stop as the script starts ends it at once, with no recorder left running",
              early.seconds < 10 && pgrep.terminationStatus == 1, "\(early)")

        let failed = record("fail", limit: 60)
        check("the recorder's exit status is the script's", failed.status == 3, "\(failed)")
        check("a recorder that ends by itself ends the script at once", failed.seconds < 10, "\(failed)")

        if failures > 0 {
            print("\(failures) recording script test(s) failed")
            exit(1)
        }
        print("All recording script tests passed")
    }
}
