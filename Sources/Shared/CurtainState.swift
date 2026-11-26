import Foundation
import Darwin

enum CurtainPhase: String, Equatable {
    case off
    case preparing
    case active
    case releasing
    case fault

    var blocksDesktopInput: Bool { self != .off }
    var allowsAccessibility: Bool { self == .active }
}

// What the marker says, and what the servers act on. MacControl.app rewrites the marker about once a second
// while the curtain is on; if it crashes or hangs, the panels may be gone, so a marker that has not been
// confirmed recently counts as a fault instead of being trusted.
struct CurtainReading: Equatable {
    let recorded: CurtainPhase
    let stale: Bool

    var phase: CurtainPhase { stale ? .fault : recorded }
}

enum CurtainStateStore {
    private static let directoryName = "MacControl"
    private static let fileName = "curtain-state"
    static let heartbeatSeconds: TimeInterval = 1
    static let staleAfterSeconds: TimeInterval = 3

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func read() -> CurtainPhase {
        reading().phase
    }

    static func reading() -> CurtainReading {
        reading(at: fileURL, now: Date())
    }

    static func reading(at url: URL, now: Date) -> CurtainReading {
        guard FileManager.default.fileExists(atPath: url.path) else { return CurtainReading(recorded: .off, stale: false) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CurtainReading(recorded: .fault, stale: false)
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let phase = CurtainPhase(rawValue: first) else {
            return CurtainReading(recorded: .fault, stale: false)
        }
        // Off needs no confirmation: nothing is covered, and every tool already works as without a curtain.
        if phase == .off { return CurtainReading(recorded: .off, stale: false) }
        guard lines.count > 1, let seconds = Double(lines[1]), seconds.isFinite else {
            return CurtainReading(recorded: phase, stale: true)
        }
        // A time ahead of the clock is accepted only by as much as a stale one would be, so a clock set
        // backwards cannot keep a dead curtain trusted.
        let age = now.timeIntervalSince1970 - seconds
        return CurtainReading(recorded: phase, stale: abs(age) > staleAfterSeconds)
    }

    static func write(_ phase: CurtainPhase) throws {
        try write(phase, at: fileURL, now: Date())
    }

    static func write(_ phase: CurtainPhase, at url: URL, now: Date) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let text = phase.rawValue + "\n" + String(format: "%.3f", now.timeIntervalSince1970) + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
