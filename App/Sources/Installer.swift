import Foundation

// Where MacControl keeps what it installs. Nothing here needs administrator rights.
struct AppPaths {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let bundle = Bundle.main.bundleURL

    var support: URL { home.appendingPathComponent("Library/Application Support/MacControl") }
    var runtime: URL { support.appendingPathComponent("runtime") }
    var runtimeBin: URL { runtime.appendingPathComponent("bin") }
    var lima: URL { runtime.appendingPathComponent("lima-\(Manifest.limaVersion)") }
    var colima: URL { runtimeBin.appendingPathComponent("colima") }
    var docker: URL { runtimeBin.appendingPathComponent("docker") }
    // Colima's docker commands write contexts here, so the user's own Docker settings are never changed.
    var dockerConfig: URL { support.appendingPathComponent("docker-config") }
    var downloads: URL { support.appendingPathComponent("downloads") }
    // Colima keeps profiles in ~/.colima; a short path keeps Lima's sockets under the macOS length limit.
    var colimaSocket: URL { home.appendingPathComponent(".colima/\(Installer.colimaProfile)/docker.sock") }
    var marker: URL { runtime.appendingPathComponent("installed-versions") }

    var helpers: URL { bundle.appendingPathComponent("Contents/Helpers") }
    var controlServer: URL { helpers.appendingPathComponent("mac-control-mcp") }
    var execServer: URL { helpers.appendingPathComponent("mac-exec-mcp") }
    var sandboxContext: URL { bundle.appendingPathComponent("Contents/Resources/sandbox") }
    var appleContainer: URL { URL(fileURLWithPath: "/usr/local/bin/container") }
}

struct InstallFailure: Error, CustomStringConvertible {
    let description: String
}

enum Installer {
    static let colimaProfile = "maccontrol"
    static let image = "mac-exec-sandbox:latest"
    static let paths = AppPaths()

    static var installedVersions: String {
        "colima \(Manifest.colimaVersion), lima \(Manifest.limaVersion), docker \(Manifest.dockerVersion)"
    }

    // MARK: Running programs

    // The PATH that the managed tools need: Colima calls limactl and docker.
    static var managedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [paths.runtimeBin.path, paths.lima.appendingPathComponent("bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        env["DOCKER_CONFIG"] = paths.dockerConfig.path
        return env
    }

    static func run(_ program: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 120) async throws -> RunResult {
        try await Task.detached(priority: .userInitiated) {
            try runProcess(program, arguments, environment: environment, timeout: timeout, outputLimit: 200_000)
        }.value
    }

    // Finds a command the way the user's login shell would, since apps start with a short PATH.
    static func locate(_ command: String) async -> String? {
        let result = try? await run("/bin/zsh", ["-lc", #"command -v -- "$1""#, "zsh", command], timeout: 20)
        guard let path = result?.stdout.split(separator: "\n").last.map(String.init),
              result?.exitCode == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // Runs a client's CLI inside the login shell, so tools it needs, such as node, are found.
    static func runInLoginShell(_ program: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> RunResult {
        try await run("/bin/zsh", ["-lc", #""$0" "$@""#, program] + arguments, timeout: timeout)
    }

    // MARK: Downloads

    // Downloads a file and keeps it only if its SHA-256 matches the manifest.
    static func fetch(_ download: Download) async throws -> URL {
        try FileManager.default.createDirectory(at: paths.downloads, withIntermediateDirectories: true)
        let target = paths.downloads.appendingPathComponent(download.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path), Checksum.matches(target, download.sha256) { return target }
        let (temporary, response) = try await URLSession.shared.download(from: download.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw InstallFailure(description: "Could not download \(download.name) from \(download.url.host ?? "the server").")
        }
        guard Checksum.matches(temporary, download.sha256) else {
            try? FileManager.default.removeItem(at: temporary)
            throw InstallFailure(description: "\(download.name) did not match its expected checksum, so it was not installed. Try again later, or update MacControl.")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    // MARK: Managed Colima

    static var managedColimaInstalled: Bool {
        (try? String(contentsOf: paths.marker, encoding: .utf8)) == installedVersions
            && FileManager.default.isExecutableFile(atPath: paths.colima.path)
            && FileManager.default.isExecutableFile(atPath: paths.docker.path)
            && FileManager.default.isExecutableFile(atPath: paths.lima.appendingPathComponent("bin/limactl").path)
    }

    static func installManagedColima(cpu: CPU, progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.runtimeBin, withIntermediateDirectories: true)

        progress("Downloading \(Manifest.lima(cpu).name)…")
        let lima = try await fetch(Manifest.lima(cpu))
        try? fm.removeItem(at: paths.lima)
        try fm.createDirectory(at: paths.lima, withIntermediateDirectories: true)
        try await check(run("/usr/bin/tar", ["-xzf", lima.path, "-C", paths.lima.path]), "unpack Lima")

        progress("Downloading \(Manifest.colima(cpu).name)…")
        let colima = try await fetch(Manifest.colima(cpu))
        try? fm.removeItem(at: paths.colima)
        try fm.copyItem(at: colima, to: paths.colima)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.colima.path)

        progress("Downloading \(Manifest.dockerCLI(cpu).name)…")
        let docker = try await fetch(Manifest.dockerCLI(cpu))
        let unpacked = paths.downloads.appendingPathComponent("docker-unpacked")
        try? fm.removeItem(at: unpacked)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await check(run("/usr/bin/tar", ["-xzf", docker.path, "-C", unpacked.path, "docker/docker"]), "unpack the Docker CLI")
        try? fm.removeItem(at: paths.docker)
        try fm.moveItem(at: unpacked.appendingPathComponent("docker/docker"), to: paths.docker)
        try? fm.removeItem(at: unpacked)

        try installedVersions.write(to: paths.marker, atomically: true, encoding: .utf8)
        progress("Installed \(installedVersions).")
    }

    static func colimaRunning() async -> Bool {
        guard managedColimaInstalled else { return false }
        let status = try? await run(paths.colima.path, ["status", "--profile", colimaProfile], environment: managedEnvironment, timeout: 30)
        return status?.exitCode == 0
    }

    // Starts the MacControl Colima profile, sharing only the workspace (read-write) and the read-only folders.
    // A running profile is restarted when the shared folders changed.
    static func startColima(workspace: URL, readOnly: [URL], cpu: CPU, progress: @escaping @Sendable (String) -> Void) async throws {
        let mounts = ["\(resolvedPath(workspace)):w"] + readOnly.map { resolvedPath($0) }
        let mountKey = "colimaMounts"
        if await colimaRunning(), UserDefaults.standard.stringArray(forKey: mountKey) == mounts { return }
        if await colimaRunning() {
            progress("Restarting the sandbox VM with the new shared folders…")
            _ = try? await run(paths.colima.path, ["stop", "--profile", colimaProfile], environment: managedEnvironment, timeout: 180)
        } else {
            progress("Starting the sandbox VM (this takes a minute the first time)…")
        }
        try FileManager.default.createDirectory(at: paths.dockerConfig, withIntermediateDirectories: true)
        var arguments = ["start", "--profile", colimaProfile, "--runtime", "docker", "--vm-type", "vz",
                         "--cpu", "2", "--memory", "4", "--disk", "30"]
        if cpu == .appleSilicon { arguments += ["--arch", "aarch64"] }
        for mount in mounts { arguments += ["--mount", mount] }
        try await check(run(paths.colima.path, arguments, environment: managedEnvironment, timeout: 900), "start Colima")
        UserDefaults.standard.set(mounts, forKey: mountKey)
    }

    // MARK: Apple container

    static var appleContainerInstalled: Bool { FileManager.default.isExecutableFile(atPath: paths.appleContainer.path) }

    // Downloads Apple's signed installer, checks its checksum and that Apple's Containerization team signed it,
    // then opens it in Installer, where the user confirms and authenticates.
    static func openAppleContainerInstaller(progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Downloading \(Manifest.appleContainer.name)…")
        let package = try await fetch(Manifest.appleContainer)
        let signature = try await run("/usr/sbin/pkgutil", ["--check-signature", package.path], timeout: 60)
        guard signature.exitCode == 0, signature.stdout.contains("(\(Manifest.appleContainerTeamID))"),
              signature.stdout.contains("Notarization: trusted by the Apple notary service") else {
            throw InstallFailure(description: "The Apple container installer is not signed and notarized by Apple, so it was not opened.")
        }
        progress("Opening the installer. Follow its steps, then come back to MacControl.")
        _ = try await run("/usr/bin/open", ["-a", "Installer", package.path], timeout: 30)
    }

    static func startAppleContainer() async throws {
        let status = try? await run(paths.appleContainer.path, ["system", "status"], timeout: 30)
        if status?.exitCode == 0 { return }
        try await check(run(paths.appleContainer.path, ["system", "start", "--enable-kernel-install"], timeout: 900), "start Apple container")
    }

    // MARK: Sandbox image

    static func runtime(for choice: RuntimeChoice) -> ContainerRuntime {
        switch choice {
        case .appleContainer:
            return ContainerRuntime(kind: .apple, program: paths.appleContainer.path, environment: ProcessInfo.processInfo.environment)
        case .existingDocker(let docker):
            return ContainerRuntime(kind: .docker, program: docker, environment: ProcessInfo.processInfo.environment)
        case .managedColima:
            var env = managedEnvironment
            env["DOCKER_HOST"] = "unix://" + paths.colimaSocket.path
            return ContainerRuntime(kind: .docker, program: paths.docker.path, environment: env)
        }
    }

    static func imagePresent(_ runtime: ContainerRuntime) async -> Bool {
        let result = try? await run(runtime.program, runtime.imageExistsArguments(image), environment: runtime.environment, timeout: 30)
        return result?.exitCode == 0
    }

    static func buildImage(_ runtime: ContainerRuntime, progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Building the sandbox image (a few minutes the first time)…")
        try await check(run(runtime.program, runtime.buildArguments(image: image, context: paths.sandboxContext.path),
                            environment: runtime.environment, timeout: 1800), "build the sandbox image")
    }

    // Runs one throwaway container the way mac-exec does, to prove the whole path works.
    static func smokeTest(_ runtime: ContainerRuntime, workspace: URL) async throws {
        let probe = ".maccontrol-probe-\(UUID().uuidString.prefix(8))"
        let run = SandboxRun(name: "mac-exec-check-\(UUID().uuidString.lowercased())", image: image,
                             workspace: resolvedPath(workspace), readOnly: [], workdir: "/workspace",
                             command: "id -u && touch \(probe) && rm \(probe)")
        let result = try await self.run(runtime.program, try runtime.runArguments(run), environment: runtime.environment, timeout: 300)
        guard result.exitCode == 0, result.stdout.split(separator: "\n").first == "1000" else {
            throw InstallFailure(description: "The sandbox test container failed: \(String(result.stderr.suffix(600)))")
        }
    }

    private static func check(_ result: RunResult, _ action: String) throws {
        guard result.exitCode == 0, !result.timedOut else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(800)
            throw InstallFailure(description: "Could not \(action)\(result.timedOut ? " (it took too long)" : ""): \(detail)")
        }
    }
}
