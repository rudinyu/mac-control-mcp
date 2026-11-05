// A server with only test tools, built with Sources/Shared by scripts/ci.sh, so tests/test_mcp_server.py can check
// how requests are read, ordered, and cancelled without any macOS permission.

import Foundation

private final class FakeServer: MCPServer {
    let name = "fake"
    let instructions = "Test tools only."
    let tools: [[String: Any]] = [
        ["name": "sleep", "description": "Sleep, stopping early when cancelled.",
         "inputSchema": ["type": "object", "properties": ["seconds": ["type": "number", "description": "How long."]]],
         "annotations": ["readOnlyHint": true]],
        ["name": "echo", "description": "Return text, with where and how the call ran.",
         "inputSchema": ["type": "object", "properties": ["text": ["type": "string", "description": "What to return."]]],
         "annotations": ["readOnlyHint": true]],
    ]
    private var running = 0
    private var mostRunning = 0

    func answer(tool name: String, arguments: [String: Any], cancellation: Cancellation) -> [String: Any] {
        running += 1
        mostRunning = max(mostRunning, running)
        defer { running -= 1 }
        switch name {
        case "sleep":
            let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue ?? 1
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if cancellation.isCancelled { return ["content": [textContent("stopped")]] }
                usleep(10_000)
            }
            return ["content": [textContent("slept")]]
        case "echo":
            let report: [String: Any] = ["text": arguments["text"] as? String ?? "", "main_thread": Thread.isMainThread,
                                         "most_running": mostRunning]
            return ["content": [textContent(jsonString(report))]]
        case "unencodable":
            // The extra value is NaN, which JSON cannot hold.
            return ["content": [textContent("fine")], "value": Double.nan]
        default:
            return ["content": [textContent("Unknown tool")], "isError": true]
        }
    }
}

@main
private enum Main {
    static func main() { FakeServer().serve() }
}
