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

        check("missing marker means off", CurtainStateStore.read(at: file) == .off)
        try CurtainStateStore.write(.preparing, at: file)
        check("preparing marker round trips", CurtainStateStore.read(at: file) == .preparing)
        try CurtainStateStore.write(.active, at: file)
        check("active marker round trips", CurtainStateStore.read(at: file) == .active)
        check("active curtain allows AX", CurtainStateStore.read(at: file).allowsAccessibility)
        check("active curtain blocks desktop input", CurtainStateStore.read(at: file).blocksDesktopInput)
        try CurtainStateStore.write(.off, at: file)
        check("off marker round trips", CurtainStateStore.read(at: file) == .off)
        try Data("unexpected\n".utf8).write(to: file)
        check("invalid marker fails closed", CurtainStateStore.read(at: file) == .fault)

        if failures > 0 { exit(1) }
        print("All curtain state tests passed")
    }
}
