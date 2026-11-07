// Unit tests for the lock mac-control servers share. Built with Sources/MacControl/SharedLock.swift by scripts/ci.sh.
// flock locks belong to an open file, so two SharedLock objects in one process stand in for two servers.

import Foundation

private var failures = 0

private func check(_ name: String, _ passed: Bool) {
    print(passed ? "ok   \(name)" : "FAIL \(name)")
    if !passed { failures += 1 }
}

@main
private enum SharedLockTests {
    static func main() {
        let name = "test-\(UUID().uuidString)"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("mac-control-\(name).lock")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = SharedLock(name)
        let second = SharedLock(name)
        do {
            check("the first server takes the lock", try first.tryLock() && first.isHeld)
            check("taking it again while held succeeds", try first.tryLock())
            check("a second server cannot take it", try !second.tryLock() && !second.isHeld)
            let started = Date()
            check("waiting gives up at the timeout", try !second.lock(timeout: 0.2, cancellation: Cancellation()))
            check("and waits about that long", Date().timeIntervalSince(started) >= 0.2)
            let cancelled = Cancellation()
            cancelled.cancel()
            var threw = false
            do { _ = try second.lock(timeout: 5, cancellation: cancelled) } catch { threw = true }
            check("a cancelled call stops waiting", threw)
            first.unlock()
            check("once released, the second server takes it", try second.tryLock())
            check("and the first cannot", try !first.tryLock())
            second.unlock()
            second.unlock()
            check("releasing twice is harmless", try first.tryLock())
            first.unlock()
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            check("the lock file is private", (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        } catch {
            check("no error: \(error)", false)
        }
        if failures > 0 {
            print("\(failures) shared lock test(s) failed")
            exit(1)
        }
        print("All shared lock tests passed")
    }
}
