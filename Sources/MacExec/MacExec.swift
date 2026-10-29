import Foundation

private let serverVersion = "0.1.0"
private let supportedProtocolVersions: Set<String> = [
    "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
]
private let defaultImage = "mac-exec-sandbox:latest"
private let outputLimit = 100_000
private let maxCommandLength = 20_000
private let maxFileBytes = 1_000_000
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
    let runtime: ContainerRuntime?
    let auditLog: URL
    let problems: [String]

    // A read-only folder inside the workspace is refused: the sandbox could replace it with a link between
    // runs, and it is visible under /workspace anyway.
    static func readOnlyRejection(_ folder: URL, home: URL, project: URL, workspace: URL) -> String? {
        if let reason = mountRejection(folder, home: home, protected: [project]) { return reason }
        let path = resolvedPath(folder), root = resolvedPath(workspace)
        if isSame(path, orInside: root) { return "\(path) is inside the workspace \(root), which the sandbox can change." }
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
        // The sandbox can write the workspace, so a log there could be replaced with a link to another file.
        if isSame(resolvedPath(auditLog), orInside: resolvedPath(workspace)) {
            problems.append("MAC_EXEC_AUDIT_LOG \(auditLog.path) is inside the workspace, which the sandbox can change; choose a log outside it.")
        }
        if ContainerRuntime.requestedKind(env) == nil {
            problems.append("MAC_EXEC_RUNTIME is \"\(env["MAC_EXEC_RUNTIME"] ?? "")\"; use docker or apple.")
        }
        return Settings(
            home: home, workspace: workspace, readOnlyDirs: readOnly, project: project,
            allowHost: env["MAC_EXEC_ALLOW_HOST"] == "1",
            image: env["MAC_EXEC_IMAGE"] ?? defaultImage,
            runtime: ContainerRuntime.find(env),
            auditLog: auditLog,
            problems: problems
        )
    }

}

private final class MacExecServer {
    private let settings = Settings.load()
    // The client's own name from initialize, such as claude-ai or codex, so the audit log shows who ran what.
    private var client: String?

    private var tools: [[String: Any]] {
        let command: [String: Any] = ["type": "string", "maxLength": maxCommandLength]
        let timeout: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 600, "description": "Seconds before the command is stopped. Default 120."]
        let path: [String: Any] = ["type": "string", "description": "Path relative to the workspace, or under /workspace."]
        let runs: [String: Any] = ["destructiveHint": true, "openWorldHint": true]
        var list: [[String: Any]] = [
            [
                "name": "exec_status",
                "description": "Report the sandbox runtime (Docker or Apple container) and whether it is ready, whether the sandbox image is built, the workspace folder, read-only folders, and whether host_exec is enabled. Call this first.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "sandbox_exec",
                "description": "Run a bash command in a fresh, isolated Linux container. The workspace is mounted read-write at /workspace and is the only place where files persist; read-only folders are under /mnt/readonly. The container runs as a non-root user with a read-only system, no added privileges, and internet access. It cannot run macOS programs or see the rest of the Mac.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["command": command, "cwd": path, "timeout_seconds": timeout],
                    "required": ["command"], "additionalProperties": false
                ],
                "annotations": runs
            ],
            [
                "name": "sandbox_read_file",
                "description": "Read a UTF-8 text file from the workspace.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["path": path, "max_bytes": ["type": "integer", "minimum": 1, "maximum": maxFileBytes]],
                    "required": ["path"], "additionalProperties": false
                ],
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "sandbox_write_file",
                "description": "Create or replace a text file in the workspace, creating folders as needed. Set append to add to the end instead.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["path": path, "content": ["type": "string"], "append": ["type": "boolean"]],
                    "required": ["path", "content"], "additionalProperties": false
                ],
                "annotations": ["destructiveHint": true]
            ],
            [
                "name": "sandbox_list",
                "description": "List a folder in the workspace with each entry's type and size.",
                "inputSchema": ["type": "object", "properties": ["path": path], "additionalProperties": false],
                "annotations": ["readOnlyHint": true]
            ],
        ]
        if settings.allowHost {
            list.append([
                "name": "host_exec",
                "description": "Run a zsh command directly on the Mac, outside the sandbox, with the user's full permissions. Use only when the task cannot be done in sandbox_exec, for example to run a macOS program. reason must say why the sandbox is not enough. sudo is refused.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "command": command,
                        "reason": ["type": "string", "minLength": 10, "maxLength": 500],
                        "cwd": ["type": "string", "description": "Absolute folder on the Mac. Default is the home folder."],
                        "timeout_seconds": timeout
                    ],
                    "required": ["command", "reason"], "additionalProperties": false
                ],
                "annotations": runs
            ])
        }
        return list
    }

    func serve() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    send(error: -32600, message: "Invalid JSON-RPC request", id: NSNull())
                    continue
                }
                handle(message)
            } catch {
                send(error: -32700, message: "Invalid JSON", id: NSNull())
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String else {
            send(error: -32600, message: "Missing method", id: message["id"] ?? NSNull())
            return
        }
        guard let id = message["id"] else { return } // MCP notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            if let name = (params["clientInfo"] as? [String: Any])?["name"] as? String {
                let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
                client = cleaned.isEmpty ? nil : String(cleaned.prefix(64))
            }
            let selected = supportedProtocolVersions.contains(requested) ? requested : "2025-11-25"
            send(result: [
                "protocolVersion": selected,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "mac-exec", "version": serverVersion],
                "instructions": "Run commands with sandbox_exec, and keep files in the workspace. Use host_exec, when it is available, only when the sandbox cannot do the task, and explain why in reason."
            ], id: id)
        case "ping":
            send(result: [:], id: id)
        case "tools/list":
            send(result: ["tools": tools], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else {
                send(error: -32602, message: "Missing tool name", id: id)
                return
            }
            do {
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                send(result: ["content": [["type": "text", "text": try callTool(name, arguments)]]], id: id)
            } catch {
                send(result: ["content": [["type": "text", "text": String(describing: error)]], "isError": true], id: id)
            }
        default:
            send(error: -32601, message: "Method not found", id: id)
        }
    }

    private func callTool(_ name: String, _ args: [String: Any]) throws -> String {
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
            let fd = open(settings.auditLog.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
            guard info.st_uid == getuid() else { throw POSIXError(.EPERM) }
            if info.st_mode & 0o077 != 0, fchmod(fd, 0o600) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
            try handle.write(contentsOf: data + Data([0x0a]))
        } catch {
            throw ToolFailure("Could not write the audit log \(settings.auditLog.path): \(error.localizedDescription); nothing was run.")
        }
    }

    // MARK: Tools

    private func status() -> String {
        var info: [String: Any] = [
            "workspace": settings.workspace.path,
            "readonly_dirs": settings.readOnlyDirs.map(\.path),
            "host_exec_enabled": settings.allowHost,
            "image": settings.image,
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
        return jsonString(info)
    }

    private func sandboxExec(_ args: [String: Any]) throws -> String {
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
        let name = "mac-exec-\(UUID().uuidString.lowercased())"
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
                                                        readOnly: readOnly, workdir: containerCwd, command: command))

        try audit(["tool": "sandbox_exec", "event": "start", "command": command, "cwd": containerCwd, "container": name,
                   "runtime": runtime.kind.rawValue])
        let result = try runProcess(runtime.program, arguments, environment: runtime.environment,
                                    timeout: TimeInterval(timeout), outputLimit: outputLimit) {
            _ = try? runProcess(runtime.program, runtime.killArguments(name), environment: runtime.environment,
                                timeout: 15, outputLimit: 1000)
        }
        try? audit(["tool": "sandbox_exec", "event": "end", "container": name, "exit_code": result.exitCode,
                    "timed_out": result.timedOut, "duration_ms": result.durationMs])
        if runtime.isMissingImage(result, image: settings.image) {
            throw ToolFailure("The sandbox image \(settings.image) is missing. Open MacControl.app to build it, or run sh scripts/build-sandbox.sh in the mac-control-mcp folder.")
        }
        return resultJSON(result)
    }

    // MacControl.app tells the server how to start the runtime it installed, so the first sandbox command
    // after a restart starts the VM instead of failing. Without that information, nothing is started.
    private func ensureRuntimeRunning(_ runtime: ContainerRuntime) throws {
        let ready = try? runProcess(runtime.program, runtime.readyArguments(), environment: runtime.environment,
                                    timeout: 20, outputLimit: 1000)
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
        let started = try runProcess(program, arguments, environment: startEnvironment, timeout: 600, outputLimit: 20_000)
        guard started.exitCode == 0 else {
            throw ToolFailure("The sandbox runtime was not running and could not be started: \(started.stderr.suffix(500)) Open MacControl.app to check it.")
        }
    }

    private func hostExec(_ args: [String: Any]) throws -> String {
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
                                    timeout: TimeInterval(timeout), outputLimit: outputLimit)
        try? audit(["tool": "host_exec", "event": "end", "exit_code": result.exitCode,
                    "timed_out": result.timedOut, "duration_ms": result.durationMs])
        return resultJSON(result)
    }

    // File tools go through WorkspaceFiles, which never follows a link the sandbox may have swapped in.
    private var files: WorkspaceFiles { WorkspaceFiles(root: resolvedPath(settings.workspace)) }

    private func readFile(_ args: [String: Any]) throws -> String {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path")
        let limit = try integer(args, "max_bytes", default: 200_000, range: 1...maxFileBytes)
        let handle: FileHandle
        do { handle = try files.openFile(url.path, flags: O_RDONLY) } catch {
            throw ToolFailure("Cannot read \(displayPath(url)): \(error)")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard let text = utf8Text(data, limit: limit) else {
            throw ToolFailure("\(displayPath(url)) is not UTF-8 text. Use sandbox_exec, for example with base64 or xxd.")
        }
        return jsonString(["path": displayPath(url), "content": text, "truncated": data.count > limit])
    }

    private func writeFile(_ args: [String: Any]) throws -> String {
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
        return jsonString(["path": displayPath(url), "bytes_written": data.count, "appended": append])
    }

    private func list(_ args: [String: Any]) throws -> String {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path", default: ".")
        do {
            let (entries, truncated) = try files.list(url.path, limit: maxListEntries)
            return jsonString(["path": displayPath(url), "entries": entries, "truncated": truncated])
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

    private func resultJSON(_ result: RunResult) -> String {
        jsonString([
            "exit_code": result.exitCode, "stdout": result.stdout, "stderr": result.stderr,
            "timed_out": result.timedOut, "output_truncated": result.truncated, "duration_ms": result.durationMs
        ])
    }

    private func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func send(result: Any, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, message: String, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

@main
private enum Main {
    static func main() { MacExecServer().serve() }
}
