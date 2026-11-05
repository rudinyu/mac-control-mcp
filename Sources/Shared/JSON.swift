import Foundation

func textContent(_ text: String) -> [String: Any] {
    ["type": "text", "text": text]
}

// JSONSerialization stops the process on a value JSON cannot hold, so such values, like a Date or NaN, are
// written as their descriptions instead.
func jsonString(_ value: Any) -> String {
    let safe = JSONSerialization.isValidJSONObject(value) ? value : jsonSafe(value)
    guard JSONSerialization.isValidJSONObject(safe),
          let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}

private func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let dictionary as [String: Any]: return dictionary.mapValues(jsonSafe)
    case let array as [Any]: return array.map(jsonSafe)
    case is String, is NSNull: return value
    case let number as NSNumber where JSONSerialization.isValidJSONObject([number]): return number
    default: return String(describing: value)
    }
}
