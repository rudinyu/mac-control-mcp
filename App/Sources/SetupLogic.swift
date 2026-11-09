import Foundation

// The setup window's decisions, kept apart from the checks and changes they lead to, so tests can reach them.

enum StepState: Equatable {
    case unknown
    case working(String)
    case done(String)
    case needsAction(String)
    case failed(String)
    case notNeeded(String)

    var isDone: Bool {
        switch self {
        case .done, .notNeeded: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    // What VoiceOver says for the status icon.
    var accessibilityLabel: String {
        switch self {
        case .unknown: return String(localized: "Checking")
        case .working: return String(localized: "In progress")
        case .done: return String(localized: "Done")
        case .needsAction: return String(localized: "Needs action")
        case .failed: return String(localized: "Failed")
        case .notNeeded: return String(localized: "Not needed")
        }
    }
}

enum Client: String, CaseIterable, Identifiable {
    case claudeDesktop = "Claude Desktop"
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    // The app that macOS asks to grant Accessibility and Screen Recording to.
    var permissionHolder: String {
        switch self {
        case .claudeDesktop: return "MacControlHelper"
        case .claudeCode: return String(localized: "your terminal app (Terminal, iTerm2, …)")
        case .codex: return String(localized: "MacControlHelper for the Codex app, or your terminal app")
        }
    }

    var reloadHint: String {
        switch self {
        case .claudeDesktop: return String(localized: "Quit and reopen Claude to load the tools.")
        case .claudeCode, .codex: return String(localized: "Start a new \(rawValue) session to load the tools.")
        }
    }
}

// The one-line state of the whole setup, shown in the header and the menu bar.
struct Summary: Equatable {
    enum Level { case ready, working, needsAction, failed }
    let level: Level
    let text: String
    // False when the remaining step is outside MacControl, such as restarting a client, so Set Up cannot help.
    var setUpHelps = true
}

extension Summary {
    // The summary of the steps' states. The first rule that applies wins: work in progress, a copy that must be
    // moved, failures, settings to apply, steps left, then what is outside MacControl, before Ready.
    static func of(steps: [StepState], busy: Bool, hasChecked: Bool, isTranslocated: Bool, staleClients: Int,
                   enabledClients: Int, helperPermissionsMissing: Bool, oldServersRunning: Bool, enableExec: Bool) -> Summary {
        if busy || steps.contains(where: \.isWorking) { return Summary(level: .working, text: String(localized: "Setting up…")) }
        if !hasChecked { return Summary(level: .working, text: String(localized: "Checking this Mac…")) }
        // Set Up cannot fix a translocated copy; only moving the app can.
        if isTranslocated {
            return Summary(level: .needsAction, text: String(localized: "Quit MacControl, then open it from Applications."))
        }
        if steps.contains(where: \.isFailed) { return Summary(level: .failed, text: String(localized: "Something needs attention below.")) }
        if staleClients > 0 {
            return Summary(level: .needsAction, text: staleClients == 1
                ? String(localized: "Settings changed. Apply them to 1 client.")
                : String(localized: "Settings changed. Apply them to \(staleClients) clients."))
        }
        let remaining = steps.filter { !$0.isDone }.count
        if remaining > 0 {
            return Summary(level: .needsAction, text: remaining == 1
                ? String(localized: "1 step left. Click Set Up.")
                : String(localized: "\(remaining) steps left. Click Set Up."))
        }
        if enabledClients == 0 {
            return Summary(level: .needsAction, text: String(localized: "Install or turn on Claude Desktop, Claude Code, or Codex."))
        }
        if helperPermissionsMissing {
            return Summary(level: .needsAction, text: String(localized: "Turn on MacControlHelper in System Settings. Click Set Up."))
        }
        if oldServersRunning {
            return Summary(level: .needsAction, text: String(localized: "Restart your agent apps to use this version."), setUpHelps: false)
        }
        let text: String
        switch (enabledClients == 1, enableExec) {
        case (true, true): text = String(localized: "Ready: 1 client connected, sandbox ready.")
        case (true, false): text = String(localized: "Ready: 1 client connected.")
        case (false, true): text = String(localized: "Ready: \(enabledClients) clients connected, sandbox ready.")
        case (false, false): text = String(localized: "Ready: \(enabledClients) clients connected.")
        }
        return Summary(level: .ready, text: text)
    }
}

// What the window shows for a client, and whether it needs its settings applied or still has servers while
// turned off.
struct ClientStatus: Equatable {
    let state: StepState
    var stale = false
    var leftover = false

    static func of(locationReady: Bool, enabled: Bool, connected: Bool, hasEntry: Bool) -> ClientStatus {
        // Until MacControl runs from Applications, its helper paths differ from what clients use, so a
        // comparison would wrongly call every client outdated.
        if !locationReady, enabled {
            // Whether the entry works cannot be told from here, so only say that one exists. The Location
            // step keeps the summary from reporting Ready meanwhile.
            return ClientStatus(state: .notNeeded(hasEntry ? String(localized: "Previously set up. Checked once MacControl runs from Applications.")
                                                           : String(localized: "Connects once MacControl runs from Applications.")))
        }
        if !enabled {
            return ClientStatus(state: .notNeeded(hasEntry ? String(localized: "Turned off, but still connected") : String(localized: "Turned off")),
                                leftover: hasEntry)
        }
        if connected { return ClientStatus(state: .done(String(localized: "Connected"))) }
        if hasEntry { return ClientStatus(state: .needsAction(String(localized: "Connected with older settings")), stale: true) }
        return ClientStatus(state: .needsAction(String(localized: "Not connected yet")))
    }
}

extension RuntimeSelection {
    // A runtime forced for testing and support with
    // `defaults write tw.com.eaman.MacControl runtimeOverride managedColima` (or appleContainer).
    static func override(_ stored: String?) -> RuntimeChoice? {
        switch stored {
        case "managedColima": return .managedColima
        case "appleContainer": return .appleContainer
        default: return nil
        }
    }

    // The runtime to use. remembered is the runtime set up before, if its program is still there.
    // workingDocker, which starts Docker to check it, is called only when nothing else decides.
    static func choose(override stored: String?, remembered: RuntimeChoice?, hasOlderColima: Bool, cpu: CPU, macOSMajor: Int,
                       workingDocker: () async -> String?) async -> RuntimeChoice {
        if let forced = override(stored) { return forced }
        // Once a runtime is set up, keep it: after an update or a macOS upgrade, switching by itself would
        // leave the old VM and its image behind and give agents a different sandbox. A Docker that has been
        // uninstalled is not passed in, so the app can find another.
        if let remembered { return remembered }
        // Set up by a version that did not remember the runtime. Its Colima may be older than this version
        // wants, which Set Up then updates, so keep using it rather than switch.
        if hasOlderColima { return .managedColima }
        if cpu == .appleSilicon, macOSMajor >= 26 { return .appleContainer }
        return choose(cpu: cpu, macOSMajor: macOSMajor, workingDocker: await workingDocker())
    }

    // Whether removing MacControl deletes the sandbox image from this runtime. The app's own Colima VM is
    // deleted whole instead, and an Apple container tool that is not installed has no image to delete.
    static func removalDeletesImage(_ choice: RuntimeChoice?, appleContainerInstalled: Bool) -> Bool {
        guard let choice, choice != .managedColima else { return false }
        return choice != .appleContainer || appleContainerInstalled
    }
}
