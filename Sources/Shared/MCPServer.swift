import Foundation

// The JSON-RPC side of an MCP server on standard input and output, shared by mac-control and mac-exec. Each
// server gives its name, instructions, and tools, and answers tool calls; this reads requests and replies.
protocol MCPServer: AnyObject {
    var name: String { get }
    var instructions: String { get }
    var tools: [[String: Any]] { get }
    // Called with the params of initialize, such as to note the client's name.
    func initialized(_ params: [String: Any])
    // The result of tools/call: its content, and isError when the call failed.
    func answer(tool name: String, arguments: [String: Any]) -> [String: Any]
}

let supportedProtocolVersions: Set<String> = [
    "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
]

extension MCPServer {
    func initialized(_ params: [String: Any]) {}

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
            initialized(params)
            let requested = params["protocolVersion"] as? String ?? ""
            let selected = supportedProtocolVersions.contains(requested) ? requested : "2025-11-25"
            send(result: [
                "protocolVersion": selected,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": name, "version": productVersion],
                "instructions": instructions
            ], id: id)
        case "ping":
            send(result: [:], id: id)
        case "tools/list":
            send(result: ["tools": tools], id: id)
        case "tools/call":
            guard let tool = params["name"] as? String else {
                send(error: -32602, message: "Missing tool name", id: id)
                return
            }
            send(result: answer(tool: tool, arguments: params["arguments"] as? [String: Any] ?? [:]), id: id)
        default:
            send(error: -32601, message: "Method not found", id: id)
        }
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

func textContent(_ text: String) -> [String: Any] {
    ["type": "text", "text": text]
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}
