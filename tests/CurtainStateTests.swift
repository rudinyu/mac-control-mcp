import Foundation

private var failures = 0

private func check(_ name: String, _ passed: Bool) {
    if passed { print("ok   \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}

@main
private enum CurtainStateTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("curtain-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("curtain-state")
        let now = Date()
        func phase(at time: Date = now) -> CurtainPhase { CurtainStateStore.reading(at: file, now: time).phase }

        check("missing marker means off", phase() == .off)
        try CurtainStateStore.write(.preparing, at: file, now: now)
        check("preparing marker round trips", phase() == .preparing)
        try CurtainStateStore.write(.active, at: file, now: now)
        check("active marker round trips", phase() == .active)
        check("active curtain allows AX", phase().allowsAccessibility)
        check("active curtain blocks desktop input", phase().blocksDesktopInput)

        let late = now.addingTimeInterval(CurtainStateStore.staleAfterSeconds + 1)
        check("unconfirmed active marker is a fault", phase(at: late) == .fault)
        check("stale reading keeps the recorded phase",
              CurtainStateStore.reading(at: file, now: late) == CurtainReading(recorded: .active, stale: true))
        check("stale curtain refuses AX", !phase(at: late).allowsAccessibility)
        check("marker within the limit is trusted",
              phase(at: now.addingTimeInterval(CurtainStateStore.staleAfterSeconds - 1)) == .active)
        check("marker far in the future is a fault", phase(at: now.addingTimeInterval(-60)) == .fault)

        try CurtainStateStore.write(.fault, at: file, now: now)
        check("an old fault stays a recorded fault",
              CurtainStateStore.reading(at: file, now: late).recorded == .fault)
        try CurtainStateStore.write(.releasing, at: file, now: now)
        check("unconfirmed releasing marker is a fault", phase(at: late) == .fault)
        try Data("active\ninf\n".utf8).write(to: file)
        check("active marker with an infinite time is a fault", phase() == .fault)

        try CurtainStateStore.write(.off, at: file, now: now)
        check("off marker round trips", phase() == .off)
        check("off is written as a bare phase that older servers read",
              (try? String(contentsOf: file, encoding: .utf8)) == "off\n")
        check("off needs no confirmation", phase(at: late) == .off)

        try Data("active\n".utf8).write(to: file)
        check("active marker without a time is a fault", phase() == .fault)
        try Data("active\nsoon\n".utf8).write(to: file)
        check("active marker with a bad time is a fault", phase() == .fault)
        try Data("unexpected\n".utf8).write(to: file)
        check("invalid marker fails closed", phase() == .fault)

        func evaluate(_ recorded: CurtainPhase, stale: Bool = false, locked: Bool = false,
                      _ coverage: CurtainCoverage) -> CurtainPhase {
            CurtainCheck.evaluate(CurtainReading(recorded: recorded, stale: stale), sessionLocked: locked,
                                  coverage: coverage).phase
        }
        check("off without panels is off", evaluate(.off, .none) == .off)
        check("off written while panels show is a fault", evaluate(.off, .full) == .fault)
        check("off written while some panels show is a fault", evaluate(.off, .partial) == .fault)
        check("active covering every display is active", evaluate(.active, .full) == .active)
        check("active missing a display is a fault", evaluate(.active, .partial) == .fault)
        check("active without panels is a fault", evaluate(.active, .none) == .fault)
        check("locked session trusts active without panels", evaluate(.active, locked: true, .none) == .active)
        check("locked session still refuses a stale marker", evaluate(.active, stale: true, locked: true, .none) == .fault)
        check("off is a fault when windows cannot be listed", evaluate(.off, .unknown) == .fault)
        check("active is a fault when windows cannot be listed", evaluate(.active, .unknown) == .fault)
        check("preparing stays preparing", evaluate(.preparing, .partial) == .preparing)
        check("releasing stays releasing", evaluate(.releasing, .none) == .releasing)
        check("a recorded fault stays a fault without a problem",
              CurtainCheck.evaluate(CurtainReading(recorded: .fault, stale: true), sessionLocked: false, coverage: .none)
                == CurtainCheck(phase: .fault, problem: nil))
        check("a forged off names the panels",
              CurtainCheck.evaluate(CurtainReading(recorded: .off, stale: false), sessionLocked: false, coverage: .full)
                .problem?.contains("still on the displays") == true)

        if failures > 0 { exit(1) }
        print("All curtain state tests passed")
    }
}
