// Unit tests for sessionInputBlockReason. Built with Sources/SessionLock.swift by scripts/ci.sh.

import Foundation

private var failures = 0

private func check(_ name: String, _ session: [String: Any]?, blocked expected: String?) {
    let reason = sessionInputBlockReason(session)
    let passed = expected.map { reason?.contains($0) == true } ?? (reason == nil)
    if passed {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\n     expected: \(expected ?? "not blocked")\n     actual:   \(reason ?? "not blocked")")
    }
}

@main
private enum SessionLockTests {
    static func main() {
        let unlocked: [String: Any] = ["kCGSSessionOnConsoleKey": NSNumber(value: 1), "kCGSessionLoginDoneKey": NSNumber(value: 1)]
        check("unlocked console session", unlocked, blocked: nil)
        check("no session", nil, blocked: "No macOS login session")

        var locked = unlocked
        locked["CGSSessionScreenIsLocked"] = NSNumber(value: 1)
        check("locked screen", locked, blocked: "screen is locked")

        var unlockedFlag = unlocked
        unlockedFlag["CGSSessionScreenIsLocked"] = NSNumber(value: 0)
        check("lock flag present but false", unlockedFlag, blocked: nil)

        var switchedAway = unlocked
        switchedAway["kCGSSessionOnConsoleKey"] = NSNumber(value: 0)
        check("another user on the display", switchedAway, blocked: "fast user switching")

        var lockedAndAway = switchedAway
        lockedAndAway["CGSSessionScreenIsLocked"] = NSNumber(value: 1)
        check("locked takes precedence", lockedAndAway, blocked: "screen is locked")

        if failures > 0 {
            print("\(failures) session lock test(s) failed")
            exit(1)
        }
        print("All session lock tests passed")
    }
}
