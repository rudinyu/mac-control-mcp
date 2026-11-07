import Foundation

struct ToolFailure: Error, CustomStringConvertible {
    var description: String
    let kind: FailureKind
    // Whether the action reached the app, when that is known; otherwise the kind decides.
    let delivered: Bool?
    // More fields for the error's JSON part, such as the menus and sheets an action opened.
    var details: [String: Any] = [:]
    init(_ description: String, _ kind: FailureKind = .invalidArgs, delivered: Bool? = nil) {
        self.description = description
        self.kind = kind
        self.delivered = delivered
    }
}

// What an agent can do about a failure without reading the message. Every error result carries the code,
// whether the input or action reached the app, and how to retry.
enum FailureKind: String {
    case invalidArgs = "INVALID_ARGS"
    case permissionDenied = "PERMISSION_DENIED"
    case screenLocked = "SCREEN_LOCKED"
    case setup = "SETUP_PROBLEM"
    case clipboardUnsafe = "CLIPBOARD_UNSAFE"
    case appNotFound = "APP_NOT_FOUND"
    case appAmbiguous = "APP_AMBIGUOUS"
    case unsupported = "ACTION_UNSUPPORTED"
    case staleScreenshot = "STALE_SCREENSHOT"
    case staleRef = "STALE_REF"
    case focusLost = "FOCUS_LOST"
    case appUnresponsive = "APP_UNRESPONSIVE"
    case busy = "BUSY"
    case internalError = "INTERNAL"
    case timeout = "TIMEOUT"
    case outcomeUnknown = "OUTCOME_UNKNOWN"

    // Only an action that was sent without confirmation can have reached the app. A failure that knows the
    // app accepted the action, but could not confirm its result, says delivered true instead.
    var delivered: Any { self == .outcomeUnknown ? "unknown" : false }

    var retry: String {
        switch self {
        // Change the arguments, or what they name, such as launching the app.
        case .invalidArgs, .appNotFound, .appAmbiguous, .unsupported: return "fix"
        // Needs the user: a permission, an unlocked screen, or a working setup.
        case .permissionDenied, .screenLocked, .setup, .clipboardUnsafe: return "user"
        // Take a new mac_screenshot or mac_ui_tree and use what it returns.
        case .staleScreenshot, .staleRef: return "refresh"
        // The same call can be repeated.
        case .focusLost, .appUnresponsive, .busy, .internalError, .timeout: return "safe"
        // Look at the app before repeating anything.
        case .outcomeUnknown: return "check"
        }
    }
}

// The tools/call result for a failed call: one JSON text, like a successful call's, with the code, whether
// anything was delivered, how to retry, the message, and the failure's details, which cannot replace those.
// There is no structuredContent, since clients check it against the tool's outputSchema, which describes success.
func failureResult(_ error: Error) -> [String: Any] {
    // Every known failure is a ToolFailure, so another error comes from a call whose effect is not known.
    let failure = error as? ToolFailure
    let kind = failure?.kind ?? .outcomeUnknown
    let delivered: Any = failure?.delivered ?? kind.delivered
    let base: [String: Any] = ["code": kind.rawValue, "delivered": delivered, "retry": kind.retry,
                               "message": String(describing: error)]
    let details = ["error": base.merging(failure?.details ?? [:]) { current, _ in current }]
    return ["content": [textContent(jsonString(details))], "isError": true]
}
