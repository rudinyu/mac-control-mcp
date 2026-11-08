import Foundation

// Edits the mcpServers object of JSON text in place, so the rest of a file keeps its layout, key order, and
// formatting. Each edit returns nil when the text is not laid out as expected; callers then check the result
// against a parsed version and fall back to writing the file anew. Text with CRLF line endings is left to that
// fallback too, rather than given mixed line endings.
enum JSONEdit {
    static func same(_ a: Data, as b: Data) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
              let right = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return false }
        return left == right
    }

    static func setServer(_ text: String, name: String, value: Any) -> String? {
        let bytes = Array(text.utf8)
        let rootStart = skipSpace(bytes, 0)
        guard !bytes.contains(0x0d), rootStart < bytes.count, bytes[rootStart] == UInt8(ascii: "{"),
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
        let rootStart = skipSpace(bytes, 0)
        guard !bytes.contains(0x0d), rootStart < bytes.count, bytes[rootStart] == UInt8(ascii: "{"),
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

    private static func skipSpace(_ b: [UInt8], _ start: Int) -> Int {
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
            // A number, true, false, or null. Anything else is accepted too, which is safe only because
            // callers compare the edited text with a parsed version before using it.
            var i = start
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0a, 0x0d].contains(b[i]) { i += 1 }
            return i > start ? i : nil
        }
    }

    private static func members(_ b: [UInt8], _ open: Int) -> Object? {
        var result: [Member] = []
        var i = skipSpace(b, open + 1)
        if i < b.count, b[i] == UInt8(ascii: "}") { return Object(members: [], close: i) }
        while i < b.count {
            guard b[i] == UInt8(ascii: "\""), let keyEnd = endOfString(b, i),
                  let key = try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed) as? String,
                  case let colon = skipSpace(b, keyEnd), colon < b.count, b[colon] == UInt8(ascii: ":"),
                  case let valueStart = skipSpace(b, colon + 1), let end = endOfValue(b, valueStart),
                  case let after = skipSpace(b, end), after < b.count else { return nil }
            result.append(Member(key: key, keyStart: i, valueStart: valueStart, end: end))
            if b[after] == UInt8(ascii: "}") { return Object(members: result, close: after) }
            guard b[after] == UInt8(ascii: ",") else { return nil }
            i = skipSpace(b, after + 1)
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
