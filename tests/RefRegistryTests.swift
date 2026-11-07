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
    // Snapshots hold only three refs here, so tests can fill them.
    func registry() -> RefRegistry {
        RefRegistry(processStart: { self.starts[$0] }, isRunning: { self.starts[$0] != nil }, appName: { self.starts[$0] == nil ? nil : "App \($0)" },
                    refLimit: 3)
    }
}

private func element(_ n: pid_t) -> AXUIElement { AXUIElementCreateApplication(n) }

// Gives out refs until the owner's snapshot is full, so the app's next read starts a new one.
private func fill(_ refs: RefRegistry, _ owner: AXOwner) {
    for n in pid_t(1000)..<1003 { _ = refs.ref(for: element(n), role: "AXGroup", owner: owner) }
}

private func found(_ lookup: RefLookup) -> AXRef? {
    if case .found(let ref) = lookup { return ref }
    return nil
}

private func retiredReason(_ lookup: RefLookup) -> RetireReason? {
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

        guard let first = refs.owner(100) else {
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

        let same = refs.owner(100)
        check("reading again keeps the snapshot", same?.snapshot == first.snapshot)
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

        fill(refs, first)
        guard let second = refs.owner(100) else { exit(1) }
        check("a full snapshot is replaced at the next read", second.snapshot != first.snapshot)
        check("the old snapshot's refs are replaced", retiredReason(refs.lookup(button)) == .replaced(by: second.snapshot, app: "App 100"), "\(refs.lookup(button))")
        check("the reason reads as a sentence", retiredReason(refs.lookup(button))?.description
              == "was replaced by snapshot \(second.snapshot) of App 100 after giving out as many refs as a snapshot may")
        check("the new snapshot numbers from 1 again", refs.ref(for: element(1), role: "AXButton", owner: second) == "\(second.snapshot).1")

        // A relaunch is noticed when the next read asks for the current snapshot.
        processes.launch(100, at: 2)
        guard let third = refs.owner(100) else { exit(1) }
        check("a relaunched app gets a new snapshot", third.snapshot != second.snapshot)
        check("refs of the earlier run say so", retiredReason(refs.lookup("\(second.snapshot).1")) == .earlierRun(app: "App 100"), "\(refs.lookup("\(second.snapshot).1"))")

        // A relaunch is also noticed when a ref is used.
        let kept = refs.ref(for: element(3), role: "AXButton", owner: third)
        if let ref = found(refs.lookup(kept)) {
            check("a ref from the current run is current", refs.confirmCurrentRun(ref))
            processes.launch(100, at: 3)
            check("a ref from before a relaunch is not", !refs.confirmCurrentRun(ref))
            check("and its snapshot is retired", retiredReason(refs.lookup(kept)) == .earlierRun(app: "App 100"), "\(refs.lookup(kept))")
            check("and the app has no current snapshot", refs.snapshot(of: 100) == nil)
        } else {
            check("a ref from the current run is found", false)
        }

        // Another app's refs are dropped once it quits.
        guard let other = refs.owner(200) else { exit(1) }
        let otherRef = refs.ref(for: element(4), role: "AXButton", owner: other)
        let current = refs.owner(100)
        processes.starts[200] = nil
        check("an app's next read keeps its snapshot", refs.owner(100)?.snapshot == current?.snapshot)
        check("refs of an app that quit are released", retiredReason(refs.lookup(otherRef)) == .quit, "\(refs.lookup(otherRef))")

        check("an app without a start time gets no snapshot", refs.owner(300) == nil)
        if case .unknownSnapshot("zzzzzz") = refs.lookup("zzzzzz.1") {
            check("a snapshot from another session is unknown", true)
        } else {
            check("a snapshot from another session is unknown", false)
        }
        if case .notARef = refs.lookup("3.12") { check("an old-style ref is not a ref", true) } else { check("an old-style ref is not a ref", false) }

        // Reading more in an app with no snapshot starts one.
        processes.launch(500, at: 1)
        let started = refs.owner(500)
        check("reading more without a snapshot starts one", started != nil && refs.snapshot(of: 500) == started?.snapshot)

        // Each app numbers its own refs, even for an element that compares equal to one in another app.
        processes.launch(600, at: 1)
        if let a = refs.owner(500), let b = refs.owner(600) {
            let inA = refs.ref(for: element(7), role: "AXButton", owner: a)
            let inB = refs.ref(for: element(7), role: "AXButton", owner: b)
            check("apps keep separate refs", inA == "\(a.snapshot).1" && inB == "\(b.snapshot).1", "\(inA), \(inB)")
            check("another app's snapshot leaves these refs alone", found(refs.lookup(inA)) != nil)

            // An element found again after its ref was forgotten gets a new number, never the old one.
            refs.forget(inA)
            let again = refs.ref(for: element(7), role: "AXButton", owner: a)
            check("a forgotten element gets a new number", again == "\(a.snapshot).2", again)

            // An app that quit is noticed when its ref is used.
            if let ref = found(refs.lookup(inB)) {
                processes.starts[600] = nil
                check("a ref of an app that quit is not current", !refs.confirmCurrentRun(ref))
                check("and names no app it cannot find", retiredReason(refs.lookup(inB)) == .earlierRun(app: "the app"), "\(refs.lookup(inB))")
                check("the other app's refs are kept", found(refs.lookup(again)) != nil)
            } else {
                check("a ref in the second app is found", false)
            }
        } else {
            check("two apps get snapshots", false)
        }

        // A new snapshot ID differs from the current ones and the 200 remembered replaced ones, so the current
        // snapshot and the 200 before it are all different.
        processes.launch(700, at: 1)
        var seen = Set<String>()
        for _ in 0...200 {
            if let owner = refs.owner(700) { seen.insert(owner.snapshot); fill(refs, owner) }
        }
        check("remembered snapshot IDs are unique", seen.count == 201, "\(seen.count)")
        check("snapshot IDs make valid refs", seen.allSatisfy { parseRef($0 + ".1") != nil })

        // Only the newest 200 replaced snapshots are remembered. Making next retires oldest, and each read in the
        // loop retires the one before it, so 200 snapshots are retired after oldest and 199 after next.
        processes.launch(400, at: 1)
        func nextSnapshot() -> String { let owner = refs.owner(400)!; fill(refs, owner); return owner.snapshot }
        let oldest = nextSnapshot()
        let next = nextSnapshot()
        for _ in 0..<200 { _ = nextSnapshot() }
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
