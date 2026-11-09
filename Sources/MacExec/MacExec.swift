import Foundation

private let defaultImage = "mac-exec-sandbox:latest"
private let outputLimit = 100_000
private let maxCommandLength = 20_000
private let maxFileBytes = 1_000_000
// The audit log is moved aside to audit.log.1 once it reaches this size.
private let auditLogLimit: off_t = 10_000_000
private let defaultReadBytes = 200_000
private let maxListEntries = 500

private struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Settings read once from the environment the MCP client starts the server with.
private struct Settings {
    let home: URL
    let workspace: URL
    let readOnlyDirs: [URL]
    let project: URL
    let allowHost: Bool
    let image: String
    let network: SandboxNetwork
    let runtime: ContainerRuntime?
    let auditLog: URL
    // Set when the audit log may not be used; every command, host_exec included, is then refused.
    let auditLogProblem: String?
    let problems: [String]

    // A read-only folder in the workspace, or reached through it, is refused: the sandbox could replace it,
    // or a link on the way to it, between runs. A folder inside the workspace is visible under /workspace anyway.
    static func readOnlyRejection(_ folder: URL, home: URL, project: URL, workspace: URL) -> String? {
        if let reason = mountRejection(folder, home: home, protected: [project]) { return reason }
        if let prefix = partInWorkspace(folder, workspace: workspace) {
            return "\(prefix) is in the workspace \(resolvedPath(workspace)), which the sandbox can change."
        }
        return nil
    }

    // Returns the first leading part of the path that is the workspace or inside it once links are resolved,
    // such as ~/AgentWorkspace/link in ~/AgentWorkspace/link/data, or nil when no part of it is.
    // The path is standardized first, removing any "..", which is also the path that is later mounted or written.
    static func partInWorkspace(_ url: URL, workspace: URL) -> String? {
        let root = resolvedPath(workspace)
        var prefix = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            prefix.appendPathComponent(component)
            if isSame(resolvedPath(prefix), orInside: root) { return prefix.path }
        }
        return nil
    }

    static func load() -> Settings {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        func expand(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        var problems: [String] = []
        // The code that runs this server on the Mac must not be changeable from the sandbox: the app bundle
        // when the server ships inside MacControl.app, or the project when it runs from <project>/.build.
        // Use the real executable path, since the name the server was started with may be relative or a link.
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let project: URL
        if let range = executable.path.range(of: ".app/Contents/") {
            project = URL(fileURLWithPath: String(executable.path[..<range.lowerBound]) + ".app")
        } else {
            project = executable.deletingLastPathComponent().deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: project.appendingPathComponent("Sources/MacExec").path) {
                problems.append("Could not find the mac-control-mcp project next to \(executable.path); run the server from its .build folder.")
            }
        }
        let workspace = expand(env["MAC_EXEC_WORKSPACE"] ?? "~/AgentWorkspace")
        if let reason = mountRejection(workspace, home: home, protected: [project]) {
            problems.append("MAC_EXEC_WORKSPACE cannot be used: \(reason)")
        } else if !FileManager.default.fileExists(atPath: workspace.path) {
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            } catch {
                problems.append("Could not create the workspace \(workspace.path): \(error.localizedDescription)")
            }
        }
        var readOnly: [URL] = []
        for entry in (env["MAC_EXEC_READONLY_DIRS"] ?? "").split(separator: ":") where !entry.isEmpty {
            let folder = expand(String(entry))
            var isDirectory: ObjCBool = false
            if let reason = readOnlyRejection(folder, home: home, project: project, workspace: workspace) {
                problems.append("MAC_EXEC_READONLY_DIRS entry \(folder.path) cannot be shared: \(reason)")
            } else if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                problems.append("MAC_EXEC_READONLY_DIRS entry \(folder.path) is not a folder.")
            } else {
                readOnly.append(folder)
            }
        }
        let auditLog = expand(env["MAC_EXEC_AUDIT_LOG"] ?? "~/Library/Logs/mac-exec/audit.log")
        // The sandbox can write the workspace, so a log there, or a link on the way to it, could be replaced
        // to send the log to another file.
        var auditLogProblem: String?
        if let prefix = Settings.partInWorkspace(auditLog, workspace: workspace) {
            let message = "MAC_EXEC_AUDIT_LOG \(auditLog.path) is in or reached through the workspace (\(prefix)), which the sandbox can change; choose a log outside it."
            auditLogProblem = message
            problems.append(message)
        }
        if ContainerRuntime.requestedKind(env) == nil {
            problems.append("MAC_EXEC_RUNTIME is \"\(env["MAC_EXEC_RUNTIME"] ?? "")\"; use docker or apple.")
        }
        let runtime = ContainerRuntime.find(env)
        // A setting that cannot be honored stops every command, rather than running with the network on.
        let network = SandboxNetwork(rawValue: env["MAC_EXEC_NETWORK"] ?? SandboxNetwork.bridge.rawValue)
        if network == nil {
            problems.append("MAC_EXEC_NETWORK is \"\(env["MAC_EXEC_NETWORK"] ?? "")\"; use bridge or none.")
        } else if let network, let runtime, !runtime.supports(network) {
            problems.append("MAC_EXEC_NETWORK is \(network.rawValue). \(ContainerRuntime.appleNeedsNetwork)")
        }
        return Settings(
            home: home, workspace: workspace, readOnlyDirs: readOnly, project: project,
            allowHost: env["MAC_EXEC_ALLOW_HOST"] == "1",
            image: env["MAC_EXEC_IMAGE"] ?? defaultImage,
            network: network ?? .disabled,
            runtime: runtime,
            auditLog: auditLog, auditLogProblem: auditLogProblem,
            problems: problems
        )
    }

}

private final class MacExecServer: MCPServer {
    private let settings = Settings.load()
    // The client's own name from initialize, such as claude-ai or codex, so the audit log shows who ran what.
    private var client: String?
    // The running call's cancellation; calls run one at a time.
    private var cancellation = Cancellation()
    // Whether to look for containers left behind before the next sandbox command: at first, since an earlier
    // server may have been killed during a command, and after a command was stopped, since the runtime may have
    // created its container after the kill was sent.
    private var sweepContainers = true

    var tools: [[String: Any]] {
        // The two exec tools take the same command, run by different shells.
        func command(runBy shell: String) -> [String: Any] {
            ["type": "string", "maxLength": maxCommandLength, "description": "The command, run by \(shell)."]
        }
        let timeout: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 600, "description": "Seconds before the command is stopped. Default 120."]
        let path: [String: Any] = ["type": "string", "description": "Path relative to the workspace, or under /workspace."]
        let runs: [String: Any] = ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]
        // Output schemas name the fields agents rely on. Objects stay open, so a field added later is no error.
        func output(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let string: [String: Any] = ["type": "string"]
        let boolean: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": "integer"]
        let ran = output([
            "exit_code": integer, "stdout": string, "stderr": string,
            "timed_out": boolean, "duration_ms": integer,
            "output_truncated": ["type": "boolean", "description": "stdout or stderr was cut to the output limit."]
        ], required: ["exit_code", "stdout", "stderr", "timed_out", "output_truncated", "duration_ms"])
        var list: [[String: Any]] = [
            [
                "name": "exec_status",
                "description": "Report the sandbox runtime (Docker or Apple container) and whether it is ready, whether the sandbox image is built, whether containers get a network, the workspace folder, read-only folders, and whether host_exec is enabled. Call this first.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                "outputSchema": output([
                    "runtime": ["type": ["string", "null"]], "runtime_ready": boolean, "image_present": boolean,
                    "network": ["type": "string", "enum": ["bridge", "none"]], "workspace": string, "readonly_dirs": ["type": "array", "items": string], "host_exec_enabled": boolean,
                    "problems": ["type": "array", "items": string], "next_step": string
                ], required: ["runtime", "runtime_ready", "image_present", "workspace", "readonly_dirs", "host_exec_enabled", "problems"]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "sandbox_exec",
                "description": "Run a bash command in a fresh, isolated Linux container. The workspace is mounted read-write at /workspace and is the only place where files persist; read-only folders are under /mnt/readonly. The container runs as a non-root user with a read-only system, no added privileges, and \(settings.network == .disabled ? "no network access" : "internet access"). It cannot run macOS programs or see the rest of the Mac.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["command": command(runBy: "bash -c"), "cwd": path, "timeout_seconds": timeout],
                    "required": ["command"], "additionalProperties": false
                ],
                "outputSchema": ran,
                "annotations": runs
            ],
            [
                "name": "sandbox_read_file",
                "description": "Read a UTF-8 text file from the workspace.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["path": path, "max_bytes": ["type": "integer", "minimum": 1, "maximum": maxFileBytes, "description": "Most bytes to read. Default \(defaultReadBytes)."]],
                    "required": ["path"], "additionalProperties": false
                ],
                "outputSchema": output(["path": string, "content": string, "truncated": boolean], required: ["path", "content", "truncated"]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "sandbox_write_file",
                "description": "Create or replace a text file in the workspace, creating folders as needed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": path, "content": ["type": "string", "description": "The text to write."],
                        "append": ["type": "boolean", "description": "Add to the end of the file instead of replacing it. Default false."]
                    ],
                    "required": ["path", "content"], "additionalProperties": false
                ],
                "outputSchema": output(["path": string, "bytes_written": integer, "appended": boolean], required: ["path", "bytes_written", "appended"]),
                "annotations": ["readOnlyHint": false, "destructiveHint": true]
            ],
            [
                "name": "sandbox_list",
                "description": "List a folder in the workspace with each entry's type and size.",
                "inputSchema": ["type": "object", "properties": ["path": path], "additionalProperties": false],
                "outputSchema": output([
                    "path": string, "truncated": boolean,
                    "entries": ["type": "array", "items": output([
                        "name": string, "type": ["type": "string", "enum": ["file", "folder", "link", "other"]], "bytes": integer
                    ], required: ["name", "type", "bytes"])]
                ], required: ["path", "entries", "truncated"]),
                "annotations": ["readOnlyHint": true]
            ],
        ]
        if settings.allowHost {
            list.append([
                "name": "host_exec",
                "description": "Run a zsh command directly on the Mac, outside the sandbox, with the user's full permissions. Use only when the task cannot be done in sandbox_exec, for example to run a macOS program. sudo is refused.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "command": command(runBy: "a zsh login shell"),
                        "reason": ["type": "string", "minLength": 10, "maxLength": 500, "description": "Why sandbox_exec cannot do this task."],
                        "cwd": ["type": "string", "description": "Absolute folder on the Mac. Default is the home folder."],
                        "timeout_seconds": timeout
                    ],
                    "required": ["command", "reason"], "additionalProperties": false
                ],
                "outputSchema": ran,
                "annotations": runs
            ])
        }
        return list
    }

    let name = "mac-exec"
    let instructions = "Run commands with sandbox_exec, and keep files in the workspace. Use host_exec, when it is available, only when the sandbox cannot do the task, and explain why in reason."

    func initialized(_ params: [String: Any]) {
        if let clientName = (params["clientInfo"] as? [String: Any])?["name"] as? String {
            let cleaned = String(clientName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
            client = cleaned.isEmpty ? nil : String(cleaned.prefix(64))
        }
    }

    func answer(tool name: String, arguments: [String: Any], cancellation: Cancellation) -> [String: Any] {
        self.cancellation = cancellation
        do {
            return toolResult(try callTool(name, arguments))
        } catch {
            return ["content": [textContent(String(describing: error))], "isError": true]
        }
    }

    private func callTool(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "exec_status": return status()
        case "sandbox_exec": return try sandboxExec(args)
        case "sandbox_read_file": return try readFile(args)
        case "sandbox_write_file": return try writeFile(args)
        case "sandbox_list": return try list(args)
        case "host_exec" where settings.allowHost: return try hostExec(args)
        case "host_exec": throw ToolFailure("host_exec is turned off. Use sandbox_exec, or ask the user to set MAC_EXEC_ALLOW_HOST=1 in the client configuration.")
        default: throw ToolFailure("Unknown tool: \(name)")
        }
    }

    // MARK: Argument checks

    private func requireUsableWorkspace() throws {
        if !settings.problems.isEmpty { throw ToolFailure(settings.problems.joined(separator: " ")) }
    }

    private func string(_ args: [String: Any], _ key: String, max: Int) throws -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolFailure("\(key) must be a non-empty string.")
        }
        guard value.utf8.count <= max else { throw ToolFailure("\(key) is longer than \(max) bytes.") }
        return value
    }

    private func integer(_ args: [String: Any], _ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return value }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
            throw ToolFailure("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return number.intValue
    }

    private func workspacePath(_ args: [String: Any], _ key: String, default fallback: String? = nil) throws -> URL {
        let raw: String
        if args[key] == nil, let fallback { raw = fallback } else { raw = try string(args, key, max: 4096) }
        guard let url = resolveInWorkspace(raw, workspace: settings.workspace) else {
            throw ToolFailure("\(key) must stay inside the workspace (\(settings.workspace.path)); \"\(raw)\" does not.")
        }
        return url
    }

    // MARK: Audit log

    // Every command is logged before it runs. If the log cannot be written, the command does not run.
    private func audit(_ entry: [String: Any]) throws {
        if let problem = settings.auditLogProblem { throw ToolFailure("\(problem) Nothing was run.") }
        var record = entry
        record["time"] = ISO8601DateFormatter().string(from: Date())
        if let client { record["client"] = client }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            throw ToolFailure("Could not encode the audit record; nothing was run.")
        }
        let directory = settings.auditLog.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // O_NOFOLLOW: never append to another file through a link put in the log's place.
            // O_NONBLOCK: a FIFO there fails at once instead of waiting for a reader; it is refused below.
            func openLog() throws -> (fd: Int32, info: stat) {
                let fd = open(settings.auditLog.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw POSIXError(.EFTYPE) }
                guard info.st_uid == getuid() else { close(fd); throw POSIXError(.EPERM) }
                return (fd, info)
            }
            var (fd, info) = try openLog()
            // A full log becomes audit.log.1, replacing the one before, so the log keeps at most twice the limit.
            // The lock keeps two servers from both moving it; the inode check sees that another one already did.
            if info.st_size >= auditLogLimit {
                var current = stat()
                if flock(fd, LOCK_EX) == 0, lstat(settings.auditLog.path, &current) == 0, current.st_ino == info.st_ino,
                   rename(settings.auditLog.path, settings.auditLog.path + ".1") != 0 {
                    // The entry is still written; a log that cannot be moved only keeps growing.
                    FileHandle.standardError.write(Data("mac-exec: could not move the full audit log aside: \(String(cString: strerror(errno)))\n".utf8))
                }
                close(fd)
                (fd, info) = try openLog()
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            if info.st_mode & 0o077 != 0, fchmod(fd, 0o600) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
            try handle.write(contentsOf: data + Data([0x0a]))
        } catch {
            throw ToolFailure("Could not write the audit log \(settings.auditLog.path): \(error.localizedDescription); nothing was run.")
        }
    }

    // MARK: Tools

    private func status() -> [String: Any] {
        var info: [String: Any] = [
            "workspace": settings.workspace.path,
            "readonly_dirs": settings.readOnlyDirs.map(\.path),
            "host_exec_enabled": settings.allowHost,
            "image": settings.image,
            "network": settings.network.rawValue,
            "audit_log": settings.auditLog.path,
            "problems": settings.problems,
            "runtime": settings.runtime?.kind.rawValue ?? NSNull(),
            "runtime_program": settings.runtime?.program ?? NSNull(),
        ]
        var ready = false
        if let runtime = settings.runtime {
            let check = try? runProcess(runtime.program, runtime.readyArguments(), environment: runtime.environment,
                                        timeout: 15, outputLimit: 1000)
            ready = check?.exitCode == 0
            if runtime.kind == .docker, ready {
                info["docker_version"] = check!.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let image = try? runProcess(runtime.program, runtime.imageExistsArguments(settings.image),
                                        environment: runtime.environment, timeout: 15, outputLimit: 1000)
            info["image_present"] = image?.exitCode == 0
        } else {
            info["image_present"] = false
        }
        info["runtime_ready"] = ready
        info["docker_running"] = ready // kept for clients that read the earlier field name
        if info["image_present"] as? Bool != true {
            info["next_step"] = "Open MacControl.app to install the sandbox runtime and build the image, or run sh scripts/build-sandbox.sh in the mac-control-mcp folder."
        }
        return info
    }

    private func sandboxExec(_ args: [String: Any]) throws -> [String: Any] {
        let command = try string(args, "command", max: maxCommandLength)
        let timeout = try integer(args, "timeout_seconds", default: 120, range: 1...600)
        try requireUsableWorkspace()
        let cwd = try workspacePath(args, "cwd", default: ".")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolFailure("cwd is not a folder in the workspace.")
        }
        guard let runtime = settings.runtime else {
            throw ToolFailure("No sandbox runtime was found. Open MacControl.app to install one, or install Docker and set MAC_EXEC_DOCKER.")
        }
        try ensureRuntimeRunning(runtime)
        let root = resolvedPath(settings.workspace)
        let containerCwd = "/workspace" + String(cwd.path.dropFirst(root.count))
        if sweepContainers { sweepContainers = try !removeLeftoverContainers(runtime) }
        let name = ContainerOwner.current.containerName()
        var readOnly: [(source: String, target: String)] = []
        var used: Set<String> = []
        for folder in settings.readOnlyDirs {
            var target = folder.lastPathComponent, suffix = 2
            while used.contains(target) { target = "\(folder.lastPathComponent)-\(suffix)"; suffix += 1 }
            used.insert(target)
            // Check again what the folder resolves to now, since links in its path may have changed since startup,
            // and mount exactly the path that was checked. The sandbox cannot change links outside the workspace,
            // so only another program on the Mac could still swap one between this check and the mount.
            let source = resolvedPath(folder)
            if let reason = Settings.readOnlyRejection(URL(fileURLWithPath: source), home: settings.home,
                                                       project: settings.project, workspace: settings.workspace) {
                throw ToolFailure("MAC_EXEC_READONLY_DIRS entry \(folder.path) can no longer be shared: \(reason) Nothing was run.")
            }
            readOnly.append((source, "/mnt/readonly/\(target)"))
        }
        let arguments = try runtime.runArguments(SandboxRun(name: name, image: settings.image, workspace: root,
                                                        readOnly: readOnly, workdir: containerCwd, command: command,
                                                        network: settings.network))
        if runtime.checksImageBeforeRun {
            let inspect = try runProcess(runtime.program, runtime.imageExistsArguments(settings.image), environment: runtime.environment,
                                         timeout: 30, outputLimit: 1000, cancellation: cancellation)
            try cancellation.check()
            if inspect.timedOut {
                throw ToolFailure("The container runtime did not answer within 30 seconds when checking the sandbox image. Nothing was run; try again.")
            }
            if inspect.exitCode != 0 {
                if inspect.stderr.lowercased().contains("not found") { throw missingImage() }
                throw ToolFailure("Could not check the sandbox image \(settings.image), so nothing was run: \(inspect.stderr.suffix(400))")
            }
        }

        try audit(["tool": "sandbox_exec", "event": "start", "command": command, "cwd": containerCwd, "container": name,
                   "runtime": runtime.kind.rawValue])
        let result = try runProcess(runtime.program, arguments, environment: runtime.environment,
                                    timeout: TimeInterval(timeout), outputLimit: outputLimit, cancellation: cancellation) {
            _ = try? runProcess(runtime.program, runtime.killArguments(name), environment: runtime.environment,
                                timeout: 15, outputLimit: 1000)
        }
        if result.timedOut || result.cancelled { sweepContainers = true }
        try? audit(["tool": "sandbox_exec", "event": "end", "container": name, "exit_code": result.exitCode,
                    "timed_out": result.timedOut, "cancelled": result.cancelled, "duration_ms": result.durationMs])
        if runtime.isMissingImage(result, image: settings.image) { throw missingImage() }
        return resultJSON(result)
    }

    private func missingImage() -> ToolFailure {
        ToolFailure("The sandbox image \(settings.image) is missing. Open MacControl.app to build it, or run sh scripts/build-sandbox.sh in the mac-control-mcp folder.")
    }

    // MacControl.app tells the server how to start the runtime it installed, so the first sandbox command
    // after a restart starts the VM instead of failing. Without that information, nothing is started.
    private func ensureRuntimeRunning(_ runtime: ContainerRuntime) throws {
        let ready = try? runProcess(runtime.program, runtime.readyArguments(), environment: runtime.environment,
                                    timeout: 20, outputLimit: 1000, cancellation: cancellation)
        try cancellation.check()
        if ready?.exitCode == 0 { return }
        let env = ProcessInfo.processInfo.environment
        let program: String, arguments: [String]
        var startEnvironment = runtime.environment
        switch runtime.kind {
        case .docker:
            guard let colima = env["MAC_EXEC_COLIMA"], let profile = env["MAC_EXEC_COLIMA_PROFILE"] else { return }
            program = colima
            arguments = ["start", "--profile", profile]
            if let path = env["MAC_EXEC_COLIMA_PATH"] { startEnvironment["PATH"] = path }
            // Colima's docker context changes go to the app's own Docker settings, not the user's.
            if let config = env["MAC_EXEC_COLIMA_DOCKER_CONFIG"] { startEnvironment["DOCKER_CONFIG"] = config }
            startEnvironment.removeValue(forKey: "DOCKER_HOST")
        case .apple:
            program = runtime.program
            arguments = ["system", "start", "--enable-kernel-install"]
        }
        try audit(["tool": "sandbox_exec", "event": "start_runtime", "command": ([program] + arguments).joined(separator: " ")])
        let started = try runProcess(program, arguments, environment: startEnvironment, timeout: 600, outputLimit: 20_000,
                                     cancellation: cancellation)
        try cancellation.check()
        guard started.exitCode == 0 else {
            throw ToolFailure("The sandbox runtime was not running and could not be started: \(started.stderr.suffix(500)) Open MacControl.app to check it.")
        }
    }

    // Removes sandbox containers that are no longer wanted. Best effort: a failure here must not stop the command,
    // but returns false so the next command tries again. Only cancellation is thrown.
    private func removeLeftoverContainers(_ runtime: ContainerRuntime) throws -> Bool {
        guard let list = runtime.listArguments() else { return true }
        let listed = try? runProcess(runtime.program, list, environment: runtime.environment, timeout: 15,
                                     outputLimit: 100_000, cancellation: cancellation)
        try cancellation.check()
        guard let listed, listed.exitCode == 0 else { return false }
        let names = listed.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let leftovers = ContainerOwner.leftovers(names, me: .current, startOf: ContainerOwner.processStart)
        guard !leftovers.isEmpty else { return true }
        try? audit(["tool": "sandbox_exec", "event": "remove_leftovers", "containers": leftovers])
        _ = try? runProcess(runtime.program, runtime.removeArguments(leftovers), environment: runtime.environment,
                            timeout: 30, outputLimit: 1000, cancellation: cancellation)
        try cancellation.check()
        return true
    }

    private func hostExec(_ args: [String: Any]) throws -> [String: Any] {
        let command = try string(args, "command", max: maxCommandLength)
        let reason = try string(args, "reason", max: 500)
        guard reason.count >= 10 else { throw ToolFailure("reason must explain in at least 10 characters why the sandbox is not enough.") }
        let timeout = try integer(args, "timeout_seconds", default: 120, range: 1...600)
        // A best-effort guard against privilege escalation, not a security boundary: the client's
        // approval prompt is what lets the user stop a command.
        if command.range(of: #"(^|[^A-Za-z0-9_.-])(sudo|su|doas)([^A-Za-z0-9_.-]|$)"#, options: .regularExpression) != nil {
            throw ToolFailure("host_exec refuses sudo, su, and doas. Ask the user to run commands that need administrator rights.")
        }
        var cwd = settings.home
        if args["cwd"] != nil {
            let raw = try string(args, "cwd", max: 4096)
            guard raw.hasPrefix("/") || raw.hasPrefix("~") else { throw ToolFailure("cwd must be an absolute folder.") }
            cwd = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolFailure("cwd \(cwd.path) is not a folder.")
        }
        try audit(["tool": "host_exec", "event": "start", "command": command, "reason": reason, "cwd": cwd.path])
        // The folder and command are passed as arguments, never pasted into the script, so neither is reinterpreted.
        let script = #"cd -- "$1" || exit 125; eval "$2""#
        let result = try runProcess("/bin/zsh", ["-lc", script, "zsh", cwd.path, command],
                                    timeout: TimeInterval(timeout), outputLimit: outputLimit, cancellation: cancellation)
        try? audit(["tool": "host_exec", "event": "end", "exit_code": result.exitCode,
                    "timed_out": result.timedOut, "cancelled": result.cancelled, "duration_ms": result.durationMs])
        return resultJSON(result)
    }

    // File tools go through WorkspaceFiles, which never follows a link the sandbox may have swapped in.
    private var files: WorkspaceFiles { WorkspaceFiles(root: resolvedPath(settings.workspace)) }

    private func readFile(_ args: [String: Any]) throws -> [String: Any] {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path")
        let limit = try integer(args, "max_bytes", default: defaultReadBytes, range: 1...maxFileBytes)
        let handle: FileHandle
        do { handle = try files.openFile(url.path, flags: O_RDONLY) } catch {
            throw ToolFailure("Cannot read \(displayPath(url)): \(error)")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard let text = utf8Text(data, limit: limit) else {
            throw ToolFailure("\(displayPath(url)) is not UTF-8 text. Use sandbox_exec, for example with base64 or xxd.")
        }
        return ["path": displayPath(url), "content": text, "truncated": data.count > limit]
    }

    private func writeFile(_ args: [String: Any]) throws -> [String: Any] {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path")
        guard let content = args["content"] as? String else { throw ToolFailure("content must be a string.") }
        let data = Data(content.utf8)
        guard data.count <= maxFileBytes else { throw ToolFailure("content is larger than \(maxFileBytes) bytes.") }
        let append = args["append"] as? Bool ?? false
        let flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC)
        do {
            let handle = try files.openFile(url.path, flags: flags, createFolders: true)
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            throw ToolFailure("Cannot write \(displayPath(url)): \(error)")
        }
        return ["path": displayPath(url), "bytes_written": data.count, "appended": append]
    }

    private func list(_ args: [String: Any]) throws -> [String: Any] {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path", default: ".")
        do {
            let (entries, truncated) = try files.list(url.path, limit: maxListEntries)
            return ["path": displayPath(url), "entries": entries, "truncated": truncated]
        } catch {
            throw ToolFailure("Cannot list \(displayPath(url)): \(error)")
        }
    }

    // Decodes at most `limit` bytes as UTF-8. When the limit cuts through a character, the 1 to 3
    // bytes of it that fit are dropped instead of making the whole text invalid.
    private func utf8Text(_ data: Data, limit: Int) -> String? {
        let cut = data.prefix(limit)
        for drop in 0...(data.count > limit ? min(3, cut.count) : 0) {
            if let text = String(data: cut.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    // MARK: Output

    // Paths are shown as the container sees them, so they can be passed straight to sandbox_exec.
    private func displayPath(_ url: URL) -> String {
        let root = resolvedPath(settings.workspace)
        return "/workspace" + String(resolvedPath(url).dropFirst(root.count))
    }

    private func resultJSON(_ result: RunResult) -> [String: Any] {
        [
            "exit_code": result.exitCode, "stdout": result.stdout, "stderr": result.stderr,
            "timed_out": result.timedOut, "output_truncated": result.truncated, "duration_ms": result.durationMs
        ]
    }
}

@main
private enum Main {
    static func main() { MacExecServer().serve(stoppingOnSignals: true) }
}
