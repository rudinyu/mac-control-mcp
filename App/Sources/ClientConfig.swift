import Foundation

// A server the app registers with an MCP client.
struct ServerSpec: Equatable {
    let name: String            // as Claude names it: "mac-control" or "mac-exec"
    let command: String         // absolute path of the helper inside the app
    let environment: [String: String]

    // Codex names servers with underscores.
    var codexName: String { name.replacingOccurrences(of: "-", with: "_") }
}

struct ConfigFailure: Error, CustomStringConvertible {
    let description: String
}

enum ClientConfig {
    static let managedNames = ["mac-control", "mac-exec"]

    // Whether a server's command is a helper inside an installed MacControl, of this version or another. A
    // development entry with the same name, such as one that runs a source build, is not this app's to remove.
    static func isAppCommand(_ command: String) -> Bool {
        command.contains(".app/Contents/") && ["mac-control-mcp", "mac-exec-mcp"].contains((command as NSString).lastPathComponent)
    }

    // Whether the output of `claude mcp get` or `codex mcp get` shows a command that is this app's helper. Both
    // print a "Command:" line (Codex in lower case); the whole rest of the line is the command, which may contain
    // spaces. If no such line is found, as the format may change, any word of the output that is the helper counts.
    static func describesAppCommand(_ output: String) -> Bool {
        let commands = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("command:") else { return nil }
            return trimmed.dropFirst("command:".count).trimmingCharacters(in: .whitespaces)
        }
        if !commands.isEmpty { return commands.contains(where: isAppCommand) }
        return output.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }).contains { isAppCommand(String($0)) }
    }

    // The names of this app's servers in Claude Desktop's configuration, leaving out entries with the same
    // names that run something else.
    private static func appServerNames(_ servers: [String: Any]) -> [String] {
        managedNames.filter { isAppCommand(((servers[$0] as? [String: Any])?["command"] as? String) ?? "") }
    }

    // A server's entry in Claude Code's user configuration, ~/.claude.json, saved to put back if replacing it fails.
    enum SavedEntry: Equatable {
        case none
        case restorable(String)     // as JSON for `claude mcp add-json`
        case notRestorable
    }

    // `add-json` takes the entry on its command line, where other processes can read it, so an entry with headers
    // or with environment variables other than this app's own settings, which hold only paths and flags, is not
    // put back automatically: they may hold tokens.
    static func claudeCodeEntry(_ configuration: Data?, name: String) -> SavedEntry {
        guard let configuration, let root = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[name] else { return .none }
        guard let entry = entry as? [String: Any],
              (entry["env"] as? [String: Any] ?? [:]).keys.allSatisfy({ $0.hasPrefix("MAC_EXEC_") }),
              (entry["headers"] as? [String: Any])?.isEmpty ?? true,
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return .notRestorable }
        return .restorable(text)
    }

    // Adds or replaces this app's servers in Claude Desktop's configuration and keeps everything else,
    // including other servers and settings. Malformed JSON is refused rather than overwritten. The text is
    // edited in place, so the rest of the file keeps its layout.
    static func mergeClaudeDesktop(_ existing: Data?, servers: [ServerSpec]) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw ConfigFailure(description: String(localized: "Claude Desktop's configuration is not valid JSON, so it was left unchanged. Fix or remove it, then try again."))
            }
            root = parsed
        }
        var mcpServers: [String: Any] = [:]
        if let current = root["mcpServers"] {
            guard let dictionary = current as? [String: Any] else {
                throw ConfigFailure(description: String(localized: "\"mcpServers\" in Claude Desktop's configuration is not an object, so it was left unchanged."))
            }
            mcpServers = dictionary
        }
        var entries: [String: Any] = [:]
        for server in servers {
            var entry: [String: Any] = ["command": server.command, "args": [String]()]
            if !server.environment.isEmpty { entry["env"] = server.environment }
            entries[server.name] = entry
        }
        mcpServers.merge(entries) { _, new in new }
        root["mcpServers"] = mcpServers
        let rewritten = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let existing, !existing.isEmpty, let text = String(data: existing, encoding: .utf8) else { return rewritten }
        var edited = text
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let next = JSONEdit.setServer(edited, name: name, value: entry) else { return rewritten }
            edited = next
        }
        return JSONEdit.same(Data(edited.utf8), as: rewritten) ? Data(edited.utf8) : rewritten
    }

    // Removes this app's servers from Claude Desktop's configuration and keeps everything else, including
    // servers with the same names that run something else, such as a development build.
    static func removeFromClaudeDesktop(_ existing: Data) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw ConfigFailure(description: String(localized: "Claude Desktop's configuration is not valid JSON, so it was left unchanged."))
        }
        var names: [String] = []
        if var servers = root["mcpServers"] as? [String: Any] {
            names = appServerNames(servers)
            for name in names { servers.removeValue(forKey: name) }
            root["mcpServers"] = servers
        }
        guard !names.isEmpty else { return existing }
        let rewritten = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard var edited = String(data: existing, encoding: .utf8) else { return rewritten }
        for name in names {
            guard let next = JSONEdit.removeServer(edited, name: name) else { return rewritten }
            edited = next
        }
        return JSONEdit.same(Data(edited.utf8), as: rewritten) ? Data(edited.utf8) : rewritten
    }

    // Whether Claude Desktop's configuration has any of this app's servers, connected with any settings.
    static func claudeDesktopHasServers(_ existing: Data?) -> Bool {
        guard let existing, let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return !appServerNames(servers).isEmpty
    }

    // Whether Claude Desktop's configuration already points at exactly these servers.
    static func claudeDesktopMatches(_ existing: Data?, servers: [ServerSpec]) -> Bool {
        guard let existing, let merged = try? mergeClaudeDesktop(existing, servers: servers) else { return false }
        return JSONEdit.same(existing, as: merged)
    }

    // Commands that register a server with the Claude Code CLI for every project of this user.
    // The old entry is removed first so that changed settings replace it.
    static func claudeCodeCommands(_ server: ServerSpec) -> [[String]] {
        var add = ["mcp", "add", "--scope", "user", "--transport", "stdio", server.name]
        for key in server.environment.keys.sorted() { add += ["-e", "\(key)=\(server.environment[key]!)"] }
        add += ["--", server.command]
        return [["mcp", "remove", "--scope", "user", server.name], add]
    }

    static func codexCommands(_ server: ServerSpec) -> [[String]] {
        var add = ["mcp", "add", server.codexName]
        for key in server.environment.keys.sorted() { add += ["--env", "\(key)=\(server.environment[key]!)"] }
        add += ["--", server.command]
        return [["mcp", "remove", server.codexName], add]
    }

    // `codex mcp add` cannot set a tool timeout, and Codex may stop a tool sooner than a sandbox command, while
    // sandbox commands may run for up to 600. This sets `key = value` in the server's own table only,
    // leaving every other line of the file as it was. It handles the plain `[mcp_servers.<name>]` header
    // that `codex mcp add` writes; a table written another way is left unchanged.
    static func setCodexServerOption(_ toml: String, server: String, key: String, value: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        let header = "[mcp_servers.\(server)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return toml }
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        let line = "\(key) = \(value)"
        if let existing = (start + 1..<end).first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(key) && trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) {
            lines[existing] = line
        } else {
            lines.insert(line, at: start + 1)
        }
        return lines.joined(separator: "\n")
    }

    // Shell-quoted commands to show when a client's CLI is not installed.
    static func displayCommand(_ program: String, _ arguments: [String]) -> String {
        ([program] + arguments).map { argument in
            argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) })
                ? argument : "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }
}
