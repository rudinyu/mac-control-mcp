import Foundation

func textContent(_ text: String) -> [String: Any] {
    ["type": "text", "text": text]
}

// A successful tool result. data is the structuredContent, which the tool's outputSchema describes, and the text
// content is the same JSON for clients that read only text. A sentence for people goes into data as message,
// because some clients, such as Claude Code, show only structuredContent when it is present. Images follow.
func toolResult(_ data: [String: Any], images: [[String: Any]] = []) -> [String: Any] {
    let safe = JSONSerialization.isValidJSONObject(data) ? data : jsonSafe(data) as? [String: Any] ?? [:]
    return ["content": [textContent(jsonString(safe))] + images, "structuredContent": safe]
}

// JSONSerialization stops the process on a value JSON cannot hold, so such values, like a Date or NaN, are
// written as their descriptions instead.
func jsonString(_ value: Any) -> String {
    let safe = JSONSerialization.isValidJSONObject(value) ? value : jsonSafe(value)
    guard JSONSerialization.isValidJSONObject(safe),
          let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}

private func jsonSafe(_ value: Any) -> Any {
    // An optional is written as null or as what it holds, never as "nil" or "Optional(...)".
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        return mirror.children.first.map { jsonSafe($0.value) } ?? NSNull()
    }
    switch value {
    case let dictionary as [String: Any]: return dictionary.mapValues(jsonSafe)
    case let dictionary as [AnyHashable: Any]:
        return Dictionary(dictionary.map { ("\($0.key.base)", jsonSafe($0.value)) }, uniquingKeysWith: { first, _ in first })
    case let array as [Any]: return array.map(jsonSafe)
    case is String, is NSNull: return value
    case let number as NSNumber where JSONSerialization.isValidJSONObject([number]): return number
    default: return String(describing: value)
    }
}
