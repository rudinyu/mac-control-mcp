import Foundation

func textContent(_ text: String) -> [String: Any] {
    ["type": "text", "text": text]
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}
