// Unit tests for the refs mac-control gives out. Built with Sources/MacControl/RefRegistry.swift by
// scripts/ci.sh. Elements are application elements for made-up PIDs, which need no Accessibility permission,
// and process start times and running apps are simulated.

import ApplicationServices
import Foundation

private var failures = 0

private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    if passed {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail().isEmpty ? "" : "\n     \(detail())")")
    }
}

// Apps by PID, with when each started; an app that quits is removed.
private final class FakeProcesses {
    var starts: [pid_t: timeval] = [:]
    func launch(_ pid: pid_t, at second: Int) { starts[pid] = timeval(tv_sec: second, tv_usec: 0) }
    func registry() -> RefRegistry {
        RefRegistry(processStart: { self.starts[$0] }, isRunning: { self.starts[$0] != nil }, appName: { "App \($0)" })
    }
}

private func element(_ n: pid_t) -> AXUIElement { AXUIElementCreateApplication(n) }

private func found(_ lookup: RefLookup) -> AXRef? {
    if case .found(let ref) = lookup { return ref }
    return nil
}

private func retiredReason(_ lookup: RefLookup) -> String? {
    if case .retired(_, let reason) = lookup { return reason }
    return nil
}

@main
private enum RefRegistryTests {
    static func main() {
        for valid in ["k3f9q2.12", "a00000.1", "zzzzzz.999"] {
            check("parses \(valid)", parseRef(valid) != nil)
        }
        for invalid in ["3.12", "K3f9q2.1", "k3f9q.1", "1abcde.1", "k3f9q2.012", "k3f9q2.0", "k3f9q2.", "k3f9q2.1.2", "k3f9q2.-1", "ｋ3f9q2.1"] {
            check("refuses \(invalid)", parseRef(invalid) == nil)
        }

        let processes = FakeProcesses()
        processes.launch(100, at: 1)
        processes.launch(200, at: 1)
        let refs = processes.registry()

        guard let first = refs.owner(100, fresh: true) else {
            check("an app with a start time gets a snapshot", false)
            exit(1)
        }
        check("a snapshot ID makes a valid ref", parseRef(first.snapshot + ".1") != nil, first.snapshot)
        check("the app's current snapshot is reported", refs.snapshot(of: 100) == first.snapshot)

        let button = refs.ref(for: element(1), role: "AXButton", owner: first)
        let field = refs.ref(for: element(2), role: "AXTextField", owner: first)
        check("refs are numbered from 1", button == "\(first.snapshot).1" && field == "\(first.snapshot).2", "\(button), \(field)")
        check("an element found again keeps its ref", refs.ref(for: element(1), role: "AXButton", owner: first) == button)
        check("a ref names its element", found(refs.lookup(button)).map { CFEqual($0.element, element(1)) && $0.role == "AXButton" && $0.pid == 100 } == true)

        let same = refs.owner(100, fresh: false)
        check("reading more keeps the snapshot", same?.snapshot == first.snapshot)
        check("refs survive reading more", found(refs.lookup(field)) != nil)

        refs.forget(field)
        if case .missing(_, 2, true) = refs.lookup(field) {
            check("a forgotten ref is reported as gone", true)
        } else {
            check("a forgotten ref is reported as gone", false, "\(refs.lookup(field))")
        }
        if case .missing(_, 99, false) = refs.lookup("\(first.snapshot).99") {
            check("a number never given out is reported as such", true)
        } else {
            check("a number never given out is reported as such", false)
        }

        guard let second = refs.owner(100, fresh: true) else { exit(1) }
        check("a full read starts a new snapshot", second.snapshot != first.snapshot)
        check("the old snapshot's refs are replaced", retiredReason(refs.lookup(button))?.contains("was replaced by snapshot \(second.snapshot)") == true,
              "\(refs.lookup(button))")
        check("the new snapshot numbers from 1 again", refs.ref(for: element(1), role: "AXButton", owner: second) == "\(second.snapshot).1")

        // A relaunch is noticed when the next read asks for the current snapshot.
        processes.launch(100, at: 2)
        guard let third = refs.owner(100, fresh: false) else { exit(1) }
        check("a relaunched app gets a new snapshot", third.snapshot != second.snapshot)
        check("refs of the earlier run say so", retiredReason(refs.lookup("\(second.snapshot).1"))?.contains("earlier run of App 100") == true)

        // A relaunch is also noticed when a ref is used.
        let kept = refs.ref(for: element(3), role: "AXButton", owner: third)
        if let ref = found(refs.lookup(kept)) {
            check("a ref from the current run is current", refs.isCurrentRun(ref))
            processes.launch(100, at: 3)
            check("a ref from before a relaunch is not", !refs.isCurrentRun(ref))
            check("and its snapshot is retired", retiredReason(refs.lookup(kept))?.contains("earlier run of the app") == true)
            check("and the app has no current snapshot", refs.snapshot(of: 100) == nil)
        } else {
            check("a ref from the current run is found", false)
        }

        // Another app's refs are dropped once it quits.
        guard let other = refs.owner(200, fresh: true) else { exit(1) }
        let otherRef = refs.ref(for: element(4), role: "AXButton", owner: other)
        processes.starts[200] = nil
        _ = refs.owner(100, fresh: true)
        check("refs of an app that quit are released", retiredReason(refs.lookup(otherRef))?.contains("app that has quit") == true)

        check("an app without a start time gets no snapshot", refs.owner(300, fresh: true) == nil)
        if case .unknownSnapshot("zzzzzz") = refs.lookup("zzzzzz.1") {
            check("a snapshot from another session is unknown", true)
        } else {
            check("a snapshot from another session is unknown", false)
        }
        if case .notARef = refs.lookup("3.12") { check("an old-style ref is not a ref", true) } else { check("an old-style ref is not a ref", false) }

        // Only the newest 200 replaced snapshots are remembered. Making next retires oldest, and each read in the
        // loop retires the one before it, so 200 snapshots are retired after oldest and 199 after next.
        processes.launch(400, at: 1)
        let oldest = refs.owner(400, fresh: true)!.snapshot
        let next = refs.owner(400, fresh: true)!.snapshot
        for _ in 0..<200 { _ = refs.owner(400, fresh: true) }
        if case .unknownSnapshot = refs.lookup("\(oldest).1") {
            check("the oldest replaced snapshot is forgotten after 200 more", true)
        } else {
            check("the oldest replaced snapshot is forgotten after 200 more", false, "\(refs.lookup("\(oldest).1"))")
        }
        check("a newer replaced snapshot is still remembered", retiredReason(refs.lookup("\(next).1")) != nil)

        if failures > 0 {
            print("\(failures) ref registry test(s) failed")
            exit(1)
        }
        print("All ref registry tests passed")
    }
}
