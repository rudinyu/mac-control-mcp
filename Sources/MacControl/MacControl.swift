import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let serverVersion = "0.2.0"
private let supportedProtocolVersions: Set<String> = [
    "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
]

private struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct CaptureSize {
    let width: Int
    let height: Int
    let displayBounds: CGRect
    // The app in front and its window when the screenshot was taken, so a click aimed at an app can be
    // refused when the screen it lands on is no longer the one in the screenshot.
    let focusedPID: pid_t?
    let windowFrame: CGRect?
}

private let appProperty: [String: Any] = [
    "type": "string",
    "description": "Name or bundle ID of a running app with a Dock icon, such as TextEdit or com.apple.TextEdit."
]

private let activationTimeout: TimeInterval = 2
private let focusPollInterval: TimeInterval = 0.05
// Gives the target app time to read the clipboard before the previous contents are restored.
private let pasteSettleMicroseconds: useconds_t = 500_000

private struct Recording {
    let process: Process
    let path: URL
    let duration: Int
    let startedAt: Date
}

private final class MacControlServer {
    private var lastCapture: CaptureSize?
    private var recordings: [String: Recording] = [:]

    private let tools: [[String: Any]] = [
        [
            "name": "mac_status",
            "description": "Report macOS Screen Recording and Accessibility permission, whether the screen is locked, the frontmost app, and main display geometry. Call this before controlling the Mac. While screen_locked is true, mouse and keyboard tools refuse to send input.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true]
        ],
        [
            "name": "mac_screenshot",
            "description": "Capture the main display. The returned image dimensions define the x/y coordinate space for mac_mouse until the next screenshot. If app is given, that running app is brought to the front first, which also brings back a window from the Stage Manager strip, and mac_mouse with the same app can check that its window has not changed since. Requires Screen Recording permission, and Accessibility permission when app is given.",
            "inputSchema": ["type": "object", "properties": ["app": appProperty], "additionalProperties": false]
        ],
        [
            "name": "mac_request_screen_recording",
            "description": "Ask macOS to show its Screen Recording permission prompt for this local server. The user must grant access in macOS and restart the host app if required.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "mac_ui_tree",
            "description": "Read a limited Accessibility tree for the focused window and focused element of an app: the named app if app is given, otherwise the frontmost app. Does not change which app is in front. Password field values are excluded. Requires Accessibility permission.",
            "inputSchema": [
                "type": "object",
                "properties": ["max_depth": ["type": "integer", "minimum": 0, "maximum": 8], "app": appProperty],
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": true]
        ],
        [
            "name": "mac_record_start",
            "description": "Start recording the main display to a local MOV file for 1 to 120 seconds. Returns an ID; use mac_record_status to get the completed path. Requires Screen Recording permission.",
            "inputSchema": [
                "type": "object",
                "properties": ["duration_seconds": ["type": "integer", "minimum": 1, "maximum": 120]],
                "required": ["duration_seconds"], "additionalProperties": false
            ]
        ],
        [
            "name": "mac_record_status",
            "description": "Check whether a screen recording is still running and get the MOV file path when complete.",
            "inputSchema": [
                "type": "object",
                "properties": ["recording_id": ["type": "string"]],
                "required": ["recording_id"], "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": true]
        ],
        [
            "name": "mac_record_stop",
            "description": "Stop an active recording early. The recording may need a moment to finish writing before mac_record_status reports the file.",
            "inputSchema": [
                "type": "object",
                "properties": ["recording_id": ["type": "string"]],
                "required": ["recording_id"], "additionalProperties": false
            ]
        ],
        [
            "name": "mac_mouse",
            "description": "Move, click, double-click, right-click, or drag on the main display. x/y and to_x/to_y are pixels in the most recent mac_screenshot image. If app is given, that running app is brought to the front first, and nothing is sent unless it is still in front, the last mac_screenshot was taken with it in front, and its window has not moved or resized since. Requires Accessibility permission.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["move", "click", "double_click", "right_click", "drag"]],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"],
                    "app": appProperty
                ],
                "required": ["action", "x", "y"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "mac_scroll",
            "description": "Scroll at the current pointer position by line increments. Positive vertical values scroll up; positive horizontal values scroll left. If app is given, that running app is brought to the front first and nothing is scrolled unless it is still in front. Requires Accessibility permission.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "vertical": ["type": "integer", "minimum": -20, "maximum": 20],
                    "horizontal": ["type": "integer", "minimum": -20, "maximum": 20],
                    "app": appProperty
                ],
                "additionalProperties": false
            ]
        ],
        [
            "name": "mac_type_text",
            "description": "Insert Unicode text into the focused field by temporarily placing it on the clipboard and pressing Command-V. If app is given, that running app is brought to the front first and nothing is pasted unless it is still in front. Restores the prior clipboard when possible. Maximum 2000 characters. Requires Accessibility permission.",
            "inputSchema": [
                "type": "object",
                "properties": ["text": ["type": "string", "maxLength": 2000], "app": appProperty],
                "required": ["text"], "additionalProperties": false
            ]
        ],
        [
            "name": "mac_key",
            "description": "Press a key, optionally with modifiers cmd, shift, alt, or ctrl. Examples: key='enter'; key='c', modifiers=['cmd']. If app is given, that running app is brought to the front first and no key is sent unless it is still in front. Requires Accessibility permission.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string"],
                    "modifiers": ["type": "array", "items": ["type": "string", "enum": ["cmd", "shift", "alt", "ctrl"]], "uniqueItems": true],
                    "app": appProperty
                ],
                "required": ["key"], "additionalProperties": false
            ]
        ]
    ]

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
            let requested = params["protocolVersion"] as? String ?? ""
            let selected = supportedProtocolVersions.contains(requested) ? requested : "2025-11-25"
            send(result: [
                "protocolVersion": selected,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "mac-control", "version": serverVersion],
                "instructions": "Use mac_status first. Use mac_screenshot before mac_mouse; mouse coordinates use the most recent screenshot. Pass app with the name of the app you are working in to mac_screenshot, mac_mouse, mac_scroll, mac_type_text, and mac_key, so input cannot land in another app. Ask the user before irreversible actions."
            ], id: id)
        case "ping":
            send(result: [:], id: id)
        case "tools/list":
            send(result: ["tools": tools], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else {
                send(error: -32602, message: "Missing tool name", id: id)
                return
            }
            do {
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let content = try callTool(name, arguments)
                send(result: ["content": content], id: id)
            } catch {
                send(result: ["content": [["type": "text", "text": String(describing: error)]], "isError": true], id: id)
            }
        default:
            send(error: -32601, message: "Method not found", id: id)
        }
    }

    private func callTool(_ name: String, _ args: [String: Any]) throws -> [[String: Any]] {
        // Every schema sets additionalProperties to false. Saying so, with the accepted names, keeps a
        // misspelled parameter from being ignored or reported as a bad value.
        if let schema = tools.first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any],
           let properties = schema["properties"] as? [String: Any] {
            let unknown = Set(args.keys).subtracting(properties.keys)
            if !unknown.isEmpty {
                let accepted = properties.keys.sorted().joined(separator: ", ")
                throw ToolFailure("\(name) does not take \(unknown.sorted().joined(separator: ", ")). It accepts: \(accepted.isEmpty ? "no parameters" : accepted).")
            }
        }
        switch name {
        case "mac_status": return [textContent(status())]
        case "mac_screenshot": return try screenshot(args)
        case "mac_request_screen_recording": return [textContent(CGRequestScreenCaptureAccess() ? "Screen Recording access is granted." : "Screen Recording access is not granted yet. Complete the macOS permission prompt. \(PermissionHint.screenRecording)")]
        case "mac_ui_tree": return [textContent(try uiTree(args))]
        case "mac_record_start": return [textContent(try recordStart(args))]
        case "mac_record_status": return [textContent(try recordStatus(args))]
        case "mac_record_stop": return [textContent(try recordStop(args))]
        case "mac_mouse": return [textContent(try mouse(args))]
        case "mac_scroll": return [textContent(try scroll(args))]
        case "mac_type_text": return [textContent(try typeText(args))]
        case "mac_key": return [textContent(try key(args))]
        default: throw ToolFailure("Unknown tool: \(name)")
        }
    }

    private func textContent(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private func status() -> String {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let app = NSWorkspace.shared.frontmostApplication
        var info: [String: Any] = [
            "screen_recording": CGPreflightScreenCaptureAccess(),
            "accessibility": AXIsProcessTrusted(),
            "frontmost_app": app?.localizedName ?? NSNull(),
            "frontmost_bundle_id": app?.bundleIdentifier ?? NSNull(),
            "display_available": bounds.width > 0 && bounds.height > 0,
            "main_display": ["x": bounds.origin.x, "y": bounds.origin.y, "width": bounds.width, "height": bounds.height],
            "last_screenshot": lastCapture.map { ["width": $0.width, "height": $0.height] } ?? NSNull()
        ]
        let blockReason = inputBlockReason()
        info["screen_locked"] = blockReason != nil
        info["screen_locked_reason"] = blockReason ?? NSNull()
        if let cursor = CGEvent(source: nil)?.location {
            info["cursor_display"] = ["x": cursor.x, "y": cursor.y]
            if let capture = lastCapture, capture.displayBounds.width > 0, capture.displayBounds.height > 0 {
                info["cursor_screenshot"] = [
                    "x": (cursor.x - capture.displayBounds.origin.x) * Double(capture.width) / capture.displayBounds.width,
                    "y": (cursor.y - capture.displayBounds.origin.y) * Double(capture.height) / capture.displayBounds.height
                ]
            }
        }
        return jsonString(info)
    }

    private func screenshot(_ args: [String: Any]) throws -> [[String: Any]] {
        guard CGDisplayBounds(CGMainDisplayID()).width > 0 else {
            throw ToolFailure("No Mac display is available to this process. Run the MCP host in a logged-in local desktop session.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolFailure("Screen Recording permission is missing. \(PermissionHint.screenRecording)")
        }
        let target = try targetApp(args)
        if let target {
            try requireAccessibility()
            try bringToFront(target)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mac-control-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", "-t", "jpg", path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: path),
              let image = NSBitmapImageRep(data: data) else {
            throw ToolFailure("Screen capture failed. Check Screen Recording permission and that this process runs in a logged-in Mac desktop session.")
        }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let focused = AXIsProcessTrusted() ? focusedApp() : nil
        lastCapture = CaptureSize(width: image.pixelsWide, height: image.pixelsHigh, displayBounds: bounds,
                                  focusedPID: focused?.processIdentifier, windowFrame: focused.flatMap(windowFrame))
        var description = "Main display screenshot: \(image.pixelsWide) x \(image.pixelsHigh) pixels. Use these pixel coordinates with mac_mouse."
        if let focused { description += " \(focused.localizedName ?? "An app") is in front." }
        return [textContent(description), ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]
    }

    private func recordStart(_ args: [String: Any]) throws -> String {
        let seconds = try number(args, "duration_seconds")
        guard seconds.rounded() == seconds, seconds >= 1, seconds <= 120 else {
            throw ToolFailure("duration_seconds must be an integer from 1 to 120.")
        }
        guard CGDisplayBounds(CGMainDisplayID()).width > 0 else {
            throw ToolFailure("No Mac display is available to this process. Run the MCP host in a logged-in local desktop session.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolFailure("Screen Recording permission is missing. \(PermissionHint.screenRecording)")
        }
        guard !recordings.values.contains(where: { $0.process.isRunning }) else {
            throw ToolFailure("A screen recording is already running.")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let path = directory.appendingPathComponent("\(id).mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", "-v", "-V", String(Int(seconds)), path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        recordings[id] = Recording(process: process, path: path, duration: Int(seconds), startedAt: Date())
        return jsonString(["recording_id": id, "state": "recording", "duration_seconds": Int(seconds)])
    }

    private func recording(_ args: [String: Any]) throws -> (String, Recording) {
        guard let id = args["recording_id"] as? String, let entry = recordings[id] else {
            throw ToolFailure("Unknown recording_id.")
        }
        return (id, entry)
    }

    private func recordStatus(_ args: [String: Any]) throws -> String {
        let (id, entry) = try recording(args)
        let size = (try? FileManager.default.attributesOfItem(atPath: entry.path.path)[.size] as? NSNumber)?.intValue ?? 0
        let state: String
        if entry.process.isRunning { state = "recording" }
        else if size > 0 { state = "ready" }
        else { state = "failed" }
        return jsonString([
            "recording_id": id, "state": state, "duration_seconds": entry.duration,
            "elapsed_seconds": Int(Date().timeIntervalSince(entry.startedAt)),
            "path": state == "ready" ? entry.path.path : "",
            "bytes": size
        ])
    }

    private func recordStop(_ args: [String: Any]) throws -> String {
        let (_, entry) = try recording(args)
        if entry.process.isRunning {
            entry.process.interrupt()
            for _ in 0..<20 {
                if !entry.process.isRunning { break }
                usleep(50_000)
            }
            if entry.process.isRunning { entry.process.terminate() }
        }
        return try recordStatus(args)
    }

    // CGSessionCopyCurrentDictionary() is nil for a process outside a GUI login session.
    private func inputBlockReason() -> String? {
        sessionInputBlockReason(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    private func requireUnlocked() throws {
        if let reason = inputBlockReason() { throw ToolFailure(reason) }
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ToolFailure("Accessibility permission is missing. \(PermissionHint.accessibility)")
        }
    }

    private func targetApp(_ args: [String: Any]) throws -> NSRunningApplication? {
        guard let raw = args["app"] else { return nil }
        guard let query = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolFailure("app must be a non-empty app name or bundle ID.")
        }
        // Only regular apps (those with a Dock icon) can be brought to the front and take keyboard input.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let byBundle = apps.filter { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
        let matches = byBundle.isEmpty
            ? apps.filter { $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame }
            : byBundle
        guard !matches.isEmpty else {
            throw ToolFailure("No running app with a Dock icon matches \"\(query)\". Launch it first.")
        }
        if matches.count == 1 { return matches[0] }
        if let focused = focusedApp(), let match = matches.first(where: { $0.processIdentifier == focused.processIdentifier }) {
            return match
        }
        let listed = matches.map { "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "no bundle ID"), pid \($0.processIdentifier))" }
        throw ToolFailure("\"\(query)\" matches \(matches.count) running apps: \(listed.joined(separator: ", ")). Use a bundle ID, or quit the extra copies.")
    }

    // Asks Accessibility rather than NSWorkspace, whose frontmostApplication can be stale without a run loop.
    // Returns nil when focus is unknown, so focus checks before input fail closed.
    private func focusedApp() -> NSRunningApplication? {
        guard let element = elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString) else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func waitUntilFocused(_ app: NSRunningApplication) -> Bool {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline {
            if focusedApp()?.processIdentifier == app.processIdentifier { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(focusPollInterval))
        }
        return focusedApp()?.processIdentifier == app.processIdentifier
    }

    private func focusFailure(_ target: NSRunningApplication, _ current: NSRunningApplication?) -> ToolFailure {
        let name = target.localizedName ?? "the app"
        guard let current else {
            return ToolFailure("Could not determine which app has focus, so \(name) could not be confirmed in front; no input was sent. Check Accessibility permission.")
        }
        return ToolFailure("\(current.localizedName ?? "Another app") has focus instead of \(name); no input was sent.")
    }

    private func bringToFront(_ app: NSRunningApplication) throws {
        if focusedApp()?.processIdentifier == app.processIdentifier { return }
        // activate() can return false yet still take effect, so waitUntilFocused is the real check.
        if app.isHidden { _ = app.unhide() }
        _ = app.activate()
        if waitUntilFocused(app) { return }
        // With Stage Manager, or when the app has no open window, activate() may leave it behind. Opening
        // it again through Launch Services sends the reopen event that clicking its Dock icon does.
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            if waitUntilFocused(app) { return }
        }
        throw focusFailure(app, focusedApp())
    }

    // The frame of the app's focused or main window, in screen points.
    private func windowFrame(_ app: NSRunningApplication) -> CGRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
                ?? elementAttribute(appElement, kAXMainWindowAttribute as CFString),
              let position = attribute(window, kAXPositionAttribute as CFString),
              let size = attribute(window, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    // A click aimed at an app must land on the screen the agent saw: the app was in front for the last
    // screenshot and its window has not moved or resized since.
    private func requireUnchangedSinceScreenshot(_ app: NSRunningApplication) throws {
        let name = app.localizedName ?? "the app"
        guard let capture = lastCapture, capture.focusedPID == app.processIdentifier else {
            throw ToolFailure("\(name) was not in front for the last mac_screenshot; no input was sent. Call mac_screenshot with app \"\(name)\" first.")
        }
        guard windowFrame(app) == capture.windowFrame else {
            throw ToolFailure("\(name)'s window moved, resized, or changed since the last mac_screenshot; no input was sent. Call mac_screenshot with app \"\(name)\" again.")
        }
    }

    // Re-checks focus immediately before posting input, since another app can take focus between tool calls.
    // A terminal hosting the agent may grab focus back right after activation, so re-activate once.
    // This is best effort: focus can still change in the moment between this check and the posted event.
    private func confirmFocus(_ target: NSRunningApplication?) throws -> String {
        // The screen can lock while the target app is being brought to the front.
        try requireUnlocked()
        var current = focusedApp()
        if let target, current?.processIdentifier != target.processIdentifier {
            try bringToFront(target)
            current = focusedApp()
            guard current?.processIdentifier == target.processIdentifier else { throw focusFailure(target, current) }
        }
        return current?.localizedName ?? "the frontmost app"
    }

    private func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let value = args[key] as? NSNumber else { throw ToolFailure("Missing or invalid \(key)") }
        let n = value.doubleValue
        guard n.isFinite else { throw ToolFailure("Invalid \(key)") }
        return n
    }

    private func point(_ args: [String: Any], xKey: String = "x", yKey: String = "y") throws -> CGPoint {
        guard let capture = lastCapture else { throw ToolFailure("Call mac_screenshot before mac_mouse.") }
        let x = try number(args, xKey)
        let y = try number(args, yKey)
        guard x >= 0, y >= 0, x < Double(capture.width), y < Double(capture.height) else {
            throw ToolFailure("Mouse coordinates are outside the last screenshot (\(capture.width) x \(capture.height)).")
        }
        return CGPoint(
            x: capture.displayBounds.origin.x + x * capture.displayBounds.width / Double(capture.width),
            y: capture.displayBounds.origin.y + y * capture.displayBounds.height / Double(capture.height)
        )
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickCount: Int64 = 1) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ToolFailure("Could not create a mouse event.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
    }

    private func mouse(_ args: [String: Any]) throws -> String {
        guard let action = args["action"] as? String else { throw ToolFailure("Missing action") }
        guard ["move", "click", "double_click", "right_click", "drag"].contains(action) else {
            throw ToolFailure("Invalid mouse action")
        }
        let start = try point(args)
        let end = action == "drag" ? try point(args, xKey: "to_x", yKey: "to_y") : nil
        let target = try targetApp(args)
        try requireAccessibility()
        try requireUnlocked()
        if let target {
            try bringToFront(target)
            try requireUnchangedSinceScreenshot(target)
        }
        let receiver = try confirmFocus(target)
        switch action {
        case "move":
            try postMouse(.mouseMoved, at: start)
        case "click":
            try postMouse(.leftMouseDown, at: start)
            try postMouse(.leftMouseUp, at: start)
        case "double_click":
            for count in 1...2 {
                try postMouse(.leftMouseDown, at: start, clickCount: Int64(count))
                try postMouse(.leftMouseUp, at: start, clickCount: Int64(count))
            }
        case "right_click":
            try postMouse(.rightMouseDown, at: start, button: .right)
            try postMouse(.rightMouseUp, at: start, button: .right)
        case "drag":
            guard let end else { throw ToolFailure("Missing drag destination") }
            try postMouse(.leftMouseDown, at: start)
            for step in 1...12 {
                let t = CGFloat(step) / 12
                let current = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                try postMouse(.leftMouseDragged, at: current)
                usleep(12_000)
            }
            try postMouse(.leftMouseUp, at: end)
        default: break
        }
        return target == nil ? "Mouse \(action) completed." : "Mouse \(action) completed in \(receiver)."
    }

    private func scroll(_ args: [String: Any]) throws -> String {
        let vertical = try args["vertical"].map { _ in try number(args, "vertical") } ?? 0
        let horizontal = try args["horizontal"].map { _ in try number(args, "horizontal") } ?? 0
        guard vertical.rounded() == vertical, horizontal.rounded() == horizontal,
              abs(vertical) <= 20, abs(horizontal) <= 20,
              vertical != 0 || horizontal != 0 else {
            throw ToolFailure("Scroll values must be nonzero integers from -20 to 20.")
        }
        let target = try targetApp(args)
        try requireAccessibility()
        try requireUnlocked()
        if let target { try bringToFront(target) }
        let receiver = try confirmFocus(target)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0) else {
            throw ToolFailure("Could not create a scroll event.")
        }
        event.post(tap: .cghidEventTap)
        return target == nil ? "Scrolled." : "Scrolled in \(receiver)."
    }

    private func typeText(_ args: [String: Any]) throws -> String {
        guard let value = args["text"] as? String, !value.isEmpty, value.count <= 2000 else {
            throw ToolFailure("text must contain 1 to 2000 characters.")
        }
        let target = try targetApp(args)
        try requireAccessibility()
        try requireUnlocked()
        if let target { try bringToFront(target) }
        let pasteboard = NSPasteboard.general
        var savedItems: [NSPasteboardItem] = []
        var totalBytes = 0
        for original in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type) else {
                    throw ToolFailure("Cannot preserve the current clipboard contents; text entry was cancelled.")
                }
                totalBytes += data.count
                guard totalBytes <= 40_000_000 else {
                    throw ToolFailure("The current clipboard is too large to preserve safely; text entry was cancelled.")
                }
                copy.setData(data, forType: type)
            }
            savedItems.append(copy)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            pasteboard.clearContents()
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            throw ToolFailure("Could not put text on the clipboard.")
        }
        let temporaryChangeCount = pasteboard.changeCount
        defer {
            // Do not overwrite a clipboard update made by the user or another app during paste.
            if pasteboard.changeCount == temporaryChangeCount {
                pasteboard.clearContents()
                if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw ToolFailure("Could not create a paste keyboard event.")
        }
        let receiver = try confirmFocus(target)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(pasteSettleMicroseconds)
        return "Inserted \(value.count) characters into \(receiver) via Command-V."
    }

    private let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
        "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51,
        "escape": 53, "delete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    private func key(_ args: [String: Any]) throws -> String {
        guard let keyName = (args["key"] as? String)?.lowercased(), let code = keyCodes[keyName] else {
            throw ToolFailure("Unsupported key. Use a-z, 0-9, enter, tab, space, backspace, escape, delete, home, end, pageup, pagedown, or an arrow key.")
        }
        let names = args["modifiers"] as? [String] ?? []
        guard names.count <= 4, Set(names).count == names.count,
              names.allSatisfy({ ["cmd", "shift", "alt", "ctrl"].contains($0) }) else {
            throw ToolFailure("Invalid modifiers")
        }
        let target = try targetApp(args)
        try requireAccessibility()
        try requireUnlocked()
        if let target { try bringToFront(target) }
        var flags: CGEventFlags = []
        if names.contains("cmd") { flags.insert(.maskCommand) }
        if names.contains("shift") { flags.insert(.maskShift) }
        if names.contains("alt") { flags.insert(.maskAlternate) }
        if names.contains("ctrl") { flags.insert(.maskControl) }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw ToolFailure("Could not create a keyboard event.")
        }
        let receiver = try confirmFocus(target)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return "Pressed \((names + [keyName]).joined(separator: "+")) in \(receiver)."
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func shortString(_ value: CFTypeRef?, limit: Int = 200) -> String? {
        guard let value else { return nil }
        let string: String
        if let plain = value as? String { string = plain }
        else if let number = value as? NSNumber { string = number.stringValue }
        else { return nil }
        return cleanCellText(string, limit: limit)
    }

    private func uiTree(_ args: [String: Any]) throws -> String {
        let depth = try args["max_depth"].map { _ in try number(args, "max_depth") } ?? 5
        guard depth.rounded() == depth, depth >= 0, depth <= 8 else { throw ToolFailure("max_depth must be 0 to 8.") }
        let target = try targetApp(args)
        try requireAccessibility()
        // A stale NSWorkspace answer is acceptable here because reading the tree sends no input.
        guard let app = target ?? focusedApp() ?? NSWorkspace.shared.frontmostApplication else {
            throw ToolFailure("No frontmost app found.")
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let root = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
            ?? elementAttribute(appElement, kAXMainWindowAttribute as CFString)
            ?? appElement
        var remaining = 200
        let tree = describeElement(root, depth: Int(depth), remaining: &remaining)
        let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString).map {
            var focusRemaining = 20
            return describeElement($0, depth: 1, remaining: &focusRemaining)
        }
        return jsonString(["app": app.localizedName ?? "Unknown", "bundle_id": app.bundleIdentifier ?? "",
                           "focused": focused ?? NSNull(), "tree": tree, "truncated": remaining == 0])
    }

    private func describeElement(_ element: AXUIElement, depth: Int, remaining: inout Int) -> [String: Any] {
        remaining -= 1
        let role = shortString(attribute(element, kAXRoleAttribute as CFString)) ?? "unknown"
        var result: [String: Any] = ["role": role]
        if let title = shortString(attribute(element, kAXTitleAttribute as CFString)) { result["title"] = title }
        if let description = shortString(attribute(element, kAXDescriptionAttribute as CFString)) { result["description"] = description }
        if role != "AXSecureTextField", let value = shortString(attribute(element, kAXValueAttribute as CFString)) {
            result["value"] = value
        }
        if depth > 0, remaining > 0, let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            var entries: [[String: Any]] = []
            for child in children {
                if remaining == 0 { break }
                entries.append(describeElement(child, depth: depth - 1, remaining: &remaining))
            }
            result["children"] = entries
        }
        return result
    }

    private func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
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

// Where to grant the permissions. macOS gives them to the process that is responsible for this server: the
// terminal app for a command-line client, or this server itself when a desktop app such as Claude starts
// it on its own behalf. macOS 27 renamed the Accessibility pane.
enum PermissionHint {
    static var accessibilityPane: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
    static let grantee = "Turn it on for MacControlHelper when Claude Desktop or another desktop app runs this server, or for your terminal app when a command-line client does"
    static var accessibility: String {
        "\(grantee), in System Settings > Privacy & Security > \(accessibilityPane). Then quit and reopen that app."
    }
    static let screenRecording = "\(grantee), in System Settings > Privacy & Security > Screen & System Audio Recording. Then quit and reopen that app."
}

@main
private enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        // MacControl.app starts the helper app with these through Launch Services, so macOS treats the
        // helper as responsible for itself, as it is when a desktop client runs it.
        case "--request-permissions":
            // Shows the macOS prompts and adds "MacControlHelper" to both lists, ready to be turned on.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestScreenCaptureAccess()
            Thread.sleep(forTimeInterval: 1)
        case "--check-permissions":
            guard arguments.count == 2 else { exit(2) }
            let result = ["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()]
            guard let data = try? JSONSerialization.data(withJSONObject: result),
                  (try? data.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)) != nil else { exit(1) }
        default:
            MacControlServer().serve()
        }
    }
}
