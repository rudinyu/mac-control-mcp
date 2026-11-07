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

    // Whether the output of `claude mcp get` or `codex mcp get` shows a command that is this app's helper.
    static func describesAppCommand(_ output: String) -> Bool {
        output.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }).contains { isAppCommand(String($0)) }
    }

    // A server's entry in Claude Code's user configuration, ~/.claude.json, as JSON for `claude mcp add-json`.
    static func claudeCodeEntry(_ configuration: Data?, name: String) -> String? {
        guard let configuration, let root = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[name] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
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
        for name in entries.keys.sorted() {
            guard let next = JSONEdit.setServer(edited, name: name, value: entries[name]!) else { return rewritten }
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
            names = managedNames.filter { isAppCommand(((servers[$0] as? [String: Any])?["command"] as? String) ?? "") }
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
        return managedNames.contains { isAppCommand(((servers[$0] as? [String: Any])?["command"] as? String) ?? "") }
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

// Edits the mcpServers object of JSON text in place, so the rest of a file keeps its layout, key order, and
// formatting. Each edit returns nil when the text is not laid out as expected; callers then check the result
// against a parsed version and fall back to writing the file anew.
enum JSONEdit {
    static func same(_ a: Data, as b: Data) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
              let right = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return false }
        return left == right
    }

    static func setServer(_ text: String, name: String, value: Any) -> String? {
        let bytes = Array(text.utf8)
        guard let rootStart = skipSpace(bytes, 0), rootStart < bytes.count, bytes[rootStart] == UInt8(ascii: "{"),
              let root = members(bytes, rootStart) else { return nil }
        if let servers = root.members.first(where: { $0.key == "mcpServers" }) {
            guard bytes[servers.valueStart] == UInt8(ascii: "{"), let object = members(bytes, servers.valueStart) else { return nil }
            let indent = memberIndent(bytes, object, parent: servers.keyStart)
            guard let serialized = serialize(value, indent: indent, step: step(bytes, indent: indent, parent: servers.keyStart)) else { return nil }
            if let existing = object.members.first(where: { $0.key == name }) {
                return replace(bytes, existing.valueStart..<existing.end, serialized)
            }
            return insert(bytes, into: object, line: "\(quoted(name)): \(serialized)", indent: indent, parent: servers.keyStart)
        }
        let indent = memberIndent(bytes, root, parent: rootStart)
        guard let serialized = serialize([name: value], indent: indent, step: step(bytes, indent: indent, parent: rootStart)) else { return nil }
        return insert(bytes, into: root, line: "\"mcpServers\": \(serialized)", indent: indent, parent: rootStart)
    }

    static func removeServer(_ text: String, name: String) -> String? {
        let bytes = Array(text.utf8)
        guard let rootStart = skipSpace(bytes, 0), rootStart < bytes.count, bytes[rootStart] == UInt8(ascii: "{"),
              let root = members(bytes, rootStart),
              let servers = root.members.first(where: { $0.key == "mcpServers" }),
              bytes[servers.valueStart] == UInt8(ascii: "{"), let object = members(bytes, servers.valueStart),
              let index = object.members.firstIndex(where: { $0.key == name }) else { return nil }
        let member = object.members[index]
        let range: Range<Int>
        if index > 0 {
            range = object.members[index - 1].end..<member.end           // the comma before it, and it
        } else if object.members.count > 1 {
            range = member.keyStart..<object.members[1].keyStart        // it, its comma, and the space after
        } else {
            range = (servers.valueStart + 1)..<object.close             // the only member: leave {}
        }
        return replace(bytes, range, "")
    }

    private struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let end: Int        // just after the value
    }

    private struct Object {
        let members: [Member]
        let close: Int      // index of the closing brace
    }

    private static func skipSpace(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start
        while i < b.count, [0x20, 0x09, 0x0a, 0x0d].contains(b[i]) { i += 1 }
        return i
    }

    // The index just after the string that starts at start.
    private static func endOfString(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    // The index just after the value that starts at start.
    private static func endOfValue(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        switch b[start] {
        case UInt8(ascii: "\""): return endOfString(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""): guard let end = endOfString(b, i) else { return nil }; i = end; continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0a, 0x0d].contains(b[i]) { i += 1 }
            return i > start ? i : nil
        }
    }

    private static func members(_ b: [UInt8], _ open: Int) -> Object? {
        var result: [Member] = []
        guard var i = skipSpace(b, open + 1) else { return nil }
        if i < b.count, b[i] == UInt8(ascii: "}") { return Object(members: [], close: i) }
        while i < b.count {
            guard b[i] == UInt8(ascii: "\""), let keyEnd = endOfString(b, i),
                  let key = try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed) as? String,
                  let colon = skipSpace(b, keyEnd), colon < b.count, b[colon] == UInt8(ascii: ":"),
                  let valueStart = skipSpace(b, colon + 1), let end = endOfValue(b, valueStart),
                  let after = skipSpace(b, end), after < b.count else { return nil }
            result.append(Member(key: key, keyStart: i, valueStart: valueStart, end: end))
            if b[after] == UInt8(ascii: "}") { return Object(members: result, close: after) }
            guard b[after] == UInt8(ascii: ","), let next = skipSpace(b, after + 1) else { return nil }
            i = next
        }
        return nil
    }

    // The spaces before position on its line.
    private static func lineIndent(_ b: [UInt8], _ position: Int) -> String {
        var start = position
        while start > 0, b[start - 1] != 0x0a { start -= 1 }
        return String(decoding: b[start..<position].prefix(while: { $0 == 0x20 || $0 == 0x09 }), as: UTF8.self)
    }

    // The indent of the object's members, or the parent's indent and two spaces for an empty object.
    private static func memberIndent(_ b: [UInt8], _ object: Object, parent: Int) -> String {
        if let first = object.members.first { return lineIndent(b, first.keyStart) }
        return lineIndent(b, parent) + "  "
    }

    // The value as JSON whose lines continue at indent, indenting each level by step, as the file does.
    private static func serialize(_ value: Any, indent: String, step: String) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { return "{}" }
            var lines: [String] = []
            for key in dictionary.keys.sorted() {
                guard let inner = serialize(dictionary[key]!, indent: indent + step, step: step) else { return nil }
                lines.append(indent + step + quoted(key) + ": " + inner)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            var lines: [String] = []
            for item in array {
                guard let inner = serialize(item, indent: indent + step, step: step) else { return nil }
                lines.append(indent + step + inner)
            }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
        default:
            return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    // How much each level is indented: the members' indent beyond the parent's, or two spaces.
    private static func step(_ b: [UInt8], indent: String, parent: Int) -> String {
        let outer = lineIndent(b, parent)
        return indent.count > outer.count && indent.hasPrefix(outer) ? String(indent.dropFirst(outer.count)) : "  "
    }

    private static func quoted(_ key: String) -> String {
        (try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(key)\""
    }

    private static func insert(_ b: [UInt8], into object: Object, line: String, indent: String, parent: Int) -> String {
        if let last = object.members.last {
            return replace(b, last.end..<last.end, ",\n" + indent + line)
        }
        // An empty object: put the member on its own line, and the brace back at the parent's indent.
        let open = object.close - 1
        var start = open
        while start >= 0, b[start] != UInt8(ascii: "{") { start -= 1 }
        return replace(b, (start + 1)..<object.close, "\n" + indent + line + "\n" + lineIndent(b, parent))
    }

    private static func replace(_ b: [UInt8], _ range: Range<Int>, _ text: String) -> String {
        String(decoding: b[..<range.lowerBound] + Array(text.utf8) + b[range.upperBound...], as: UTF8.self)
    }
}
