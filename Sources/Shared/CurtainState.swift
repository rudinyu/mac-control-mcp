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

enum CurtainStateStore {
    private static let directoryName = "MacControl"
    private static let fileName = "curtain-state"

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func read() -> CurtainPhase {
        read(at: fileURL)
    }

    static func read(at url: URL) -> CurtainPhase {
        guard FileManager.default.fileExists(atPath: url.path) else { return .off }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let phase = CurtainPhase(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .fault
        }
        return phase
    }

    static func write(_ phase: CurtainPhase) throws {
        try write(phase, at: fileURL)
    }

    static func write(_ phase: CurtainPhase, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data((phase.rawValue + "\n").utf8).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
