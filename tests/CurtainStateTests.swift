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
        check("off needs no confirmation", phase(at: late) == .off)

        try Data("active\n".utf8).write(to: file)
        check("active marker without a time is a fault", phase() == .fault)
        try Data("active\nsoon\n".utf8).write(to: file)
        check("active marker with a bad time is a fault", phase() == .fault)
        try Data("unexpected\n".utf8).write(to: file)
        check("invalid marker fails closed", phase() == .fault)

        if failures > 0 { exit(1) }
        print("All curtain state tests passed")
    }
}
