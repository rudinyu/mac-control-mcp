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
    let allowHost: Bool
    let image: String
    let docker: String?
    let auditLog: URL
    let problems: [String]

    static func load() -> Settings {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        func expand(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        var problems: [String] = []
        // The server runs from <project>/.build, and the project's scripts run on the Mac.
        let project = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent()
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
            if let reason = mountRejection(folder, home: home, protected: [project]) {
                problems.append("MAC_EXEC_READONLY_DIRS entry \(folder.path) cannot be shared: \(reason)")
            } else if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                problems.append("MAC_EXEC_READONLY_DIRS entry \(folder.path) is not a folder.")
            } else {
                readOnly.append(folder)
            }
        }
        return Settings(
            home: home, workspace: workspace, readOnlyDirs: readOnly,
            allowHost: env["MAC_EXEC_ALLOW_HOST"] == "1",
            image: env["MAC_EXEC_IMAGE"] ?? defaultImage,
            docker: findDocker(env),
            auditLog: expand(env["MAC_EXEC_AUDIT_LOG"] ?? "~/Library/Logs/mac-exec/audit.log"),
            problems: problems
        )
    }

    // MCP clients such as Claude Desktop start servers with a short PATH, so look in the usual places too.
    private static func findDocker(_ env: [String: String]) -> String? {
        if let explicit = env["MAC_EXEC_DOCKER"] { return explicit }
        let candidates = (env["PATH"] ?? "").split(separator: ":").map { "\($0)/docker" } + [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private final class MacExecServer {
    private let settings = Settings.load()

    private var tools: [[String: Any]] {
        let command: [String: Any] = ["type": "string", "maxLength": maxCommandLength]
        let timeout: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 600, "description": "Seconds before the command is stopped. Default 120."]
        let path: [String: Any] = ["type": "string", "description": "Path relative to the workspace, or under /workspace."]
        let runs: [String: Any] = ["destructiveHint": true, "openWorldHint": true]
        var list: [[String: Any]] = [
            [
                "name": "exec_status",
                "description": "Report whether Docker and the sandbox image are available, the workspace folder, read-only folders, and whether host_exec is enabled. Call this first.",
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
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            throw ToolFailure("Could not encode the audit record; nothing was run.")
        }
        let directory = settings.auditLog.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: settings.auditLog.path) {
                FileManager.default.createFile(atPath: settings.auditLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: settings.auditLog)
            defer { try? handle.close() }
            try handle.seekToEnd()
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
            "docker": settings.docker ?? NSNull(),
        ]
        if let docker = settings.docker {
            let daemon = try? runProcess(docker, ["info", "--format", "{{.ServerVersion}}"], environment: dockerEnvironment(docker),
                                         timeout: 15, outputLimit: 1000)
            info["docker_running"] = daemon?.exitCode == 0
            info["docker_version"] = daemon?.exitCode == 0 ? daemon!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : NSNull()
            let image = try? runProcess(docker, ["image", "inspect", "--format", "{{.Id}}", settings.image],
                                        environment: dockerEnvironment(docker), timeout: 15, outputLimit: 1000)
            info["image_present"] = image?.exitCode == 0
        } else {
            info["docker_running"] = false
            info["image_present"] = false
        }
        if info["image_present"] as? Bool != true {
            info["next_step"] = "Start Docker Desktop, then run sh scripts/build-sandbox.sh in the mac-control-mcp folder."
        }
        return jsonString(info)
    }

    private func dockerEnvironment(_ docker: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dockerDir = (docker as NSString).deletingLastPathComponent
        env["PATH"] = [dockerDir, env["PATH"] ?? "", "/usr/local/bin", "/usr/bin", "/bin"].filter { !$0.isEmpty }.joined(separator: ":")
        return env
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
        guard let docker = settings.docker else {
            throw ToolFailure("Docker was not found. Install and start Docker Desktop, or set MAC_EXEC_DOCKER to the docker program.")
        }
        let root = resolvedPath(settings.workspace)
        let containerCwd = "/workspace" + String(cwd.path.dropFirst(root.count))
        let name = "mac-exec-\(UUID().uuidString.lowercased())"
        var arguments = [
            "run", "--rm", "--init", "--name", name, "--label", "mac-exec=1",
            "--user", "1000:1000", "--read-only",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=512m",
            "--tmpfs", "/home/agent:rw,nosuid,nodev,size=256m,uid=1000,gid=1000",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--pids-limit", "256", "--memory", "2g", "--memory-swap", "2g", "--cpus", "2",
            "--network", "bridge",
            "--mount", "type=bind,source=\(root),target=/workspace",
            "--workdir", containerCwd,
        ]
        var used: Set<String> = []
        for folder in settings.readOnlyDirs {
            var target = folder.lastPathComponent, suffix = 2
            while used.contains(target) { target = "\(folder.lastPathComponent)-\(suffix)"; suffix += 1 }
            used.insert(target)
            arguments += ["--mount", "type=bind,source=\(resolvedPath(folder)),target=/mnt/readonly/\(target),readonly"]
        }
        arguments += [settings.image, "bash", "-c", command]

        try audit(["tool": "sandbox_exec", "event": "start", "command": command, "cwd": containerCwd, "container": name])
        let env = dockerEnvironment(docker)
        let result = try runProcess(docker, arguments, environment: env, timeout: TimeInterval(timeout), outputLimit: outputLimit) {
            _ = try? runProcess(docker, ["kill", name], environment: env, timeout: 15, outputLimit: 1000)
        }
        try? audit(["tool": "sandbox_exec", "event": "end", "container": name, "exit_code": result.exitCode,
                    "timed_out": result.timedOut, "duration_ms": result.durationMs])
        // docker run exits with 125 when it cannot start the container at all.
        if result.exitCode == 125, result.stderr.contains("Unable to find image") || result.stderr.contains("No such image") {
            throw ToolFailure("The sandbox image \(settings.image) is missing. Run sh scripts/build-sandbox.sh in the mac-control-mcp folder.")
        }
        return resultJSON(result)
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

    private func readFile(_ args: [String: Any]) throws -> String {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path")
        let limit = try integer(args, "max_bytes", default: 200_000, range: 1...maxFileBytes)
        // The sandbox can create FIFOs and devices in the workspace; opening one would block the server.
        guard isRegularFile(url) else { throw ToolFailure("\(displayPath(url)) is not a regular file.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard let text = String(data: utf8Prefix(data, limit: limit), encoding: .utf8) else {
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
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ToolFailure("\(displayPath(url)) is a folder.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Creating folders can change what the path resolves to, so check it again before writing.
        guard resolveInWorkspace(displayPath(url), workspace: settings.workspace) != nil else {
            throw ToolFailure("path must stay inside the workspace.")
        }
        if FileManager.default.fileExists(atPath: url.path), !isRegularFile(url) {
            throw ToolFailure("\(displayPath(url)) is not a regular file.")
        }
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        return jsonString(["path": displayPath(url), "bytes_written": data.count, "appended": append])
    }

    private func list(_ args: [String: Any]) throws -> String {
        try requireUsableWorkspace()
        let url = try workspacePath(args, "path", default: ".")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        var entries: [[String: Any]] = []
        for name in names.prefix(maxListEntries) {
            let child = url.appendingPathComponent(name)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: child.path)) ?? [:]
            let type: String
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: type = "folder"
            case .typeSymbolicLink?: type = "link"
            case .typeRegular?: type = "file"
            default: type = "other"
            }
            entries.append(["name": name, "type": type, "bytes": (attributes[.size] as? NSNumber)?.intValue ?? 0])
        }
        return jsonString(["path": displayPath(url), "entries": entries, "truncated": names.count > maxListEntries])
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    // Cuts data to at most `limit` bytes without ending inside a UTF-8 character.
    private func utf8Prefix(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        var end = limit
        // Step back over continuation bytes (10xxxxxx) to the start of the character, then drop it
        // if the whole character does not fit.
        var start = end
        while start > 0, data[data.startIndex + start - 1] & 0xC0 == 0x80, end - start < 3 { start -= 1 }
        if start > 0 {
            let lead = data[data.startIndex + start - 1]
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if length > 1, end - (start - 1) < length { end = start - 1 }
        }
        return data.prefix(end)
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
