import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private struct CaptureSize {
    let width: Int
    let height: Int
    let displayBounds: CGRect
    // The app in front and its window when the screenshot was taken, so a click aimed at an app can be
    // refused when the screen it lands on is no longer the one in the screenshot.
    let focusedPID: pid_t?
    let windowFrame: CGRect?
}

// The app parameter: a running app with a Dock icon, and what the tool does with it.
private func appProperty(_ use: String) -> [String: Any] {
    ["type": "string", "description": "A running app with a Dock icon, by name or bundle ID, such as TextEdit. \(use)"]
}

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

// How much of an app mac_ui_tree reads, and why it stopped early. Elements whose children are not all listed
// carry more_children and a ref, so the agent can read below them with root.
private struct TreeBudget {
    var remaining: Int
    let deadline: Date
    // "element_limit", "time_limit", or "app_not_answering" once the read was cut short.
    var stopped: String?
    var observed = 0
    // Elements the app did not answer for in time.
    var unanswered = 0

    // Whether another element may be read, recording why not.
    mutating func allows() -> Bool {
        if stopped != nil { return false }
        // An app that did not answer once is busy, and every further question would wait out the timeout.
        if unanswered > 0 { stopped = "app_not_answering" } else if remaining <= 0 { stopped = "element_limit" } else if Date() >= deadline { stopped = "time_limit" }
        return stopped == nil
    }
}

// An Accessibility call that fails with cannotComplete only counts as the app not answering when it took at
// least this long; apps also return that error at once for other reasons.
private let axSlowCall: TimeInterval = 1

// Whether an Accessibility call failed because the app did not answer in time.
private func timedOut(_ call: () -> AXError) -> (error: AXError, timedOut: Bool) {
    let started = Date()
    let error = call()
    return (error, error == .cannotComplete && Date().timeIntervalSince(started) >= axSlowCall)
}

// mac_ui_tree reads at most this many elements, for at most this long, so a huge or slow app cannot stall it.
private let treeElementLimit = 200
private let treeTimeLimit: TimeInterval = 5

// mac_find and mac_wait stop after this many elements or this depth, so a huge app cannot stall them.
private let searchNodeLimit = 5000
private let searchDepthLimit = 40

// Limits and choices that the tool schemas, their descriptions, and the argument checks all use.
private let treeDepthLimit = 8
private let treeDefaultDepth = 5
private let findMatchLimit = 50
private let findDefaultLimit = 20
private let waitMinSeconds = 0.5
private let waitMaxSeconds = 30.0
private let waitDefaultSeconds = 10.0
private let textLimit = 2000
private let recordingSecondsLimit = 120
private let scrollLimit = 20
private let mouseActions = ["move", "click", "double_click", "right_click", "drag"]
private let windowActions = ["list", "focus", "move", "resize", "minimize", "restore"]
private let keyModifiers = ["cmd", "shift", "alt", "ctrl"]

// mac_key names and their virtual key codes.
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
// Key names other than single letters and digits, for the schema.
private let namedKeys = keyCodes.keys.filter { $0.count > 1 }.sorted()

// mac_ax_action names and the Accessibility actions they perform. set_value and focus set attributes instead.
private let axActionNames: [String: String] = [
    "press": kAXPressAction, "show_menu": kAXShowMenuAction,
    "increment": kAXIncrementAction, "decrement": kAXDecrementAction,
    "confirm": kAXConfirmAction, "cancel": kAXCancelAction, "raise": kAXRaiseAction,
    "scroll_to_visible": "AXScrollToVisible"
]
// Actions that set a true-or-false attribute, with the attributes to try in order. Outline rows use
// AXDisclosing; other expandable elements use AXExpanded.
private let axStateActions: [String: (attributes: [String], value: Bool)] = [
    "select": (["AXSelected"], true), "deselect": (["AXSelected"], false),
    "expand": (["AXExpanded", "AXDisclosing"], true), "collapse": (["AXExpanded", "AXDisclosing"], false)
]
// Every mac_ax_action action, in the order shown to agents.
private let axAllActions = ["press", "show_menu", "increment", "decrement", "confirm", "cancel", "raise",
                            "scroll_to_visible", "set_value", "focus", "select", "deselect", "expand", "collapse",
                            "check", "uncheck"]
// Web content offers these on nearly every node, so they alone do not earn a ref.
private let axWeakActions: Set<String> = ["show_menu", "focus", "scroll_to_visible"]
// Some menus and pop-ups only return from an action after they close; without a limit the server would hang.
private let axMessagingTimeout: Float = 2

private final class MacControlServer: MCPServer {
    let name = "mac-control"
    let instructions = "Use mac_status first. Use mac_screenshot before mac_mouse; mouse coordinates use the most recent screenshot. When mac_ui_tree or mac_find gives the element a ref, mac_ax_action can act on it without coordinates or focus; use mac_wait to wait for the result. Pass app with the name of the app you are working in to mac_screenshot, mac_mouse, mac_scroll, mac_type_text, and mac_key, so input cannot land in another app. A failed call also returns JSON with code, delivered, and retry; follow retry, and check the app before repeating an action whose retry is \"check\", since it may have happened. A mac_ax_action result says whether it was verified; when verified is false, read the app before relying on the result. Ask the user before irreversible actions."

    private var lastCapture: CaptureSize?
    private var recordings: [String: Recording] = [:]
    private let refs = RefRegistry()
    // The running call's cancellation; calls run one at a time.
    private var cancellation = Cancellation()
    // The app this server runs under, such as the terminal, Claude, or Codex: the nearest parent process with a
    // Dock icon. Input that reaches it without being aimed at it could answer the agent's own prompts. There is
    // none when the server runs under tmux or another process that launchd started.
    // The parent is read at startup: if it exits later, the server is moved under launchd and the host is lost.
    private let parentPID = getppid()
    private lazy var hostApp: NSRunningApplication? = {
        var pid = parentPID
        while pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }()

    let tools: [[String: Any]] = {
        let role: [String: Any] = ["type": "string", "description": "Accessibility role, with or without the AX prefix, such as button or AXTextField."]
        let text: [String: Any] = ["type": "string", "description": "Text to look for in the title, description, or value, ignoring case."]
        let exact: [String: Any] = ["type": "boolean", "description": "Match the whole text instead of part of it. Default false."]
        let searchRoot: [String: Any] = ["type": "string", "description": "A ref to search below instead of all of the app's windows."]
        let readApp = appProperty("Default is the frontmost app.")
        let recordingID: [String: Any] = ["type": "string", "description": "The ID from mac_record_start."]
        // Input tools can do anything the user could, in any app.
        let sendsInput: [String: Any] = ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]
        let readsOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]

        // Output schemas name the fields agents rely on. Objects stay open, so a field added later is no error.
        func output(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let string: [String: Any] = ["type": "string"]
        let boolean: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": "integer"]
        let optionalString: [String: Any] = ["type": ["string", "null"]]
        let message: [String: Any] = ["type": "string", "description": "What happened, in a sentence."]
        let inputApp: [String: Any] = ["type": "string", "description": "The app in front when the input was sent."]
        let inputWindow: [String: Any] = ["type": ["string", "null"], "description": "The title of the focused window when the input was sent."]
        let keyboardWindow: [String: Any] = ["type": "string", "description": "A window ref from mac_window list. Nothing is sent unless it is the focused window of its app; use mac_window focus with it first. Its app is used when app is left out."]
        let snapshot: [String: Any] = ["type": ["string", "null"], "description": "The snapshot the refs belong to."]
        let elementProperties: [String: Any] = [
            "role": string, "title": string, "value": string, "description": string,
            "ref": ["type": "string", "description": "Given when the element can be acted on, or has children not listed."],
            "actions": ["type": "array", "items": string, "description": "What mac_ax_action can do with the ref."],
            "children": ["type": "array", "description": "The elements below it, each like this one."],
            "more_children": ["type": "integer", "description": "Children not listed; pass the ref as root to read them."],
            "unanswered": ["type": "boolean", "description": "The app did not answer for this element."]
        ]
        let element: [String: Any] = ["type": "object", "properties": elementProperties, "required": ["role"]]
        let elements: [String: Any] = ["type": "array", "items": element]
        let kind: [String: Any] = ["type": "string", "enum": ["menu", "sheet", "dialog", "popover", "panel", "window"]]
        var openedProperties = elementProperties
        openedProperties["kind"] = kind
        let openedSurface: [String: Any] = ["type": "object", "properties": openedProperties, "required": ["kind", "role"]]
        let closedSurface: [String: Any] = ["type": "object", "properties": ["kind": kind, "title": optionalString], "required": ["kind", "title"]]
        let number: [String: Any] = ["type": "number"]
        let point: [String: Any] = ["type": "object", "properties": ["x": number, "y": number]]
        let rectangle: [String: Any] = ["type": "object", "properties": ["x": number, "y": number, "width": number, "height": number],
                                        "required": ["x", "y", "width", "height"]]
        let window: [String: Any] = [
            "type": "object",
            "properties": ["app": string, "bundle_id": string, "title": string, "frame": ["type": ["object", "null"], "description": "x, y, width, and height in screen points."],
                           "minimized": boolean, "main": boolean, "focused": boolean, "ref": string]
        ]
        let recording = output([
            "recording_id": string, "state": ["type": "string", "enum": ["recording", "ready", "failed"]],
            "duration_seconds": integer, "elapsed_seconds": integer,
            "path": ["type": "string", "description": "The MOV file, once state is ready."], "bytes": integer
        ], required: ["recording_id", "state", "duration_seconds", "elapsed_seconds", "path", "bytes"])
        return [
            [
                "name": "mac_status",
                "description": "Report macOS Screen Recording and Accessibility permission, whether the screen is locked, the frontmost app, and main display geometry. Call this before controlling the Mac. While screen_locked is true, mouse and keyboard tools refuse to send input.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                "outputSchema": output([
                    "screen_recording": boolean, "accessibility": boolean, "display_available": boolean,
                    "screen_locked": ["type": "boolean", "description": "While true, mouse and keyboard tools refuse to send input."],
                    "screen_locked_reason": optionalString, "frontmost_app": optionalString, "frontmost_bundle_id": optionalString,
                    "main_display": rectangle.merging(["description": "In screen points."]) { $1 },
                    "last_screenshot": ["type": ["object", "null"], "properties": ["width": integer, "height": integer],
                                        "description": "The image size of the last mac_screenshot."],
                    "cursor_display": point, "cursor_screenshot": point
                ], required: ["screen_recording", "accessibility", "display_available", "screen_locked", "main_display"]),
                "annotations": readsOnly
            ],
            [
                "name": "mac_screenshot",
                "description": "Capture the main display. The image is the size of the screen in points, the units of mac_window frames, and its x/y positions are the coordinates for mac_mouse until the next screenshot. Requires Screen Recording permission, and Accessibility permission when app is given.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": appProperty("It is brought to the front first, which also brings back a window from the Stage Manager strip; an app with no open window may open a new one. mac_mouse with the same app then checks that its window has not changed since."),
                        "full_resolution": ["type": "boolean", "description": "Keep every pixel of a Retina display, for reading small text. The image is then larger, usually twice the width and height, and mac_mouse takes positions in it. Default false."]
                    ],
                    "additionalProperties": false
                ],
                "outputSchema": output([
                    "width": ["type": "integer", "description": "Image width, the x range for mac_mouse."],
                    "height": ["type": "integer", "description": "Image height, the y range for mac_mouse."],
                    "full_resolution": ["type": "boolean", "description": "The image keeps every pixel, so its positions are pixels, not screen points."],
                    "front_app": optionalString,
                    "changed_during_capture": ["type": "boolean", "description": "The front app or its window changed during the capture; take another screenshot before clicking with app. Missing without Accessibility permission."],
                    "message": message
                ], required: ["width", "height", "full_resolution", "front_app", "message"]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            ],
            [
                "name": "mac_request_screen_recording",
                "description": "Ask macOS to show its Screen Recording permission prompt for this local server. The user must grant access in macOS and restart the host app if required.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                "outputSchema": output(["granted": boolean, "message": message], required: ["granted", "message"]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            ],
            [
                "name": "mac_ui_tree",
                "description": "Read a limited Accessibility tree of an app's focused window and focused element: at most \(treeElementLimit) elements, for at most \(Int(treeTimeLimit)) seconds. Elements that can be acted on get a ref and their actions, for mac_ax_action. An element read again keeps its ref, and refs keep working until the element goes away, the app quits or relaunches, or the app's refs reach \(snapshotRefLimit). For a large window, read with a small max_depth, then pass a ref as root. In the result, more_children counts the children not listed; complete is false when the read stopped early (stopped_by: element_limit, time_limit, or app_not_answering) or an element is marked unanswered, but not for children left out by max_depth. Password values are left out. Does not change which app is in front. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "max_depth": ["type": "integer", "minimum": 0, "maximum": treeDepthLimit, "description": "Levels to read below the window or root. Default \(treeDefaultDepth). Deeper children are counted in more_children."],
                        "root": ["type": "string", "description": "A ref to read below instead of the focused window, such as one with more_children. This adds to the app's current snapshot instead of starting a new one."],
                        "app": readApp
                    ],
                    "additionalProperties": false
                ],
                "outputSchema": output([
                    "app": string, "bundle_id": string, "snapshot": snapshot, "tree": element,
                    "focused": ["type": ["object", "null"], "description": "The focused element, read separately."],
                    "root": string,
                    "complete": ["type": "boolean", "description": "false when the read stopped early or an element is unanswered; children left out only by max_depth do not count."],
                    "truncated": boolean,
                    "stopped_by": ["type": ["string", "null"], "description": "element_limit, time_limit, or app_not_answering when the read stopped early."],
                    "elements_read": integer, "unanswered": integer
                ], required: ["app", "snapshot", "tree", "complete", "truncated", "stopped_by", "elements_read", "unanswered"]),
                "annotations": readsOnly
            ],
            [
                "name": "mac_find",
                "description": "Search an app for elements by role and/or text, up to \(searchNodeLimit) elements deep, far deeper than mac_ui_tree. Returns the matches with refs for mac_ax_action, keeping the app's existing refs. complete is false when the search was cut short; stopped_by says why, and app_not_answering means the app is busy or hung. Does not change which app is in front. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "role": role, "text": text, "exact": exact,
                        "limit": ["type": "integer", "minimum": 1, "maximum": findMatchLimit, "description": "Most matches to return. Default \(findDefaultLimit)."],
                        "root": searchRoot, "app": readApp
                    ],
                    "additionalProperties": false
                ],
                "outputSchema": output([
                    "app": string, "snapshot": snapshot, "matches": elements,
                    "complete": ["type": "boolean", "description": "false when the search was cut short, so a missing match is not certain."],
                    "stopped_by": ["type": ["string", "null"], "description": "element_limit, time_limit, or app_not_answering when the search stopped early."]
                ], required: ["app", "snapshot", "matches", "complete", "stopped_by"]),
                "annotations": readsOnly
            ],
            [
                "name": "mac_wait",
                "description": "Wait until an element matching role and/or text is present, or until none is left, checking about four times a second. Use it after an action instead of polling with mac_ui_tree, such as to wait for a dialog or for a spinner to go away. Returns the matches with refs, or fails with TIMEOUT, or with APP_UNRESPONSIVE when the app stopped answering. Does not change which app is in front. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "role": role, "text": text, "exact": exact,
                        "state": ["type": "string", "enum": ["present", "absent"], "description": "present (default) waits for a match; absent waits until there is none."],
                        "timeout_seconds": ["type": "number", "minimum": waitMinSeconds, "maximum": waitMaxSeconds, "description": "How long to wait. Default \(Int(waitDefaultSeconds))."],
                        "root": searchRoot, "app": readApp
                    ],
                    "additionalProperties": false
                ],
                "outputSchema": output([
                    "app": string, "state": ["type": "string", "enum": ["present", "absent"]],
                    "waited_seconds": ["type": "number"], "snapshot": snapshot,
                    "matches": ["type": "array", "items": element, "description": "The matches, when state is present."]
                ], required: ["app", "state", "waited_seconds"]),
                "annotations": readsOnly
            ],
            [
                "name": "mac_window",
                "description": "List or arrange windows. Frames are in screen points, as in mac_status main_display and the default mac_screenshot image. With Stage Manager on, macOS may ignore move, resize, minimize, and restore, which is reported as OUTCOME_UNKNOWN. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": windowActions, "description": "list returns each window's title, frame, state, and a ref. focus brings the window and its app to the front, restoring it if minimized. move sets its top-left corner to x, y; resize sets width and height; both report the frame the app actually took, which can differ. minimize and restore change whether it is minimized."],
                        "window": ["type": "string", "description": "A window ref from mac_window list, mac_find, or mac_ui_tree. Without it, the action applies to the focused window of app."],
                        "x": ["type": "number", "description": "For move: the left edge, in screen points."],
                        "y": ["type": "number", "description": "For move: the top edge, in screen points."],
                        "width": ["type": "number", "minimum": 1, "description": "For resize, in screen points."],
                        "height": ["type": "number", "minimum": 1, "description": "For resize, in screen points."],
                        "app": appProperty("For list, the app whose windows to list; without it, every app with a Dock icon. For the other actions, the app whose focused window is used when window is left out.")
                    ],
                    "required": ["action"], "additionalProperties": false
                ],
                "outputSchema": output((window["properties"] as! [String: Any]).merging([
                    "windows": ["type": "array", "items": window, "description": "For list."],
                    "truncated": boolean, "action": string,
                    "delivered": ["type": "boolean", "description": "false when the window was already in the state asked for, so nothing was sent."],
                    "as_requested": ["type": "boolean", "description": "For move and resize: whether the app took the frame asked for."],
                    "message": message
                ]) { $1 }, required: []),
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            ],
            [
                "name": "mac_ax_action",
                "description": "Act on an element through Accessibility, using a ref from mac_ui_tree, mac_find, mac_wait, or mac_window. Does not move the pointer, change which app is in front, or use the clipboard. A ref stops working when the app's whole tree is read again, the element goes away, or the app quits or relaunches; then nothing is sent. The result says whether anything was sent (delivered) and whether the element read back showing the result (verified, with the attribute in checked). It also lists the menus, sheets, dialogs, popovers, panels, and windows the action opened (each with kind, a ref, and its direct children such as menu items) and closed; an error from an app that did not answer in time, as when a button opens a modal dialog, lists them too. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "A ref such as k3f9q2.12, which names snapshot k3f9q2 and element 12 in it."],
                        "action": ["type": "string", "enum": axAllActions, "description": "press, show_menu, confirm, cancel, raise, and scroll_to_visible leave nothing to read back, so they are never verified; read the app again to see their result. select, deselect, expand, collapse, check, and uncheck do nothing when the element is already in that state. These, focus, and set_value with text fail with OUTCOME_UNKNOWN when the element reads back differently. set_value with a number, increment, decrement, and a focus the element does not report return verified false instead, since a slider can round and a stepper can be at its limit."],
                        "value": ["type": "string", "maxLength": textLimit, "description": "For set_value: the text, or a number for an element that holds one, such as a slider."],
                        "app": appProperty("If given, it must be the ref's app.")
                    ],
                    "required": ["ref", "action"], "additionalProperties": false
                ],
                "outputSchema": output([
                    "delivered": ["type": "boolean", "description": "Whether anything was sent to the app."],
                    "verified": ["type": "boolean", "description": "Whether the element was read back afterwards and shows the result."],
                    "checked": ["type": ["string", "null"], "description": "The attribute read back."],
                    "opened": ["type": "array", "items": openedSurface,
                               "description": "Menus, sheets, dialogs, popovers, panels, and windows the action opened, each with a ref and its direct children."],
                    "closed": ["type": "array", "items": closedSurface,
                               "description": "Those it closed."],
                    "message": message
                ], required: ["delivered", "verified", "checked", "opened", "closed", "message"]),
                "annotations": sendsInput
            ],
            [
                "name": "mac_record_start",
                "description": "Start recording the main display to a local MOV file. Returns an ID; use mac_record_status to get the file's path when it is done. Requires Screen Recording permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["duration_seconds": ["type": "integer", "minimum": 1, "maximum": recordingSecondsLimit, "description": "How long to record."]],
                    "required": ["duration_seconds"], "additionalProperties": false
                ],
                "outputSchema": output(["recording_id": string, "state": string, "duration_seconds": integer], required: ["recording_id", "state", "duration_seconds"]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
            ],
            [
                "name": "mac_record_status",
                "description": "Check whether a screen recording is still running and get the MOV file path when complete.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["recording_id": recordingID],
                    "required": ["recording_id"], "additionalProperties": false
                ],
                "outputSchema": recording,
                "annotations": readsOnly
            ],
            [
                "name": "mac_record_stop",
                "description": "Stop an active recording early. The recording may need a moment to finish writing before mac_record_status reports the file.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["recording_id": recordingID],
                    "required": ["recording_id"], "additionalProperties": false
                ],
                "outputSchema": recording,
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            ],
            [
                "name": "mac_mouse",
                "description": "Move, click, double-click, right-click, or drag on the main display, at a position in the most recent mac_screenshot image. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": mouseActions, "description": "What to do at x, y. drag goes from x, y to to_x, to_y."],
                        "x": ["type": "number", "description": "From the left of the most recent mac_screenshot image, in its units: screen points, or pixels with full_resolution."],
                        "y": ["type": "number", "description": "From the top of the most recent mac_screenshot image, in the same units."],
                        "to_x": ["type": "number", "description": "For drag: where it ends, in the same units."],
                        "to_y": ["type": "number", "description": "For drag: where it ends, in the same units."],
                        "app": appProperty("It is brought to the front first, and nothing is sent unless it is still in front, the last mac_screenshot was taken with it in front, its window has not moved or resized since, and the point is over it. Without app, a click needs the app that was in front for the last mac_screenshot to still be in front with its window unchanged, and may not land on the app running this agent.")
                    ],
                    "required": ["action", "x", "y"],
                    "additionalProperties": false
                ],
                "outputSchema": output(["action": string, "app": inputApp, "message": message], required: ["action", "app", "message"]),
                "annotations": sendsInput
            ],
            [
                "name": "mac_scroll",
                "description": "Scroll by lines at the current pointer position. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "vertical": ["type": "integer", "minimum": -scrollLimit, "maximum": scrollLimit, "description": "Lines to scroll; positive scrolls up."],
                        "horizontal": ["type": "integer", "minimum": -scrollLimit, "maximum": scrollLimit, "description": "Lines to scroll; positive scrolls left."],
                        "app": appProperty("It is brought to the front first, and nothing is scrolled unless it is still in front and the pointer is over it. Without app, the pointer may not be over the app running this agent.")
                    ],
                    "additionalProperties": false
                ],
                "outputSchema": output(["vertical": integer, "horizontal": integer, "app": inputApp, "message": message], required: ["vertical", "horizontal", "app", "message"]),
                "annotations": sendsInput
            ],
            [
                "name": "mac_type_text",
                "description": "Insert Unicode text into the focused field by placing it on the clipboard for a moment and pressing Command-V, then restore the prior clipboard when possible. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "maxLength": textLimit, "description": "The text to insert."],
                        "app": appProperty("It is brought to the front first, and nothing is pasted unless it is still in front. Without app or window, nothing is pasted while the app running this agent is in front."),
                        "window": keyboardWindow
                    ],
                    "required": ["text"], "additionalProperties": false
                ],
                "outputSchema": output(["characters": integer, "app": inputApp, "window": inputWindow, "message": message], required: ["characters", "app", "window", "message"]),
                "annotations": sendsInput
            ],
            [
                "name": "mac_key",
                "description": "Press a key, optionally with modifiers. Examples: key enter; key c with modifiers [cmd]. Requires Accessibility permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string", "description": "A letter a-z, a digit 0-9, or one of \(namedKeys.joined(separator: ", ")). delete is forward delete."],
                        "modifiers": ["type": "array", "items": ["type": "string", "enum": keyModifiers], "uniqueItems": true, "description": "Keys to hold down while pressing key."],
                        "app": appProperty("It is brought to the front first, and no key is sent unless it is still in front. Without app or window, no key is sent while the app running this agent is in front."),
                        "window": keyboardWindow
                    ],
                    "required": ["key"], "additionalProperties": false
                ],
                "outputSchema": output(["keys": ["type": "string", "description": "The keys pressed, such as cmd+c."], "app": inputApp, "window": inputWindow, "message": message], required: ["keys", "app", "window", "message"]),
                "annotations": sendsInput
            ]
        ]
    }()

    // Answers tools/call; a failure is described by failureResult.
    func answer(tool name: String, arguments: [String: Any], cancellation: Cancellation) -> [String: Any] {
        self.cancellation = cancellation
        do {
            return try callTool(name, arguments)
        } catch {
            return failureResult(error)
        }
    }

    private func callTool(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
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
        case "mac_status": return toolResult(status())
        case "mac_screenshot": return try screenshot(args)
        case "mac_request_screen_recording":
            let granted = CGRequestScreenCaptureAccess()
            return toolResult(["granted": granted, "message": granted ? "Screen Recording access is granted." : "Screen Recording access is not granted yet. Complete the macOS permission prompt. \(PermissionHint.screenRecording)"])
        case "mac_ui_tree": return toolResult(try uiTree(args))
        case "mac_ax_action": return toolResult(try axAction(args).report)
        case "mac_find": return toolResult(try find(args))
        case "mac_window": return toolResult(try window(args))
        case "mac_wait": return toolResult(try wait(args))
        case "mac_record_start": return toolResult(try recordStart(args))
        case "mac_record_status": return toolResult(try recordStatus(args))
        case "mac_record_stop": return toolResult(try recordStop(args))
        case "mac_mouse": return toolResult(try mouse(args))
        case "mac_scroll": return toolResult(try scroll(args))
        case "mac_type_text": return toolResult(try typeText(args))
        case "mac_key": return toolResult(try key(args))
        default: throw ToolFailure("Unknown tool: \(name)")
        }
    }

    private func status() -> [String: Any] {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let app = frontmostFromWorkspace()
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
        return info
    }

    private func screenshot(_ args: [String: Any]) throws -> [String: Any] {
        if let value = args["full_resolution"], !(value is Bool) { throw ToolFailure("full_resolution must be true or false.") }
        let fullResolution = args["full_resolution"] as? Bool ?? false
        let target = try targetApp(args)
        guard CGDisplayBounds(CGMainDisplayID()).width > 0 else {
            throw ToolFailure("No Mac display is available to this process. Run the MCP host in a logged-in local desktop session.", .setup)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolFailure("Screen Recording permission is missing. \(PermissionHint.screenRecording)", .permissionDenied)
        }
        if let target {
            try requireAccessibility()
            try bringToFront(target)
        }
        // Read before capturing, so a window that moves during the capture is not recorded as unchanged.
        let trusted = AXIsProcessTrusted()
        let focused = trusted ? focusedApp() : nil
        let frame = focused.flatMap(windowFrame)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mac-control-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", "-t", "jpg", path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ToolFailure("Could not start screencapture: \(error.localizedDescription)", .setup)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: path),
              let captured = NSBitmapImageRep(data: data) else {
            throw ToolFailure("Screen capture failed. Check Screen Recording permission and that this process runs in a logged-in Mac desktop session.", .setup)
        }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        // By default the image is scaled to the screen's size in points: a quarter of the data on a Retina
        // display, under the size clients shrink images to, and in the units of window frames.
        let (image, jpeg) = try fullResolution ? (captured, data) : scaled(captured, data, to: bounds.size)
        let after = trusted ? focusedApp() : nil
        let steady = after?.processIdentifier == focused?.processIdentifier && after.flatMap(windowFrame) == frame
        lastCapture = CaptureSize(width: image.pixelsWide, height: image.pixelsHigh, displayBounds: bounds,
                                  focusedPID: steady ? focused?.processIdentifier : nil, windowFrame: steady ? frame : nil)
        let units = fullResolution ? "pixels" : "screen points"
        var description = "Main display screenshot: \(image.pixelsWide) x \(image.pixelsHigh) \(units). Use these coordinates with mac_mouse."
        if let focused { description += " \(focused.localizedName ?? "An app") is in front." }
        if trusted, !steady { description += " The front app or its window changed during the capture; take another screenshot before clicking with app." }
        var info: [String: Any] = ["width": image.pixelsWide, "height": image.pixelsHigh, "full_resolution": fullResolution,
                                   "front_app": focused?.localizedName ?? NSNull(), "message": description]
        // Only known with Accessibility permission.
        if trusted { info["changed_during_capture"] = !steady }
        return toolResult(info, images: [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]])
    }

    // The capture redrawn at size, as JPEG. A capture already that size or smaller is kept as it is.
    private func scaled(_ image: NSBitmapImageRep, _ data: Data, to size: CGSize) throws -> (NSBitmapImageRep, Data) {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard image.pixelsWide > width || image.pixelsHigh > height else { return (image, data) }
        // No input has been sent, so the call is safe to repeat.
        let failure = ToolFailure("The screenshot could not be scaled. Try full_resolution.", .internalError)
        guard let source = image.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw failure
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaledImage = context.makeImage() else { throw failure }
        let result = NSBitmapImageRep(cgImage: scaledImage)
        guard let jpeg = result.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw failure }
        return (result, jpeg)
    }

    private func recordStart(_ args: [String: Any]) throws -> [String: Any] {
        let seconds = try number(args, "duration_seconds")
        guard seconds.rounded() == seconds, seconds >= 1, seconds <= Double(recordingSecondsLimit) else {
            throw ToolFailure("duration_seconds must be an integer from 1 to \(recordingSecondsLimit).")
        }
        guard CGDisplayBounds(CGMainDisplayID()).width > 0 else {
            throw ToolFailure("No Mac display is available to this process. Run the MCP host in a logged-in local desktop session.", .setup)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolFailure("Screen Recording permission is missing. \(PermissionHint.screenRecording)", .permissionDenied)
        }
        guard !recordings.values.contains(where: { $0.process.isRunning }) else {
            throw ToolFailure("A screen recording is already running.", .busy)
        }
        let directory = try Self.privateRecordingsFolder()
        let id = UUID().uuidString
        let path = directory.appendingPathComponent("\(id).mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", "-v", "-V", String(Int(seconds)), path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ToolFailure("Could not start screencapture; recording was not started: \(error.localizedDescription)", .setup)
        }
        recordings[id] = Recording(process: process, path: path, duration: Int(seconds), startedAt: Date())
        return ["recording_id": id, "state": "recording", "duration_seconds": Int(seconds)]
    }

    private func recording(_ args: [String: Any]) throws -> (String, Recording) {
        guard let id = args["recording_id"] as? String, let entry = recordings[id] else {
            throw ToolFailure("Unknown recording_id.")
        }
        return (id, entry)
    }

    // Inside MacControl.app, recordings go to ~/Movies/MacControl: the bundle is shared by every account,
    // is replaced on update, and writing into it breaks its signature. Removing MacControl keeps them.
    // A source build keeps .build/recordings.
    private static func recordingsFolder() -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/MacControl", isDirectory: true)
        }
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        return executable.deletingLastPathComponent().appendingPathComponent("recordings", isDirectory: true)
    }

    // Only this user may read recordings; screencapture creates each file with the ordinary umask,
    // so the folder itself must be 0700. Folders above it keep their own modes.
    private static func privateRecordingsFolder() throws -> URL {
        let directory = recordingsFolder()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw ToolFailure("Could not create \(directory.path); recording was not started: \(error.localizedDescription)", .setup)
        }
        // Check and change the folder through one descriptor, so a link swapped in cannot redirect the chmod.
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ToolFailure("\(directory.path) is not a folder; move it away and try again.", .setup) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else {
            throw ToolFailure("\(directory.path) is not a folder of yours; move it away and try again.", .setup)
        }
        if info.st_mode & 0o077 != 0, fchmod(fd, 0o700) != 0 {
            throw ToolFailure("Could not make \(directory.path) private; recordings were not started.", .setup)
        }
        return directory
    }

    private func recordStatus(_ args: [String: Any]) throws -> [String: Any] {
        let (id, entry) = try recording(args)
        let size = (try? FileManager.default.attributesOfItem(atPath: entry.path.path)[.size] as? NSNumber)?.intValue ?? 0
        let state: String
        if entry.process.isRunning { state = "recording" }
        else if size > 0 { state = "ready" }
        else { state = "failed" }
        return [
            "recording_id": id, "state": state, "duration_seconds": entry.duration,
            "elapsed_seconds": Int(Date().timeIntervalSince(entry.startedAt)),
            "path": state == "ready" ? entry.path.path : "",
            "bytes": size
        ]
    }

    private func recordStop(_ args: [String: Any]) throws -> [String: Any] {
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
        if let reason = inputBlockReason() { throw ToolFailure(reason, .screenLocked) }
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ToolFailure("Accessibility permission is missing. \(PermissionHint.accessibility)", .permissionDenied)
        }
    }

    private func targetApp(_ args: [String: Any]) throws -> NSRunningApplication? {
        guard let raw = args["app"] else { return nil }
        guard let query = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolFailure("app must be a non-empty app name or bundle ID.")
        }
        // Only regular apps (those with a Dock icon) can be brought to the front and take keyboard input.
        let apps = regularApps()
        let byBundle = apps.filter { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
        let matches = byBundle.isEmpty
            ? apps.filter { $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame }
            : byBundle
        guard !matches.isEmpty else {
            throw ToolFailure("No running app with a Dock icon matches \"\(query)\". Launch it first.", .appNotFound)
        }
        if matches.count == 1 { return matches[0] }
        if let focused = focusedApp(), let match = matches.first(where: { $0.processIdentifier == focused.processIdentifier }) {
            return match
        }
        let listed = matches.map { "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "no bundle ID"), pid \($0.processIdentifier))" }
        throw ToolFailure("\"\(query)\" matches \(matches.count) running apps: \(listed.joined(separator: ", ")). Use a bundle ID, or quit the extra copies.", .appAmbiguous)
    }

    // NSWorkspace updates its running apps and front app only while the main run loop runs, and between requests
    // the server waits without running it, so let it take the updates it has missed before reading them.
    private func catchUpWithWorkspace() {
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    private func frontmostFromWorkspace() -> NSRunningApplication? {
        catchUpWithWorkspace()
        return NSWorkspace.shared.frontmostApplication
    }

    private func regularApps() -> [NSRunningApplication] {
        catchUpWithWorkspace()
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    // Asks Accessibility rather than NSWorkspace, whose frontmostApplication can be stale without a run loop.
    // Returns nil when focus is unknown, so focus checks before input fail closed.
    private func focusedApp() -> NSRunningApplication? {
        if let element = elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return nil }
            return NSRunningApplication(processIdentifier: pid)
        }
        // The system-wide query can fail for every app, with kAXErrorCannotComplete, as on macOS 26. Then ask the
        // apps themselves: NSWorkspace's guess first, after letting it catch up, and the others only if that is wrong.
        // Hung apps could each take the timeout, so the search stops after a second, leaving focus unknown.
        let guess = frontmostFromWorkspace()
        let others = regularApps().filter { $0.processIdentifier != guess?.processIdentifier }
        let deadline = Date().addingTimeInterval(1)
        for app in [guess].compactMap({ $0 }) + others {
            guard Date() < deadline else { return nil }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            if (attribute(element, kAXFrontmostAttribute as CFString) as? Bool) == true { return app }
        }
        return nil
    }

    private func waitUntilFocused(_ app: NSRunningApplication) -> Bool {
        let deadline = Date().addingTimeInterval(activationTimeout)
        // A cancelled call stops waiting, and then sends nothing, as when the app did not come to the front.
        while Date() < deadline, !cancellation.isCancelled {
            if focusedApp()?.processIdentifier == app.processIdentifier { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(focusPollInterval))
        }
        return !cancellation.isCancelled && focusedApp()?.processIdentifier == app.processIdentifier
    }

    private func focusFailure(_ target: NSRunningApplication, _ current: NSRunningApplication?) -> ToolFailure {
        let name = target.localizedName ?? "the app"
        guard let current else {
            return ToolFailure("Could not determine which app has focus, so \(name) could not be confirmed in front; no input was sent. Check Accessibility permission.", .focusLost)
        }
        return ToolFailure("\(current.localizedName ?? "Another app") has focus instead of \(name); no input was sent.", .focusLost)
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

    // The app's focused window, or nil when it has none or does not answer.
    private func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        return elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
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
            throw ToolFailure("\(name) was not steadily in front for the last mac_screenshot; no input was sent. Call mac_screenshot with app \"\(name)\" first.", .staleScreenshot)
        }
        guard let frame = capture.windowFrame, windowFrame(app) == frame else {
            throw ToolFailure("\(name)'s window moved, resized, or changed since the last mac_screenshot, or could not be read; no input was sent. Call mac_screenshot with app \"\(name)\" again.", .staleScreenshot)
        }
    }

    // Mouse events go to whatever is under the pointer, so ask Accessibility which app owns that spot. This
    // also covers the app's own menus and sheets, and refuses another app's window on top, the Dock, and
    // menu bar icons. Returns nil when Accessibility cannot tell.
    private func appAt(_ point: CGPoint) -> pid_t? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func requirePoint(_ point: CGPoint, in app: NSRunningApplication, what: String) throws {
        let owner = appAt(point)
        guard owner == app.processIdentifier else {
            let name = app.localizedName ?? "the app"
            guard let owner else {
                throw ToolFailure("Accessibility could not tell which app is under \(what.lowercased()); no input was sent. Check Accessibility permission, or try again.", .appUnresponsive)
            }
            // Some panels, such as Open and Save in sandboxed apps, run in a separate process.
            let other = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "another process"
            throw ToolFailure("\(what) is not over \(name) but over \(other); no input was sent. Use a point inside \(name) from a mac_screenshot taken with app \"\(name)\". If the point is in a panel that \(name) opened, leave out app.", .staleScreenshot)
        }
    }

    // Input that was not aimed at an app may not reach the app running this agent.
    private func refuseHost(_ pid: pid_t?, _ what: String) throws {
        guard let host = hostApp, let pid, pid == host.processIdentifier else { return }
        let name = host.localizedName ?? "the app running this agent"
        throw ToolFailure("\(what) would go to \(name), the app running this agent; no input was sent. Pass app with the app you mean to use, or app \"\(name)\" to send it there on purpose.")
    }

    // A click without app must still land on the screen the agent saw: the app that was in front for the last
    // screenshot is still in front, and its window has not moved or resized.
    private func requireSameFrontSinceScreenshot() throws {
        guard let capture = lastCapture, let pid = capture.focusedPID else {
            throw ToolFailure("The front app or its window changed during the last mac_screenshot, or Accessibility could not tell which app was in front; no input was sent. Call mac_screenshot again.", .staleScreenshot)
        }
        let front = focusedApp()
        guard front?.processIdentifier == pid, let app = front else {
            let was = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app"
            throw ToolFailure("\(front?.localizedName ?? "Another app") is in front, but \(was) was in front for the last mac_screenshot; no input was sent. Call mac_screenshot again, or pass app.", .staleScreenshot)
        }
        // Both are nil when the app has no window, as when Finder's desktop is in front; that has not changed either.
        guard windowFrame(app) == capture.windowFrame else {
            throw ToolFailure("\(app.localizedName ?? "The front app")'s window moved, resized, or changed since the last mac_screenshot; no input was sent. Call mac_screenshot again.", .staleScreenshot)
        }
    }

    // The window ref a keyboard tool was given, and its app.
    private func inputWindow(_ args: [String: Any]) throws -> (element: AXUIElement, app: NSRunningApplication)? {
        guard args["window"] != nil else { return nil }
        let ref = try resolveRef(args, key: "window", outcome: "no input was sent")
        guard ref.role == kAXWindowRole else {
            throw ToolFailure("Ref \(args["window"] as? String ?? "") has role \(ref.role), not AXWindow. Use a ref from mac_window list.")
        }
        guard let app = NSRunningApplication(processIdentifier: ref.pid) else {
            throw ToolFailure("The window's app has quit; no input was sent.", .staleRef)
        }
        return (ref.element, app)
    }

    // Re-checks focus immediately before posting input, since another app can take focus between tool calls.
    // A terminal hosting the agent may grab focus back right after activation, so re-activate once.
    // With window, that window must also be its app's focused window. Keyboard input without a target may not
    // go to the app running this agent. Returns the app and the title of its focused window.
    // This is best effort: focus can still change in the moment between this check and the posted event.
    private func confirmFocus(_ target: NSRunningApplication?, window: AXUIElement? = nil,
                              keyboard: Bool = false) throws -> (app: String, window: String?) {
        // The screen can lock while the target app is being brought to the front.
        try requireUnlocked()
        var current = focusedApp()
        if let target, current?.processIdentifier != target.processIdentifier {
            try bringToFront(target)
            current = focusedApp()
            guard current?.processIdentifier == target.processIdentifier else { throw focusFailure(target, current) }
        }
        if keyboard, target == nil {
            guard let current else {
                throw ToolFailure("Could not determine which app has focus, so the input could go anywhere; no input was sent. Pass app, or check Accessibility permission.", .focusLost)
            }
            try refuseHost(current.processIdentifier, "The input")
        }
        let focused = current.flatMap { focusedWindow($0.processIdentifier) }
        let title = focused.flatMap(windowTitle)
        if let window, !(focused.map { CFEqual($0, window) } ?? false) {
            let name = current?.localizedName ?? "The app"
            throw ToolFailure("The window given is not \(name)'s focused window\(title.map { "; \"\($0)\" is" } ?? ""); no input was sent. Use mac_window focus with it first.", .focusLost)
        }
        // The last moment a cancelled call can stop with nothing sent.
        try cancellation.check()
        return (current?.localizedName ?? "the frontmost app", title)
    }

    private func windowTitle(_ window: AXUIElement) -> String? {
        shortString(attribute(window, kAXTitleAttribute as CFString))
    }

    private func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let value = args[key] as? NSNumber else { throw ToolFailure("Missing or invalid \(key)") }
        let n = value.doubleValue
        guard n.isFinite else { throw ToolFailure("Invalid \(key)") }
        return n
    }

    private func point(_ args: [String: Any], xKey: String = "x", yKey: String = "y") throws -> CGPoint {
        guard let capture = lastCapture else { throw ToolFailure("Call mac_screenshot before mac_mouse.", .staleScreenshot) }
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

    private func mouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickCount: Int64 = 1) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ToolFailure("Could not create a mouse event; no input was sent.", .internalError)
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        return event
    }

    private func mouse(_ args: [String: Any]) throws -> [String: Any] {
        guard let action = args["action"] as? String else { throw ToolFailure("Missing action") }
        guard mouseActions.contains(action) else {
            throw ToolFailure("Invalid mouse action")
        }
        let target = try targetApp(args)
        let start = try point(args)
        let end = action == "drag" ? try point(args, xKey: "to_x", yKey: "to_y") : nil
        try requireAccessibility()
        try requireUnlocked()
        if let target { try bringToFront(target) }
        let receiver = try confirmFocus(target).app
        if let target {
            try requireUnchangedSinceScreenshot(target)
            // Moving the pointer sends nothing to an app; a drag may end over another app, as a drop onto Finder does.
            if action != "move" { try requirePoint(start, in: target, what: "The point") }
        } else if action != "move" {
            // Only where it starts: a drag may drop onto any app, as with app.
            try requireSameFrontSinceScreenshot()
            try refuseHost(appAt(start), "The \(action.replacingOccurrences(of: "_", with: " "))")
        }
        // Every event is created before any is posted, so a failure cannot leave half a click or a button held down.
        var events: [CGEvent] = []
        switch action {
        case "move":
            events = [try mouseEvent(.mouseMoved, at: start)]
        case "click":
            events = [try mouseEvent(.leftMouseDown, at: start), try mouseEvent(.leftMouseUp, at: start)]
        case "double_click":
            for count in Int64(1)...2 {
                events += [try mouseEvent(.leftMouseDown, at: start, clickCount: count),
                           try mouseEvent(.leftMouseUp, at: start, clickCount: count)]
            }
        case "right_click":
            events = [try mouseEvent(.rightMouseDown, at: start, button: .right),
                      try mouseEvent(.rightMouseUp, at: start, button: .right)]
        case "drag":
            guard let end else { throw ToolFailure("Missing drag destination") }
            events = [try mouseEvent(.leftMouseDown, at: start)]
            for step in 1...12 {
                let t = CGFloat(step) / 12
                let current = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                events.append(try mouseEvent(.leftMouseDragged, at: current))
            }
            events.append(try mouseEvent(.leftMouseUp, at: end))
        default: break
        }
        for (index, event) in events.enumerated() {
            event.post(tap: .cghidEventTap)
            // Spaces the drag steps out so apps see movement rather than a jump.
            if action == "drag", index > 0, index < events.count - 1 { usleep(12_000) }
        }
        return ["action": action, "app": receiver,
                "message": target == nil ? "Mouse \(action) completed." : "Mouse \(action) completed in \(receiver)."]
    }

    private func scroll(_ args: [String: Any]) throws -> [String: Any] {
        let vertical = try args["vertical"].map { _ in try number(args, "vertical") } ?? 0
        let horizontal = try args["horizontal"].map { _ in try number(args, "horizontal") } ?? 0
        guard vertical.rounded() == vertical, horizontal.rounded() == horizontal,
              abs(vertical) <= Double(scrollLimit), abs(horizontal) <= Double(scrollLimit),
              vertical != 0 || horizontal != 0 else {
            throw ToolFailure("Scroll values must be nonzero integers from -\(scrollLimit) to \(scrollLimit).")
        }
        let target = try targetApp(args)
        try requireAccessibility()
        try requireUnlocked()
        if let target { try bringToFront(target) }
        let receiver = try confirmFocus(target).app
        guard let pointer = CGEvent(source: nil)?.location else {
            throw ToolFailure("Could not read the pointer position; no input was sent.", .internalError)
        }
        if let target {
            try requirePoint(pointer, in: target, what: "The pointer")
        } else {
            try refuseHost(appAt(pointer), "The scroll")
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0) else {
            throw ToolFailure("Could not create a scroll event.", .internalError)
        }
        event.post(tap: .cghidEventTap)
        return ["vertical": Int(vertical), "horizontal": Int(horizontal), "app": receiver,
                "message": target == nil ? "Scrolled." : "Scrolled in \(receiver)."]
    }

    private func typeText(_ args: [String: Any]) throws -> [String: Any] {
        guard let value = args["text"] as? String, !value.isEmpty, value.count <= textLimit else {
            throw ToolFailure("text must contain 1 to \(textLimit) characters.")
        }
        let window = try inputWindow(args)
        let target = try targetApp(args) ?? window?.app
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
                    throw ToolFailure("Cannot preserve the current clipboard contents; text entry was cancelled.", .clipboardUnsafe)
                }
                totalBytes += data.count
                guard totalBytes <= 40_000_000 else {
                    throw ToolFailure("The current clipboard is too large to preserve safely; text entry was cancelled.", .clipboardUnsafe)
                }
                copy.setData(data, forType: type)
            }
            savedItems.append(copy)
        }
        // The nspasteboard.org markers ask clipboard history tools not to save the text, which only passes through.
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) else {
            throw ToolFailure("Could not prepare the text for the clipboard.", .internalError)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            pasteboard.clearContents()
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            throw ToolFailure("Could not put text on the clipboard.", .internalError)
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
            throw ToolFailure("Could not create a paste keyboard event.", .internalError)
        }
        let receiver = try confirmFocus(target, window: window?.element, keyboard: true)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(pasteSettleMicroseconds)
        return ["characters": value.count, "app": receiver.app, "window": receiver.window ?? NSNull(),
                "message": "Inserted \(value.count) characters into \(receiver.app) via Command-V."]
    }


    private func key(_ args: [String: Any]) throws -> [String: Any] {
        guard let keyName = (args["key"] as? String)?.lowercased(), let code = keyCodes[keyName] else {
            throw ToolFailure("Unsupported key. Use a-z, 0-9, or one of \(namedKeys.joined(separator: ", ")).")
        }
        let names = args["modifiers"] as? [String] ?? []
        guard names.count <= keyModifiers.count, Set(names).count == names.count,
              names.allSatisfy({ keyModifiers.contains($0) }) else {
            throw ToolFailure("Invalid modifiers")
        }
        let window = try inputWindow(args)
        let target = try targetApp(args) ?? window?.app
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
            throw ToolFailure("Could not create a keyboard event.", .internalError)
        }
        let receiver = try confirmFocus(target, window: window?.element, keyboard: true)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        let keys = (names + [keyName]).joined(separator: "+")
        return ["keys": keys, "app": receiver.app, "window": receiver.window ?? NSNull(), "message": "Pressed \(keys) in \(receiver.app)."]
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

    private func uiTree(_ args: [String: Any]) throws -> [String: Any] {
        let depth = try args["max_depth"].map { _ in try number(args, "max_depth") } ?? Double(treeDefaultDepth)
        guard depth.rounded() == depth, depth >= 0, depth <= Double(treeDepthLimit) else { throw ToolFailure("max_depth must be 0 to \(treeDepthLimit).") }
        var budget = TreeBudget(remaining: treeElementLimit, deadline: Date().addingTimeInterval(treeTimeLimit))
        guard args["root"] != nil else {
            let app = try appToRead(args)
            let pid = app.processIdentifier
            let owner = refs.owner(pid)
            let appElement = AXUIElementCreateApplication(pid)
            // Elements obtained through the app element use its timeout, so a hung app cannot stall the tree.
            AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
            // An app that does not answer for its focused window is busy, so nothing more is asked of it.
            var windowValue: CFTypeRef?
            if timedOut({ AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) }).timedOut {
                budget.observed = 1
                budget.unanswered = 1
                budget.stopped = "app_not_answering"
                return ["app": app.localizedName ?? "Unknown", "bundle_id": app.bundleIdentifier ?? "",
                        "snapshot": owner?.snapshot ?? NSNull(), "focused": NSNull(),
                        "tree": ["role": "AXApplication", "unanswered": true]].merging(treeStatus(budget)) { $1 }
            }
            let focusedWindow = windowValue.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            let root = focusedWindow ?? elementAttribute(appElement, kAXMainWindowAttribute as CFString) ?? appElement
            let tree = describeElement(root, depth: Int(depth), budget: &budget, owner: owner)
            // The focused element has its own small allowance, but not past the time limit.
            var focusBudget = TreeBudget(remaining: 20, deadline: budget.deadline)
            let focused = budget.stopped == "time_limit" || budget.unanswered > 0 ? nil : elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString).map {
                describeElement($0, depth: 1, budget: &focusBudget, owner: owner)
            }
            budget.unanswered += focusBudget.unanswered
            if budget.stopped == nil, let stopped = focusBudget.stopped, stopped != "element_limit" { budget.stopped = stopped }
            return ["app": app.localizedName ?? "Unknown", "bundle_id": app.bundleIdentifier ?? "",
                    "snapshot": owner?.snapshot ?? NSNull(),
                    "focused": focused ?? NSNull(), "tree": tree].merging(treeStatus(budget)) { $1 }
        }
        // Reading below a ref keeps the app's refs, so the agent can map a large window first and then open
        // one part of it.
        let ref = try resolveRef(args, key: "root", outcome: "nothing was read")
        let app = NSRunningApplication(processIdentifier: ref.pid)
        let owner = refs.owner(ref.pid)
        let tree = describeElement(ref.element, depth: Int(depth), budget: &budget, owner: owner)
        return ["app": app?.localizedName ?? "Unknown", "bundle_id": app?.bundleIdentifier ?? "",
                "snapshot": owner?.snapshot ?? NSNull(),
                "root": args["root"] ?? NSNull(), "tree": tree].merging(treeStatus(budget)) { $1 }
    }

    // complete is false when the read stopped early or the app did not answer for some elements; elements
    // left out only because of max_depth do not count.
    private func treeStatus(_ budget: TreeBudget) -> [String: Any] {
        ["complete": budget.stopped == nil && budget.unanswered == 0, "truncated": budget.stopped != nil,
         "stopped_by": budget.stopped ?? NSNull(), "elements_read": budget.observed, "unanswered": budget.unanswered]
    }

    // The app named by app, otherwise the frontmost app. A stale NSWorkspace answer is acceptable here
    // because reading sends no input.
    private func appToRead(_ args: [String: Any]) throws -> NSRunningApplication {
        let target = try targetApp(args)
        try requireAccessibility()
        guard let app = target ?? focusedApp() ?? frontmostFromWorkspace() else {
            throw ToolFailure("No frontmost app found.", .internalError)
        }
        return app
    }

    private func describeElement(_ element: AXUIElement, depth: Int, budget: inout TreeBudget, owner: AXOwner?,
                                 alwaysRef: Bool = false) -> [String: Any] {
        budget.remaining -= 1
        budget.observed += 1
        // Elements do not reliably take the timeout of the app element they came from.
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        // An app that does not answer in time is likely busy, so nothing more is asked about this element.
        var answered = true
        func read(_ name: String) -> CFTypeRef? {
            guard answered else { return nil }
            var value: CFTypeRef?
            let call = timedOut { AXUIElementCopyAttributeValue(element, name as CFString, &value) }
            if call.timedOut { answered = false }
            return call.error == .success ? value : nil
        }
        let role = shortString(read(kAXRoleAttribute)) ?? "unknown"
        var result: [String: Any] = ["role": role]
        if let title = shortString(read(kAXTitleAttribute)) { result["title"] = title }
        if let description = shortString(read(kAXDescriptionAttribute)) { result["description"] = description }
        // A password field reports AXSecureTextField as its role or subrole. The value is read only when both
        // were read, or the element plainly has no subrole, so a failed read cannot let a password through.
        var subroleValue: CFTypeRef?
        let subrole = answered ? timedOut { AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) } : (.cannotComplete, false)
        if subrole.timedOut { answered = false }
        let subroleKnown = subrole.error == .success || subrole.error == .noValue || subrole.error == .attributeUnsupported
        if answered, role != "unknown", subroleKnown, role != "AXSecureTextField",
           shortString(subrole.error == .success ? subroleValue : nil) != "AXSecureTextField",
           let value = shortString(read(kAXValueAttribute)) {
            result["value"] = value
        }
        guard answered else {
            budget.unanswered += 1
            result["unanswered"] = true
            return result
        }
        // Children not listed here, because of max_depth or because the read stopped early, can be read with
        // this element's ref as root.
        var hidden: CFIndex = 0
        var count: CFIndex = 0
        let counted = timedOut { AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) }
        switch counted.error {
        case .success where count > 0:
            hidden = count
            // The budget is only spent on an element that has children, so a whole tree that ends exactly at
            // the limit is still complete.
            guard depth > 0, budget.allows() else { break }
            var childrenValue: CFTypeRef?
            let copied = timedOut { AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) }
            guard copied.error == .success, let children = childrenValue as? [AXUIElement] else {
                if copied.timedOut {
                    budget.unanswered += 1
                    result["unanswered"] = true
                }
                break
            }
            var entries: [[String: Any]] = []
            for child in children {
                guard budget.allows() else { break }
                entries.append(describeElement(child, depth: depth - 1, budget: &budget, owner: owner))
            }
            result["children"] = entries
            hidden = CFIndex(children.count - entries.count)
        case .cannotComplete where counted.timedOut:
            budget.unanswered += 1
            result["unanswered"] = true
        default: break
        }
        if hidden > 0 { result["more_children"] = hidden }
        // The ref is given after the children are read, since only then is it known whether some were left out.
        // Once the app has stopped answering, its actions are not asked for, but an element with children left
        // out still gets a ref, so they can be read later.
        if let owner, role != "unknown", budget.unanswered > 0 {
            if alwaysRef || hidden > 0 { result["ref"] = refs.ref(for: element, role: role, owner: owner) }
        } else if let owner, role != "unknown" {
            let actions = availableActions(element, role: role)
            if alwaysRef || actions.contains(where: { !axWeakActions.contains($0) }) || hidden > 0 {
                result["ref"] = refs.ref(for: element, role: role, owner: owner)
                result["actions"] = actions
            }
        }
        return result
    }

    // Looks up the ref in args[key] and checks that it still names the same kind of element in the same
    // running app. outcome says what did not happen when it does not, such as "no action was sent".
    private func resolveRef(_ args: [String: Any], key: String, outcome: String) throws -> AXRef {
        guard let refName = args[key] as? String, !refName.isEmpty else {
            throw ToolFailure("\(key) must be a ref from mac_ui_tree.")
        }
        let ref: AXRef
        switch refs.lookup(refName) {
        case .found(let found): ref = found
        case .notARef:
            throw ToolFailure("\(refName.count > 40 ? refName.prefix(40) + "…" : refName) is not a ref; \(outcome). Refs look like k3f9q2.12; use one from mac_ui_tree, mac_find, mac_wait, or mac_window list.")
        case .retired(let snapshot, let reason):
            throw ToolFailure("Expired ref \(refName): snapshot \(snapshot) \(reason); \(outcome). Use a ref from the newest mac_ui_tree, or call it again.", .staleRef)
        case .missing(let snapshot, let element, let existed):
            let detail = existed ? "that element no longer exists" : "it has no element \(element)"
            throw ToolFailure("Unknown or expired ref \(refName): snapshot \(snapshot) is current, but \(detail); \(outcome). Call mac_ui_tree again.", .staleRef)
        case .unknownSnapshot(let snapshot):
            throw ToolFailure("Unknown or expired ref \(refName): snapshot \(snapshot) is unknown to this mac-control session, as when it is from before mac-control restarted or was replaced long ago; \(outcome). Call mac_ui_tree again and use a ref from it.", .staleRef)
        }
        let target = try targetApp(args)
        try requireAccessibility()
        let name = NSRunningApplication(processIdentifier: ref.pid)?.localizedName ?? "The app"
        if let target, target.processIdentifier != ref.pid {
            throw ToolFailure("Ref \(refName) belongs to \(name), not \(target.localizedName ?? "that app"); \(outcome).")
        }
        guard refs.confirmCurrentRun(ref) else {
            throw ToolFailure("\(name) has quit or relaunched since mac_ui_tree; \(outcome). Call mac_ui_tree again.", .staleRef)
        }
        AXUIElementSetMessagingTimeout(ref.element, axMessagingTimeout)
        // Read the role again, so an element that went away, or that the app reused for another kind of
        // control, is refused.
        var roleValue: CFTypeRef?
        switch AXUIElementCopyAttributeValue(ref.element, kAXRoleAttribute as CFString, &roleValue) {
        case .success where roleValue as? String == ref.role: return ref
        case .apiDisabled: throw ToolFailure("Accessibility permission is missing. \(PermissionHint.accessibility)", .permissionDenied)
        case .cannotComplete: throw ToolFailure("\(name) did not answer; \(outcome). Try again.", .appUnresponsive)
        default:
            refs.forget(refName)
            throw ToolFailure("The element of ref \(refName) no longer exists or has changed; \(outcome). Call mac_ui_tree again.", .staleRef)
        }
    }

    private struct SearchQuery {
        let role: String?
        let text: String?
        let exact: Bool
    }

    private func searchQuery(_ args: [String: Any]) throws -> SearchQuery {
        func optionalText(_ key: String) throws -> String? {
            guard let raw = args[key] else { return nil }
            guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 200 else {
                throw ToolFailure("\(key) must be text of 1 to 200 characters.")
            }
            return text
        }
        let role = try optionalText("role")
        let text = try optionalText("text")
        guard role != nil || text != nil else { throw ToolFailure("Give role, text, or both.") }
        guard args["exact"] == nil || args["exact"] is Bool else { throw ToolFailure("exact must be true or false.") }
        return SearchQuery(role: role, text: text, exact: args["exact"] as? Bool ?? false)
    }

    private func matches(_ element: AXUIElement, role: String, _ query: SearchQuery) -> Bool {
        // AXButton and button name the same role.
        if let wanted = query.role, role.caseInsensitiveCompare(wanted) != .orderedSame,
           role.caseInsensitiveCompare("AX" + wanted) != .orderedSame {
            return false
        }
        guard let text = query.text else { return true }
        var fields = [kAXTitleAttribute, kAXDescriptionAttribute]
        if !isSecure(element, role: role) { fields.append(kAXValueAttribute) }
        return fields.contains { name in
            let raw = attribute(element, name as CFString)
            guard let field = raw as? String ?? (raw as? NSNumber)?.stringValue else { return false }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return query.exact ? field.compare(text, options: options) == .orderedSame : field.range(of: text, options: options) != nil
        }
    }

    // The roots to search: the ref's element, or every window of the app with the focused one first. nil when
    // the app did not answer, so the search does not wait on it again for each window.
    private func searchRoots(_ pid: pid_t, root: AXRef?) -> [AXUIElement]? {
        if let root { return [root.element] }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        var focused: CFTypeRef?
        if timedOut({ AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) }).timedOut { return nil }
        var roots: [AXUIElement] = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? [$0 as! AXUIElement] : nil } ?? []
        for window in attribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        where !roots.contains(where: { CFEqual($0, window) }) {
            roots.append(window)
        }
        return roots.isEmpty ? [appElement] : roots
    }

    // Reads an attribute the search depends on. nil with readable true means the element simply has none;
    // readable false means it could not be read, and answered false that the app did not answer in time.
    private func searchAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, readable: Bool, answered: Bool) {
        var value: CFTypeRef?
        let call = timedOut { AXUIElementCopyAttributeValue(element, name as CFString, &value) }
        switch call.error {
        case .success: return (value, true, true)
        case .noValue, .attributeUnsupported: return (nil, true, true)
        default: return (nil, false, !call.timedOut)
        }
    }

    private struct SearchResult {
        var found: [AXUIElement] = []
        var complete = true
        // "element_limit", "time_limit", or "app_not_answering" when the search stopped early.
        var stoppedBy: String?
    }

    // Depth-first search in document order. complete is false when a limit, the deadline, or an element that
    // could not be read cut it short, so a missing match is only certain when complete is true. It stops at the
    // first question the app does not answer in time, since every further one would wait out the timeout too.
    private func search(_ pid: pid_t, root: AXRef?, _ query: SearchQuery, limit: Int, deadline: Date) -> SearchResult {
        var result = SearchResult()
        func stop(_ reason: String) -> SearchResult {
            result.complete = false
            result.stoppedBy = reason
            return result
        }
        guard let roots = searchRoots(pid, root: root) else { return stop("app_not_answering") }
        var stack = roots.reversed().map { ($0, 0) }
        var visited = 0
        // Some apps list an element among its own descendants, such as Calculator giving its application element
        // as a window, so elements already searched are skipped instead of searched again until the limit.
        var seen: [CFHashCode: [AXUIElement]] = [:]
        while let (element, depth) = stack.popLast() {
            let hash = CFHash(element)
            if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { continue }
            seen[hash, default: []].append(element)
            if visited >= searchNodeLimit { return stop("element_limit") }
            if Date() >= deadline || cancellation.isCancelled { return stop("time_limit") }
            visited += 1
            // Elements do not reliably take the timeout of the app element they came from.
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            let role = searchAttribute(element, kAXRoleAttribute)
            guard role.answered else { return stop("app_not_answering") }
            let childList = searchAttribute(element, kAXChildrenAttribute)
            guard childList.answered else { return stop("app_not_answering") }
            if !role.readable || !childList.readable { result.complete = false }
            if let role = role.value as? String, matches(element, role: role, query) {
                result.found.append(element)
                if result.found.count >= limit {
                    result.complete = result.complete && stack.isEmpty
                    return result
                }
            }
            guard let children = childList.value as? [AXUIElement], !children.isEmpty else { continue }
            if depth >= searchDepthLimit {
                result.complete = false
                continue
            }
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return result
    }

    // The app and roots for mac_find and mac_wait: below the root ref if given, otherwise the app's windows.
    private func searchScope(_ args: [String: Any]) throws -> (app: NSRunningApplication?, pid: pid_t, root: AXRef?) {
        if args["root"] != nil {
            let ref = try resolveRef(args, key: "root", outcome: "nothing was searched")
            return (NSRunningApplication(processIdentifier: ref.pid), ref.pid, ref)
        }
        let app = try appToRead(args)
        return (app, app.processIdentifier, nil)
    }

    // Every match gets a ref, even one with no action of its own, so it can be read below or waited on.
    private func describeMatches(_ found: [AXUIElement], pid: pid_t) -> [[String: Any]] {
        let owner = refs.owner(pid)
        return found.map { element in
            var budget = TreeBudget(remaining: 1, deadline: .distantFuture)
            return describeElement(element, depth: 0, budget: &budget, owner: owner, alwaysRef: true)
        }
    }

    private func find(_ args: [String: Any]) throws -> [String: Any] {
        let query = try searchQuery(args)
        let limit = try args["limit"].map { _ in try number(args, "limit") } ?? Double(findDefaultLimit)
        guard limit.rounded() == limit, limit >= 1, limit <= Double(findMatchLimit) else { throw ToolFailure("limit must be 1 to \(findMatchLimit).") }
        let scope = try searchScope(args)
        let result = search(scope.pid, root: scope.root, query, limit: Int(limit), deadline: Date().addingTimeInterval(5))
        let matches = describeMatches(result.found, pid: scope.pid)
        var output: [String: Any] = ["app": scope.app?.localizedName ?? "Unknown", "snapshot": refs.snapshot(of: scope.pid) ?? NSNull(),
                                     "matches": matches, "complete": result.complete, "stopped_by": result.stoppedBy ?? NSNull()]
        if result.stoppedBy == "app_not_answering" {
            output["message"] = "\(scope.app?.localizedName ?? "The app") stopped answering Accessibility requests, so the search ended early. It may be busy; try again shortly."
        }
        return output
    }

    private func cgValue<T>(_ element: AXUIElement, _ name: String, _ type: AXValueType, _ empty: T) -> T? {
        guard let value = attribute(element, name as CFString), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = empty
        return AXValueGetValue(value as! AXValue, type, &result) ? result : nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = cgValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = cgValue(window, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func frameJSON(_ rect: CGRect?) -> Any {
        guard let rect else { return NSNull() }
        return ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }

    private func describeWindow(_ element: AXUIElement, app: NSRunningApplication, appElement: AXUIElement) -> [String: Any] {
        let focused = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        var result: [String: Any] = [
            "app": app.localizedName ?? "Unknown", "bundle_id": app.bundleIdentifier ?? "",
            "title": shortString(attribute(element, kAXTitleAttribute as CFString)) ?? "",
            "frame": frameJSON(frame(of: element)),
            "minimized": boolState(element, kAXMinimizedAttribute) ?? false,
            "main": boolState(element, kAXMainAttribute) ?? false,
            "focused": focused.map { CFEqual($0, element) } ?? false
        ]
        if let owner = refs.owner(app.processIdentifier) {
            result["ref"] = refs.ref(for: element, role: kAXWindowRole, owner: owner)
        }
        return result
    }

    private func window(_ args: [String: Any]) throws -> [String: Any] {
        let actions = windowActions
        guard let action = args["action"] as? String, actions.contains(action) else {
            throw ToolFailure("Invalid action. Use \(actions.joined(separator: ", ")).")
        }
        // Only the arguments of the chosen action are allowed, so a mistyped call does nothing.
        let needed: [String: [String]] = ["move": ["x", "y"], "resize": ["width", "height"]]
        for key in ["x", "y", "width", "height"] where args[key] != nil && !(needed[action] ?? []).contains(key) {
            throw ToolFailure("\(key) is not used with \(action).")
        }
        var numbers: [String: Double] = [:]
        for key in needed[action] ?? [] {
            let value = try number(args, key)
            guard abs(value) <= 100_000, key == "x" || key == "y" || value >= 1 else {
                throw ToolFailure("\(key) is out of range.")
            }
            numbers[key] = value
        }
        if action == "list" {
            guard args["window"] == nil else { throw ToolFailure("window is not used with list.") }
            let apps: [NSRunningApplication]
            if args["app"] != nil {
                apps = [try targetApp(args)!]
            } else {
                apps = regularApps()
            }
            try requireAccessibility()
            var windows: [[String: Any]] = []
            for app in apps where windows.count < 100 {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
                for element in attribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? [] where windows.count < 100 {
                    windows.append(describeWindow(element, app: app, appElement: appElement))
                }
            }
            return ["windows": windows, "truncated": windows.count >= 100]
        }
        guard args["window"] != nil || args["app"] != nil else {
            throw ToolFailure("Give window, a ref from mac_window list, or app to use its focused window.")
        }
        let element: AXUIElement
        let pid: pid_t
        let refName: String
        if args["window"] != nil {
            let ref = try resolveRef(args, key: "window", outcome: "nothing was sent")
            guard ref.role == kAXWindowRole else {
                throw ToolFailure("Ref \(args["window"] as? String ?? "") has role \(ref.role), not AXWindow. Use a ref from mac_window list.")
            }
            (element, pid, refName) = (ref.element, ref.pid, args["window"] as? String ?? "")
        } else {
            let app = try targetApp(args)!
            try requireAccessibility()
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
            guard let focused = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
                    ?? elementAttribute(appElement, kAXMainWindowAttribute as CFString) else {
                throw ToolFailure("\(app.localizedName ?? "The app") has no focused window. Use mac_window list and pass a window ref.", .appNotFound)
            }
            AXUIElementSetMessagingTimeout(focused, axMessagingTimeout)
            (element, pid, refName) = (focused, app.processIdentifier, "")
        }
        try requireUnlocked()
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw ToolFailure("The app has quit; nothing was sent.", .staleRef)
        }
        let name = app.localizedName ?? "The app"
        let label = refName.isEmpty ? "the focused window" : "window \(refName)"
        let appElement = AXUIElementCreateApplication(pid)
        func set(_ attribute: String, _ value: CFTypeRef) throws {
            guard isSettable(element, attribute as CFString) else {
                throw ToolFailure("\(name) does not let \(label) be changed this way (\(attribute) is fixed); nothing was sent.", .unsupported)
            }
            let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
            guard error == .success else { throw axFailure(error, action, refName: refName, appName: name) }
        }
        switch action {
        case "focus":
            if boolState(element, kAXMinimizedAttribute) == true { try set(kAXMinimizedAttribute, kCFBooleanFalse) }
            let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            guard raised == .success else { throw axFailure(raised, "focus", refName: refName, appName: name) }
            try bringToFront(app)
            guard settles({ elementAttribute(appElement, kAXFocusedWindowAttribute as CFString).map { CFEqual($0, element) } ?? false }) else {
                throw ToolFailure("\(name) came to the front, but \(label) did not become its focused window. Call mac_window list to check.", .outcomeUnknown, delivered: true)
            }
        case "move", "resize":
            var point = CGPoint(x: numbers["x"] ?? 0, y: numbers["y"] ?? 0)
            var size = CGSize(width: numbers["width"] ?? 0, height: numbers["height"] ?? 0)
            let value = action == "move" ? AXValueCreate(.cgPoint, &point) : AXValueCreate(.cgSize, &size)
            guard let value else { throw ToolFailure("Could not create the window \(action == "move" ? "position" : "size"); nothing was sent.", .internalError) }
            try set(action == "move" ? kAXPositionAttribute : kAXSizeAttribute, value)
        case "minimize", "restore":
            let wanted = action == "minimize"
            if boolState(element, kAXMinimizedAttribute) == wanted {
                var result = describeWindow(element, app: app, appElement: appElement)
                result["action"] = action
                result["delivered"] = false
                result["message"] = "\(label.prefix(1).uppercased() + label.dropFirst()) of \(name) is already \(wanted ? "minimized" : "not minimized"), so nothing was sent."
                return result
            }
            try set(kAXMinimizedAttribute, wanted ? kCFBooleanTrue : kCFBooleanFalse)
            // The Dock animation takes a moment.
            guard settles({ boolState(element, kAXMinimizedAttribute) == wanted }) || settles({ boolState(element, kAXMinimizedAttribute) == wanted }) else {
                throw ToolFailure("\(name) accepted \(action) for \(label), but it has not changed yet. Call mac_window list to check.", .outcomeUnknown, delivered: true)
            }
        default: break
        }
        var result = describeWindow(element, app: app, appElement: appElement)
        result["action"] = action
        result["delivered"] = true
        if action == "move" || action == "resize", let actual = frame(of: element) {
            let asked = action == "move"
                ? (abs(actual.origin.x - numbers["x"]!) <= 1 && abs(actual.origin.y - numbers["y"]!) <= 1)
                : (abs(actual.width - numbers["width"]!) <= 1 && abs(actual.height - numbers["height"]!) <= 1)
            result["as_requested"] = asked
        }
        return result
    }

    private func wait(_ args: [String: Any]) throws -> [String: Any] {
        let query = try searchQuery(args)
        let state = args["state"] as? String ?? "present"
        guard args["state"] == nil || ["present", "absent"].contains(args["state"] as? String) else {
            throw ToolFailure("state must be present or absent.")
        }
        let seconds = try args["timeout_seconds"].map { _ in try number(args, "timeout_seconds") } ?? waitDefaultSeconds
        guard seconds >= waitMinSeconds, seconds <= waitMaxSeconds else { throw ToolFailure("timeout_seconds must be \(waitMinSeconds) to \(Int(waitMaxSeconds)).") }
        let scope = try searchScope(args)
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        var sawIncomplete = false
        var unanswered = false
        repeat {
            try cancellation.check()
            var rootRole: CFTypeRef?
            if let root = scope.root, case .invalidUIElement = AXUIElementCopyAttributeValue(root.element, kAXRoleAttribute as CFString, &rootRole) {
                throw ToolFailure("The root element went away while waiting. Call mac_ui_tree again.", .staleRef)
            }
            // Windows are looked up on every try, so a dialog that opens in a new window is found.
            let result = search(scope.pid, root: scope.root, query, limit: 20, deadline: deadline)
            if state == "present", !result.found.isEmpty {
                let matches = describeMatches(result.found, pid: scope.pid)
                return ["app": scope.app?.localizedName ?? "Unknown", "state": state,
                        "waited_seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                        "snapshot": refs.snapshot(of: scope.pid) ?? NSNull(), "matches": matches]
            }
            // An element is only gone when the whole search finished without finding it.
            if state == "absent", result.found.isEmpty, result.complete {
                return ["app": scope.app?.localizedName ?? "Unknown", "state": state,
                        "waited_seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]
            }
            try cancellation.check()
            sawIncomplete = sawIncomplete || !result.complete
            unanswered = result.stoppedBy == "app_not_answering"
            if NSRunningApplication(processIdentifier: scope.pid) == nil {
                throw ToolFailure("The app quit while waiting.", .staleRef)
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.25)))
        } while Date() < deadline
        if unanswered {
            throw ToolFailure("\(scope.app?.localizedName ?? "The app") did not answer Accessibility requests during the last check, so after \(seconds) seconds it is not known whether \(state == "present" ? "a matching element appeared" : "the matching elements went away"). It may be busy; check it with mac_screenshot.", .appUnresponsive)
        }
        let note = sawIncomplete ? " The app's tree was too large or slow to search fully; narrow it with root." : ""
        let outcome = state == "present" ? "No matching element appeared" : "A matching element was still there"
        throw ToolFailure("\(outcome) after \(seconds) seconds.\(note)", .timeout)
    }

    // A password field reports AXSecureTextField as its role or, for NSSecureTextField, as its subrole.
    private func isSecure(_ element: AXUIElement, role: String) -> Bool {
        role == "AXSecureTextField" || shortString(attribute(element, kAXSubroleAttribute as CFString)) == "AXSecureTextField"
    }

    private func isSettable(_ element: AXUIElement, _ name: CFString) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name, &settable) == .success && settable.boolValue
    }

    // The mac_ax_action names this element offers now.
    private func availableActions(_ element: AXUIElement, role: String) -> [String] {
        var names: CFArray?
        let native = AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String] ?? []) : []
        var actions = axActionNames.filter { native.contains($0.value) }.keys.sorted()
        if !isSecure(element, role: role), isSettable(element, kAXValueAttribute as CFString) { actions.append("set_value") }
        if isSettable(element, kAXFocusedAttribute as CFString) { actions.append("focus") }
        for name in ["select", "deselect", "expand", "collapse"]
        where axStateActions[name]!.attributes.contains(where: { isSettable(element, $0 as CFString) }) {
            actions.append(name)
        }
        // A checkbox is checked by pressing it, so check and uncheck press only when the state differs.
        if role == "AXCheckBox", native.contains(kAXPressAction) { actions += ["check", "uncheck"] }
        return actions
    }

    // A true-or-false attribute, or nil when it cannot be read. A checkbox's value is 0, 1, or 2 for mixed.
    private func boolState(_ element: AXUIElement, _ name: String) -> Bool? {
        let value = attribute(element, name as CFString)
        if let flag = value as? Bool { return flag }
        guard let number = value as? NSNumber, number.intValue == 0 || number.intValue == 1 else { return nil }
        return number.intValue == 1
    }

    // Some apps update state after the action returns, as when a row animates open.
    private func settles(_ check: () -> Bool) -> Bool {
        for _ in 0..<10 {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return check()
    }

    // The failure for an Accessibility call that did not succeed. what names the action in messages.
    private func axFailure(_ error: AXError, _ what: String, refName: String, appName: String) -> ToolFailure {
        switch error {
        case .actionUnsupported, .attributeUnsupported, .notImplemented:
            return ToolFailure("\(appName) reported that the element of ref \(refName) does not support \(what), so it was not done.", .unsupported)
        case .illegalArgument:
            return ToolFailure("\(appName) rejected \(what) for ref \(refName), so it was not done.", .unsupported)
        case .invalidUIElement:
            refs.forget(refName)
            return ToolFailure("The element of ref \(refName) no longer exists; nothing was sent. Call mac_ui_tree again.", .staleRef)
        case .apiDisabled:
            return ToolFailure("Accessibility permission is missing. \(PermissionHint.accessibility)", .permissionDenied)
        case .cannotComplete:
            return ToolFailure("\(appName) did not answer in time, so \(what) may or may not have happened. Call mac_ui_tree to check before trying again.", .outcomeUnknown)
        default:
            return ToolFailure("\(what) returned Accessibility error \(error.rawValue), so it may or may not have happened. Call mac_ui_tree to check before trying again.", .outcomeUnknown)
        }
    }

    // A menu, sheet, dialog, popover, or window of an app, as seen before and after an action.
    private struct Surface {
        let element: AXUIElement
        let kind: String
        let title: String?
    }

    // The app's open surfaces: its windows and their sheets, menus under the app element, menus and popovers
    // under near, the element acted on, which is where pop-up and context menus and popovers appear, and the
    // menu or popover near is in.
    // nil when the app does not answer.
    private func surfaces(_ pid: pid_t, near: AXUIElement) -> [Surface]? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        var windowsValue: CFTypeRef?
        let windowsRead = timedOut { AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) }
        guard !windowsRead.timedOut else { return nil }
        func role(_ element: AXUIElement) -> String? {
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            return shortString(attribute(element, kAXRoleAttribute as CFString))
        }
        func surface(_ element: AXUIElement, _ kind: String) -> Surface {
            Surface(element: element, kind: kind, title: shortString(attribute(element, kAXTitleAttribute as CFString)).flatMap { $0.isEmpty ? nil : $0 })
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            return attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        }
        var found: [Surface] = []
        for window in windowsValue as? [AXUIElement] ?? [] {
            AXUIElementSetMessagingTimeout(window, axMessagingTimeout)
            let subrole = shortString(attribute(window, kAXSubroleAttribute as CFString))
            let kind = ["AXDialog": "dialog", "AXSystemDialog": "dialog", "AXFloatingWindow": "panel"][subrole ?? ""] ?? "window"
            found.append(surface(window, kind))
            for child in children(window) {
                switch role(child) {
                case "AXSheet": found.append(surface(child, "sheet"))
                case "AXPopover": found.append(surface(child, "popover"))
                default: break
                }
            }
        }
        for child in children(appElement) where role(child) == "AXMenu" { found.append(surface(child, "menu")) }
        // Two levels below the element, as a menu can sit inside a wrapper. A menu item lists its submenu
        // whether or not it is open, so nothing below a menu or menu item is taken for an open menu.
        let nearRole = role(near) ?? ""
        for child in ["AXMenu", "AXMenuItem"].contains(nearRole) ? [] : children(near) where role(child) != "AXMenuItem" {
            for element in [child] + (["AXMenu", "AXPopover"].contains(role(child) ?? "") ? [] : children(child)) {
                switch role(element) {
                case "AXMenu": found.append(surface(element, "menu"))
                case "AXPopover": found.append(surface(element, "popover"))
                default: break
                }
            }
        }
        // The menu or popover the element is in, so choosing a menu item or cancelling a popover reports it closed.
        var ancestor: AXUIElement? = near
        for _ in 0..<8 {
            guard let current = ancestor, let currentRole = role(current), !["AXWindow", "AXApplication"].contains(currentRole) else { break }
            let parent = elementAttribute(current, kAXParentAttribute as CFString)
            // A closed menu can still be read, but its parent no longer lists it, so only a listed one is open.
            if let kind = ["AXMenu": "menu", "AXPopover": "popover"][currentRole],
               let parent, children(parent).contains(where: { CFEqual($0, current) }) {
                found.append(surface(current, kind))
            }
            ancestor = parent
        }
        // A surface found two ways is listed once.
        return found.enumerated().filter { index, item in !found[..<index].contains { CFEqual($0.element, item.element) } }.map(\.element)
    }

    // The surfaces in after that were not in before, and the other way round. Each opened one gets a ref and
    // its direct children, such as a menu's items, so the agent can act on it at once.
    private func surfaceChanges(before: [Surface], after: [Surface], owner: AXOwner?) -> (opened: [[String: Any]], closed: [[String: Any]]) {
        let opened = after.filter { item in !before.contains { CFEqual($0.element, item.element) } }.map { item -> [String: Any] in
            var budget = TreeBudget(remaining: 30, deadline: Date().addingTimeInterval(1))
            var entry = describeElement(item.element, depth: 1, budget: &budget, owner: owner, alwaysRef: true)
            entry["kind"] = item.kind
            return entry
        }
        let closed = before.filter { item in !after.contains { CFEqual($0.element, item.element) } }.map { item -> [String: Any] in
            ["kind": item.kind, "title": item.title ?? NSNull()]
        }
        return (opened, closed)
    }

    // A sentence naming what opened and closed, for the message part of the result.
    private func surfaceSentence(_ opened: [[String: Any]], _ closed: [[String: Any]]) -> String {
        func names(_ items: [[String: Any]]) -> String {
            items.map { item in
                let kind = item["kind"] as? String ?? "surface"
                let title = [item["title"], item["description"]].compactMap { $0 as? String }.first { !$0.isEmpty }
                let name = title.map { "\(kind) \"\($0)\"" } ?? kind
                return (item["ref"] as? String).map { "\(name) (ref \($0))" } ?? name
            }.joined(separator: ", ")
        }
        var parts: [String] = []
        if !opened.isEmpty { parts.append("Opened: \(names(opened)); its items are listed in opened, or read below its ref with mac_ui_tree root.") }
        if !closed.isEmpty { parts.append("Closed: \(names(closed)).") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    // What mac_ax_action did: whether anything was sent, whether the result was read back and matched, what
    // was read, and what opened and closed. The value read back is not repeated, since it may be private; the
    // surfaces are described as mac_ui_tree would describe them.
    private struct AXActionOutcome {
        var message: String
        let delivered: Bool
        let checked: String?
        let verified: Bool
        var opened: [[String: Any]] = []
        var closed: [[String: Any]] = []
        var report: [String: Any] {
            ["delivered": delivered, "verified": verified, "checked": checked ?? NSNull(), "opened": opened, "closed": closed,
             "message": message]
        }
    }

    private func axAction(_ args: [String: Any]) throws -> AXActionOutcome {
        guard let action = args["action"] as? String, axAllActions.contains(action) else {
            throw ToolFailure("Invalid action. Use \(axAllActions.joined(separator: ", ")).")
        }
        let value = args["value"] as? String
        if action == "set_value" {
            guard let value, value.count <= textLimit else { throw ToolFailure("set_value needs value, the text to set, of up to \(textLimit) characters.") }
        } else if args["value"] != nil {
            throw ToolFailure("value is only used with set_value.")
        }
        let ref = try resolveRef(args, key: "ref", outcome: "no action was sent")
        try requireUnlocked()
        let refName = args["ref"] as? String ?? ""
        let name = NSRunningApplication(processIdentifier: ref.pid)?.localizedName ?? "The app"
        guard availableActions(ref.element, role: ref.role).contains(action) else {
            throw ToolFailure("The element of ref \(refName) does not offer \(action) now; no action was sent. Call mac_ui_tree again to see its actions.", .unsupported)
        }
        // For a state action, the attribute to read back and the state wanted.
        var target: (attribute: String, value: Bool)?
        if let state = axStateActions[action] {
            target = state.attributes.first(where: { isSettable(ref.element, $0 as CFString) }).map { ($0, state.value) }
            // The attribute can stop being settable after the check above.
            guard target != nil else {
                throw ToolFailure("The element of ref \(refName) does not offer \(action) now; nothing was sent. Call mac_ui_tree again to see its actions.", .unsupported)
            }
        } else if action == "check" || action == "uncheck" {
            target = (kAXValueAttribute, action == "check")
        }
        if let target, boolState(ref.element, target.attribute) == target.value {
            return AXActionOutcome(message: "The \(ref.role) ref \(refName) in \(name) is already in that state, so nothing was sent.",
                                   delivered: false, checked: target.attribute, verified: true)
        }
        // A slider or stepper holds a number and rejects text, so a number is sent to an element that has one.
        let asked = action == "set_value" && numberValue(ref.element) != nil ? parseNumber(value!) : nil
        if action == "set_value", numberValue(ref.element) != nil, asked == nil {
            throw ToolFailure("The \(ref.role) of ref \(refName) holds a number, so set_value needs a finite number such as 5 or 0.5; nothing was sent.")
        }
        // Surfaces are compared before and after, so a menu, sheet, or dialog the action opened is reported.
        let surfacesBefore = surfaces(ref.pid, near: ref.element)
        // increment and decrement are checked against the value before them.
        let numberBefore = ["increment", "decrement"].contains(action) ? numberValue(ref.element) : nil
        let error: AXError
        switch action {
        case "set_value":
            let newValue: CFTypeRef = asked.map { NSNumber(value: $0) } ?? value! as CFString
            error = AXUIElementSetAttributeValue(ref.element, kAXValueAttribute as CFString, newValue)
        case "focus": error = AXUIElementSetAttributeValue(ref.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "check", "uncheck": error = AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        default:
            if let target {
                error = AXUIElementSetAttributeValue(ref.element, target.attribute as CFString, target.value ? kCFBooleanTrue : kCFBooleanFalse)
            } else if let native = axActionNames[action] {
                error = AXUIElementPerformAction(ref.element, native as CFString)
            } else {
                throw ToolFailure("Invalid action \(action).")
            }
        }
        guard error == .success else {
            var failure = axFailure(error, action, refName: refName, appName: name)
            // An app can hold the reply until a modal dialog the action opened is up, so what opened tells
            // whether the action happened.
            if failure.kind == .outcomeUnknown, let before = surfacesBefore, let after = surfaces(ref.pid, near: ref.element) {
                let changes = surfaceChanges(before: before, after: after, owner: refs.owner(ref.pid))
                if !changes.opened.isEmpty || !changes.closed.isEmpty {
                    let sheet = changes.opened.contains { ["sheet", "dialog"].contains($0["kind"] as? String ?? "") }
                    failure.description += surfaceSentence(changes.opened, changes.closed)
                        + (sheet ? " A sheet or dialog that opened this way usually means \(action) happened; check that it is the one expected." : "")
                    failure.details = ["opened": changes.opened, "closed": changes.closed]
                }
            }
            throw failure
        }
        // The read-back can fail, as when a state did not change; what opened and closed is reported either way.
        let outcome = Result { try checkAXAction(action: action, ref: ref, refName: refName, name: name, target: target, value: value, asked: asked, numberBefore: numberBefore) }
        let changes: (opened: [[String: Any]], closed: [[String: Any]]) =
            surfacesBefore.map { waitForSurfaceChanges(ref: ref, action: action, before: $0) } ?? ([], [])
        switch outcome {
        case .success(var result):
            result.opened = changes.opened
            result.closed = changes.closed
            result.message += surfaceSentence(changes.opened, changes.closed)
            return result
        case .failure(let error):
            guard var failure = error as? ToolFailure, !changes.opened.isEmpty || !changes.closed.isEmpty else { throw error }
            // Appended in place, so the failure keeps whether the action was delivered.
            failure.description += surfaceSentence(changes.opened, changes.closed)
            failure.details = ["opened": changes.opened, "closed": changes.closed]
            throw failure
        }
    }

    // What opened and closed after an action. Menus and sheets can take a moment to appear, so actions that
    // open them are watched a little longer, and a chosen menu item flashes before its menu closes.
    private func waitForSurfaceChanges(ref: AXRef, action: String, before: [Surface]) -> (opened: [[String: Any]], closed: [[String: Any]]) {
        let checks = ref.role == "AXMenuItem" ? 11 : ["press", "show_menu", "confirm", "cancel"].contains(action) ? 4 : 1
        for attempt in 0..<checks {
            if attempt > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            guard let after = surfaces(ref.pid, near: ref.element) else { break }
            // Compared as sets, since windows can change order without anything opening or closing.
            let opened = after.contains { item in !before.contains { CFEqual($0.element, item.element) } }
            let closed = before.contains { item in !after.contains { CFEqual($0.element, item.element) } }
            if opened || closed { return surfaceChanges(before: before, after: after, owner: refs.owner(ref.pid)) }
        }
        return ([], [])
    }

    // Reads the element back after mac_ax_action sent action, and says what it found.
    private func checkAXAction(action: String, ref: AXRef, refName: String, name: String, target: (attribute: String, value: Bool)?,
                               value: String?, asked: Double?, numberBefore: Double?) throws -> AXActionOutcome {
        if let target, !settles({ boolState(ref.element, target.attribute) == target.value }) {
            throw ToolFailure("\(name) accepted \(action) for ref \(refName), but the element did not change state, so it may not have been applied. Call mac_ui_tree to check.", .outcomeUnknown, delivered: true)
        }
        let sent = "Sent \(action) to \(ref.role) ref \(refName) in \(name)"
        if let target {
            return AXActionOutcome(message: "\(sent); it is now in that state.", delivered: true, checked: target.attribute, verified: true)
        }
        switch action {
        case "set_value":
            // Some fields, such as many on web pages, accept a value without taking it.
            let shown = attribute(ref.element, kAXValueAttribute as CFString)
            if let text = shown as? String {
                guard text.replacingOccurrences(of: "\r\n", with: "\n") == value!.replacingOccurrences(of: "\r\n", with: "\n") else {
                    throw ToolFailure("\(name) accepted set_value for ref \(refName), but the field does not show the new text, so it may not have been applied. Call mac_ui_tree to check, or use mac_type_text.", .outcomeUnknown, delivered: true)
                }
                return AXActionOutcome(message: "\(sent); the field shows the new text.", delivered: true, checked: kAXValueAttribute, verified: true)
            }
            // A slider or stepper can round a number to its step, so a different number is not a contradiction.
            if let asked, numberValue(ref.element) == asked {
                return AXActionOutcome(message: "\(sent); it shows the new value.", delivered: true, checked: kAXValueAttribute, verified: true)
            }
            return AXActionOutcome(message: "\(sent), but its value could not be compared with the one asked for, as when a slider rounds it. Call mac_ui_tree to check.",
                                   delivered: true, checked: nil, verified: false)
        case "focus":
            if !settles({ boolState(ref.element, kAXFocusedAttribute) == true }) {
                // Some web and custom elements take focus without reporting it.
                guard boolState(ref.element, kAXFocusedAttribute) == false else {
                    return AXActionOutcome(message: "\(sent), but it does not report whether it has focus. Call mac_ui_tree to check.",
                                           delivered: true, checked: nil, verified: false)
                }
                throw ToolFailure("\(name) accepted focus for ref \(refName), but the element does not report focus, so it may not have been applied. Call mac_ui_tree to check.", .outcomeUnknown, delivered: true)
            }
            return AXActionOutcome(message: "\(sent); it now has focus in \(name).", delivered: true, checked: kAXFocusedAttribute, verified: true)
        case "increment", "decrement":
            // An element at its limit does not change, so an unchanged value is not a contradiction.
            if let before = numberBefore, settles({ numberValue(ref.element).map { action == "increment" ? $0 > before : $0 < before } ?? false }) {
                return AXActionOutcome(message: "\(sent); its value \(action == "increment" ? "went up" : "went down").", delivered: true, checked: kAXValueAttribute, verified: true)
            }
            return AXActionOutcome(message: "\(sent), but its value did not change as expected; it may be at its limit. Call mac_ui_tree to check.",
                                   delivered: true, checked: nil, verified: false)
        default:
            // press, show_menu, confirm, cancel, raise, and scroll_to_visible leave no state on the element to read.
            return AXActionOutcome(message: "\(sent). \(action) leaves no state on the element to check, so call mac_ui_tree to see the result.",
                                   delivered: true, checked: nil, verified: false)
        }
    }

    // The element's value as a number, such as a slider's or stepper's, or nil when it is not one. A checkbox's
    // or switch's true or false also arrives as a number, but is not one here.
    private func numberValue(_ element: AXUIElement) -> Double? {
        guard let value = attribute(element, kAXValueAttribute as CFString), CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    // A finite decimal number, such as 5 or -0.5; not nan, inf, or a hexadecimal number, which Double accepts.
    private func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
              let number = Double(trimmed), number.isFinite else { return nil }
        return number
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
