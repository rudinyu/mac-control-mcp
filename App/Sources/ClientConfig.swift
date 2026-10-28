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

    // Adds or replaces this app's servers in Claude Desktop's configuration and keeps everything else,
    // including other servers and settings. Malformed JSON is refused rather than overwritten.
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
        for server in servers {
            var entry: [String: Any] = ["command": server.command, "args": [String]()]
            if !server.environment.isEmpty { entry["env"] = server.environment }
            mcpServers[server.name] = entry
        }
        root["mcpServers"] = mcpServers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // Removes this app's servers from Claude Desktop's configuration and keeps everything else.
    static func removeFromClaudeDesktop(_ existing: Data) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw ConfigFailure(description: String(localized: "Claude Desktop's configuration is not valid JSON, so it was left unchanged."))
        }
        if var servers = root["mcpServers"] as? [String: Any] {
            for name in managedNames { servers.removeValue(forKey: name) }
            root["mcpServers"] = servers
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // Whether Claude Desktop's configuration has any of this app's servers, connected with any settings.
    static func claudeDesktopHasServers(_ existing: Data?) -> Bool {
        guard let existing, let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return managedNames.contains { servers[$0] != nil }
    }

    // Whether Claude Desktop's configuration already points at exactly these servers.
    static func claudeDesktopMatches(_ existing: Data?, servers: [ServerSpec]) -> Bool {
        guard let existing, let merged = try? mergeClaudeDesktop(existing, servers: servers),
              let before = try? JSONSerialization.jsonObject(with: existing) as? NSDictionary,
              let after = try? JSONSerialization.jsonObject(with: merged) as? NSDictionary else { return false }
        return before == after
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
