import Foundation

// Decides whether synthetic input can reach the user's apps, from CGSessionCopyCurrentDictionary().
// While the screen is locked, or another user owns the display through fast user switching, input
// would go to the login window instead, so input tools refuse rather than act blindly.
// Returns nil when input can be sent, otherwise the reason it cannot.
func sessionInputBlockReason(_ session: [String: Any]?) -> String? {
    guard let session else {
        return "No macOS login session is available to this process. Run the MCP host in a logged-in desktop session."
    }
    if (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
        return "The screen is locked. Unlock the Mac, then try again; no input was sent."
    }
    if (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == false {
        return "This login session is not on the display (another user is active through fast user switching); no input was sent."
    }
    return nil
}
