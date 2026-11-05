import Foundation

// The JSON-RPC side of an MCP server on standard input and output, shared by mac-control and mac-exec. Each
// server gives its name, instructions, and tools, and answers tool calls; this reads requests and replies.
protocol MCPServer: AnyObject {
    var name: String { get }
    var instructions: String { get }
    var tools: [[String: Any]] { get }
    // Called with the params of initialize, such as to note the client's name.
    func initialized(_ params: [String: Any])
    // The result of tools/call: its content, and isError when the call failed. Runs on the main thread, one call
    // at a time; cancellation is set when the client cancels the call.
    func answer(tool name: String, arguments: [String: Any], cancellation: Cancellation) -> [String: Any]
}

let supportedProtocolVersions: Set<String> = [
    "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
]

extension MCPServer {
    func initialized(_ params: [String: Any]) {}

    // Serves until standard input closes and every request read before that is answered.
    func serve() {
        MCPConnection(server: self).run()
    }
}

// Requests are read on a background thread, so ping and cancellation are handled while a tool runs. Everything
// else is handled in order on the main thread, one request at a time: tools wait on the main run loop for app
// state, and two input actions must never interleave.
private final class MCPConnection {
    private struct Request {
        let id: Any
        let key: String
        let method: String
        let params: [String: Any]
        let cancellation = Cancellation()
    }

    private let server: MCPServer
    // Guards queue, active, and ended, and wakes the main thread when a request arrives or input ends.
    private let pending = NSCondition()
    private var queue: [Request] = []
    // The cancellation of each request that is queued or running, by request ID.
    private var active: [String: Cancellation] = [:]
    private var ended = false
    private let output = NSLock()

    init(server: MCPServer) {
        self.server = server
    }

    func run() {
        Thread { [self] in read() }.start()
        while let request = next() {
            if !request.cancellation.isCancelled { handle(request) }
            pending.lock()
            if active[request.key] === request.cancellation { active[request.key] = nil }
            pending.unlock()
        }
    }

    private func read() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    send(error: -32600, message: "Invalid JSON-RPC request", id: NSNull())
                    continue
                }
                receive(message)
            } catch {
                send(error: -32700, message: "Invalid JSON", id: NSNull())
            }
        }
        pending.lock()
        ended = true
        pending.signal()
        pending.unlock()
    }

    private func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String else {
            send(error: -32600, message: "Missing method", id: message["id"] ?? NSNull())
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"] else {
            // A notification. Cancelling a request that is still queued means it never runs.
            if method == "notifications/cancelled", let requestID = params["requestId"] {
                pending.lock()
                active[key(requestID)]?.cancel()
                pending.unlock()
            }
            return
        }
        if method == "ping" {
            send(result: [:], id: id)
            return
        }
        let request = Request(id: id, key: key(id), method: method, params: params)
        pending.lock()
        queue.append(request)
        // Only tool calls can be cancelled; MCP does not let a client cancel initialize.
        if method == "tools/call" { active[request.key] = request.cancellation }
        pending.signal()
        pending.unlock()
    }

    // The next request to handle, or nil once input has ended and nothing is left.
    private func next() -> Request? {
        pending.lock(); defer { pending.unlock() }
        while queue.isEmpty && !ended { pending.wait() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    private func handle(_ request: Request) {
        switch request.method {
        case "initialize":
            server.initialized(request.params)
            let requested = request.params["protocolVersion"] as? String ?? ""
            let selected = supportedProtocolVersions.contains(requested) ? requested : "2025-11-25"
            send(result: [
                "protocolVersion": selected,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": server.name, "version": productVersion],
                "instructions": server.instructions
            ], id: request.id)
        case "tools/list":
            send(result: ["tools": server.tools], id: request.id)
        case "tools/call":
            guard let tool = request.params["name"] as? String else {
                send(error: -32602, message: "Missing tool name", id: request.id)
                return
            }
            let result = server.answer(tool: tool, arguments: request.params["arguments"] as? [String: Any] ?? [:],
                                       cancellation: request.cancellation)
            // The client has stopped waiting for a cancelled request, so it gets no answer.
            if !request.cancellation.isCancelled { send(result: result, id: request.id) }
        default:
            send(error: -32601, message: "Method not found", id: request.id)
        }
    }

    // JSONSerialization stops the process on a value JSON cannot hold, so check first.
    private func encoded(_ value: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    // Request IDs are strings or numbers, and "1" and 1 are different requests.
    private func key(_ id: Any) -> String {
        if let text = id as? String { return "s" + text }
        if let number = id as? NSNumber { return "n" + number.stringValue }
        return "?" + String(describing: id)
    }

    private func send(result: Any, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, message: String, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ value: [String: Any]) {
        var data = encoded(value)
        if data == nil {
            let id = value["id"].map { String(describing: $0) } ?? "none"
            FileHandle.standardError.write(Data("The message for request \(id) could not be encoded as JSON.\n".utf8))
            // A result still needs an answer, or the client waits forever for it. The error holds nothing but the
            // request's own ID, which was read from JSON.
            if value["result"] != nil, let id = value["id"] {
                data = encoded(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32603, "message": "Internal error: the result could not be encoded as JSON"]])
            }
        }
        guard let data else { return }
        output.lock(); defer { output.unlock() }
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}
