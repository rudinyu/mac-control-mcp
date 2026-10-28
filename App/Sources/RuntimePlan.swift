import CryptoKit
import Foundation

// One file the app may download. The version and SHA-256 are pinned here, inside the signed app,
// so a changed or replaced download is refused instead of installed.
struct Download: Equatable {
    let name: String
    let url: URL
    let sha256: String
}

enum CPU: String {
    case appleSilicon = "arm64"
    case intel = "x86_64"
}

// Components and checksums verified when this version of the app was built. Update them together
// with the app; never fetch checksums at run time from the same place as the files.
enum Manifest {
    static let colimaVersion = "0.10.3"
    static let limaVersion = "2.2.1"
    static let dockerVersion = "29.9.2"
    static let appleContainerVersion = "1.6.1"
    // Team ID of "Developer ID Installer: Apple Inc. - Containerization", which signs the container package.
    static let appleContainerTeamID = "UPBK2H6LZM"

    static func colima(_ cpu: CPU) -> Download {
        let file = "colima-Darwin-\(cpu.rawValue)"
        return Download(name: "Colima \(colimaVersion)",
                        url: URL(string: "https://github.com/abiosoft/colima/releases/download/v\(colimaVersion)/\(file)")!,
                        sha256: cpu == .intel
                            ? "3082737fe8a98afda11cba7d9a20b6e56fe80c6153464beda04bec630758770b"
                            : "980ad8bf61a4ca370243f4cb41401a61276dcd2c2502bee7b9b86f9250169f34")
    }

    static func lima(_ cpu: CPU) -> Download {
        let file = "lima-\(limaVersion)-Darwin-\(cpu.rawValue).tar.gz"
        return Download(name: "Lima \(limaVersion)",
                        url: URL(string: "https://github.com/lima-vm/lima/releases/download/v\(limaVersion)/\(file)")!,
                        sha256: cpu == .intel
                            ? "6b776e4bc41f358e6ee01fefcc78e2eb26f11635a0fcff632234af77a566c6c4"
                            : "9e9eacce88f37e185c346bad73aa6136f738d8cdf8c3bb23cd42b071824bc66e")
    }

    static func dockerCLI(_ cpu: CPU) -> Download {
        let folder = cpu == .intel ? "x86_64" : "aarch64"
        return Download(name: "Docker CLI \(dockerVersion)",
                        url: URL(string: "https://download.docker.com/mac/static/stable/\(folder)/docker-\(dockerVersion).tgz")!,
                        sha256: cpu == .intel
                            ? "089c3f618df88bdef4f1257d9d604499136a1ec5168b67d194c260acad2b522f"
                            : "ea8a2ce5ac31f9f5f3fb711a7a485e1e46cc7a69798a629a70306f6e6af25b7a")
    }

    static let appleContainer = Download(
        name: "Apple container \(appleContainerVersion)",
        url: URL(string: "https://github.com/apple/container/releases/download/\(appleContainerVersion)/container-\(appleContainerVersion)-installer-signed.pkg")!,
        sha256: "cd47846819f06478d067060efe21e516b562ac0a9af8eecad6d5fea0b556b200")
}

// How the sandbox will run on this Mac.
enum RuntimeChoice: Equatable {
    case appleContainer          // Apple silicon with macOS 26 or later
    case existingDocker(String)  // a docker program that already works, such as Docker Desktop or OrbStack
    case managedColima           // Colima, Lima, and the Docker CLI installed by this app

    var label: String {
        switch self {
        case .appleContainer: return String(localized: "Apple container")
        case .existingDocker: return String(localized: "Docker on this Mac")
        case .managedColima: return String(localized: "Linux VM by MacControl")
        }
    }
}

enum RuntimeSelection {
    // Apple silicon on macOS 26 or later uses Apple's runtime. Elsewhere, a Docker that already works is
    // reused, and otherwise the app installs its own Colima.
    static func choose(cpu: CPU, macOSMajor: Int, workingDocker: String?) -> RuntimeChoice {
        if cpu == .appleSilicon, macOSMajor >= 26 { return .appleContainer }
        if let docker = workingDocker { return .existingDocker(docker) }
        return .managedColima
    }

    // The real CPU, even when the app runs under Rosetta.
    static func currentCPU() -> CPU {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let found = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return found && value == 1 ? .appleSilicon : .intel
    }
}

enum Checksum {
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ file: URL, _ expected: String) -> Bool {
        (try? sha256(of: file)) == expected.lowercased()
    }
}

enum AppVersion {
    // Numeric parts of a version such as "v0.3.10" or "0.3.4"; anything after a "-" is ignored.
    static func parts(_ version: String) -> [Int] {
        let core = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        return core.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum PrivacyPane {
    static let helperBundleID = "tw.com.eaman.MacControl.control"

    // macOS 27 renamed Privacy & Security > Accessibility to Device Control and Data Access.
    static func accessibilityRenamed(macOSMajor: Int) -> Bool { macOSMajor >= 27 }
}
