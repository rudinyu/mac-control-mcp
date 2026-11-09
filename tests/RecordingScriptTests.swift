// Unit tests for the script that runs and times a recording. Built with Sources/MacControl/RecordingScript.swift by
// scripts/ci.sh. A fake recorder stands in for screencapture: it writes how it was stopped to the file it is given.

import Foundation

private var failures = 0

private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    print(passed ? "ok   \(name)" : "FAIL \(name) \(detail())")
    if !passed { failures += 1 }
}

// Records until SIGINT, like screencapture without -V. It sets its own handler, as screencapture does, since a
// program the script starts in the background begins with SIGINT ignored. With "fail", it exits 3 at once.
private let fakeRecorder = """
#!/usr/bin/env python3
import signal, sys, time
path = sys.argv[-1]
if "fail" in path:
    sys.exit(3)
def stop(number, frame):
    open(path, "w").write("stopped by " + signal.Signals(number).name)
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
while True:
    time.sleep(0.05)
"""

private struct Run {
    let status: Int32
    let seconds: Double
    let file: String?
}

@main
private enum RecordingScriptTests {
    static func main() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-script-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = folder.appendingPathComponent("fake-recorder")
        try! fakeRecorder.write(to: recorder, atomically: true, encoding: .utf8)
        chmod(recorder.path, 0o755)

        // A limit no other test or program uses, so the timer's sleep can be looked for afterwards.
        let longLimit = "\(Int.random(in: 400...499))"
        func record(_ name: String, limit: String, signal: Int32? = nil, after delay: Double = 0.5) -> Run {
            let file = folder.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", recordingScript, "mac-control-recording", recorder.path, file.path, limit]
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

        let timed = record("timed", limit: "1")
        check("the time limit stops the recording with SIGINT", timed.file == "stopped by SIGINT", "\(timed)")
        check("at the limit", timed.status == 0 && timed.seconds >= 1 && timed.seconds < 3, "\(timed)")

        for (name, signal) in [("SIGINT", SIGINT), ("SIGTERM", SIGTERM), ("SIGHUP", SIGHUP)] {
            let stopped = record("stopped-\(name)", limit: longLimit, signal: signal)
            check("\(name) to the script stops the recording with SIGINT, so it keeps the file",
                  stopped.file == "stopped by SIGINT" && stopped.status == 0, "\(stopped)")
            check("\(name) stops it at once, not at the limit", stopped.seconds < 3, "\(stopped)")
        }

        let failed = record("fail", limit: longLimit)
        check("the recorder's exit status is the script's", failed.status == 3, "\(failed)")
        check("a recorder that ends by itself ends the script at once", failed.seconds < 3, "\(failed)")

        usleep(300_000)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "^sleep \(longLimit)$"]
        pgrep.standardOutput = FileHandle.nullDevice
        try! pgrep.run()
        pgrep.waitUntilExit()
        check("no timer is left behind", pgrep.terminationStatus == 1)

        if failures > 0 {
            print("\(failures) recording script test(s) failed")
            exit(1)
        }
        print("All recording script tests passed")
    }
}
