import AppKit
import Foundation
import ServiceManagement

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
        case .unknown: return "Checking"
        case .working: return "In progress"
        case .done: return "Done"
        case .needsAction: return "Needs action"
        case .failed: return "Failed"
        case .notNeeded: return "Not needed"
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
        case .claudeDesktop: return "Claude"
        case .claudeCode: return "your terminal app (Terminal, iTerm2, …)"
        case .codex: return "the Codex app, or your terminal app"
        }
    }

    var reloadHint: String {
        switch self {
        case .claudeDesktop: return "Quit and reopen Claude to load the tools."
        case .claudeCode, .codex: return "Start a new \(rawValue) session to load the tools."
        }
    }
}

// The one-line state of the whole setup, shown in the header and the menu bar.
struct Summary: Equatable {
    enum Level { case ready, working, needsAction, failed }
    let level: Level
    let text: String
}

@MainActor
final class SetupModel: ObservableObject {
    // One model drives the window and the menu bar item.
    static let shared = SetupModel()

    private let paths = AppPaths()
    private let defaults = UserDefaults.standard
    let cpu = RuntimeSelection.currentCPU()
    let macOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    @Published var location: StepState = .unknown
    @Published var clients: [Client: StepState] = [:]
    @Published var clientPrograms: [Client: String] = [:]
    @Published var runtimeChoice: RuntimeChoice?
    @Published var runtime: StepState = .unknown
    @Published var image: StepState = .unknown
    @Published var log: [String] = []
    @Published var busy = false
    @Published var manualCommands: [String] = []
    // Clients whose current entry was written with older settings and should be updated.
    @Published var staleClients: Set<Client> = []
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hasChecked = false
    // Called when Set Up finishes with everything ready, so the window can step aside.
    var onReady: (() -> Void)?

    @Published var enableExec: Bool { didSet { defaults.set(enableExec, forKey: "enableExec"); clientsChanged() } }
    @Published var allowHost: Bool { didSet { defaults.set(allowHost, forKey: "allowHost"); clientsChanged() } }
    @Published var workspacePath: String { didSet { defaults.set(workspacePath, forKey: "workspace"); clientsChanged() } }

    init() {
        enableExec = defaults.object(forKey: "enableExec") as? Bool ?? true
        allowHost = defaults.bool(forKey: "allowHost")
        workspacePath = defaults.string(forKey: "workspace")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AgentWorkspace").path
    }

    var workspace: URL { URL(fileURLWithPath: (workspacePath as NSString).expandingTildeInPath) }

    func isEnabled(_ client: Client) -> Bool { defaults.object(forKey: "use." + client.rawValue) as? Bool ?? true }

    // Turning a client on connects it; turning it off removes this app's servers from it.
    func setEnabled(_ client: Client, _ on: Bool) async {
        defaults.set(on, forKey: "use." + client.rawValue)
        objectWillChange.send()
        if on { await connect(client) } else { await disconnect(client) }
    }

    var detectedClients: [Client] { Client.allCases.filter { clients[$0] != nil } }
    var enabledClients: [Client] { detectedClients.filter(isEnabled) }

    var summary: Summary {
        let steps = [location, runtime, image] + enabledClients.compactMap { clients[$0] }
        if busy || steps.contains(where: \.isWorking) { return Summary(level: .working, text: "Setting up…") }
        if !hasChecked { return Summary(level: .working, text: "Checking this Mac…") }
        if steps.contains(where: \.isFailed) { return Summary(level: .failed, text: "Something needs attention below.") }
        if !staleClients.isEmpty {
            return Summary(level: .needsAction, text: "Settings changed. Apply them to \(staleClients.count) client\(staleClients.count == 1 ? "" : "s").")
        }
        let remaining = steps.filter { !$0.isDone }.count
        if remaining > 0 { return Summary(level: .needsAction, text: "\(remaining) step\(remaining == 1 ? "" : "s") left. Click Set Up.") }
        if enabledClients.isEmpty { return Summary(level: .needsAction, text: "Install or turn on Claude Desktop, Claude Code, or Codex.") }
        let clientText = "\(enabledClients.count) client\(enabledClients.count == 1 ? "" : "s") connected"
        return Summary(level: .ready, text: "Ready: " + clientText + (enableExec ? ", sandbox running." : "."))
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            note("Could not change Open at Login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    var workspaceProblem: String? {
        mountRejection(workspace, home: FileManager.default.homeDirectoryForCurrentUser, protected: [paths.bundle])
    }

    var appleSiliconNote: String? {
        runtimeChoice == .appleContainer
            ? "Apple container support has not yet been verified on Apple silicon hardware. Please report problems."
            : nil
    }

    private func note(_ line: String) { log.append(line) }

    // MARK: Checks

    func refresh() async {
        guard !busy else { return }
        checkLocation()
        await checkRuntime()
        await detectClients()
        hasChecked = true
    }

    func checkLocation() {
        location = paths.bundle.path.hasPrefix("/Applications/")
            ? .done("Installed in \(paths.bundle.deletingLastPathComponent().path)")
            : .needsAction("Move MacControl to the Applications folder, so clients keep finding it.")
    }

    private func requireUsableWorkspace() throws {
        if let problem = workspaceProblem { throw InstallFailure(description: "The workspace cannot be used: \(problem)") }
    }

    // The servers as clients should run them, with this app's current settings.
    var servers: [ServerSpec] {
        var list = [ServerSpec(name: "mac-control", command: paths.controlServer.path, environment: [:])]
        if enableExec, let choice = runtimeChoice {
            var env = ["MAC_EXEC_WORKSPACE": workspace.path]
            switch choice {
            case .appleContainer:
                env["MAC_EXEC_RUNTIME"] = "apple"
                env["MAC_EXEC_CONTAINER"] = paths.appleContainer.path
            case .existingDocker(let docker):
                env["MAC_EXEC_DOCKER"] = docker
            case .managedColima:
                env["MAC_EXEC_DOCKER"] = paths.docker.path
                env["MAC_EXEC_DOCKER_HOST"] = "unix://" + paths.colimaSocket.path
                // Lets mac-exec start the VM again after a restart, without opening this app.
                env["MAC_EXEC_COLIMA"] = paths.colima.path
                env["MAC_EXEC_COLIMA_PROFILE"] = Installer.colimaProfile
                env["MAC_EXEC_COLIMA_PATH"] = Installer.managedEnvironment["PATH"]
                env["MAC_EXEC_COLIMA_DOCKER_CONFIG"] = paths.dockerConfig.path
            }
            if allowHost { env["MAC_EXEC_ALLOW_HOST"] = "1" }
            list.append(ServerSpec(name: "mac-exec", command: paths.execServer.path, environment: env))
        }
        return list
    }

    var claudeDesktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    func detectClients() async {
        var found: [Client: StepState] = [:]
        var stale: Set<Client> = []
        func record(_ client: Client, connected: Bool, hasEntry: Bool) {
            if !isEnabled(client) {
                found[client] = .notNeeded(hasEntry ? "Turned off, but still connected" : "Turned off")
            } else if connected {
                found[client] = .done("Connected")
            } else if hasEntry {
                found[client] = .needsAction("Connected with older settings")
                stale.insert(client)
            } else {
                found[client] = .needsAction("Not connected yet")
            }
        }
        if FileManager.default.fileExists(atPath: "/Applications/Claude.app") || FileManager.default.fileExists(atPath: claudeDesktopConfig.path) {
            let current = try? Data(contentsOf: claudeDesktopConfig)
            record(.claudeDesktop, connected: ClientConfig.claudeDesktopMatches(current, servers: servers),
                   hasEntry: ClientConfig.claudeDesktopHasServers(current))
        }
        for (client, command) in [(Client.claudeCode, "claude"), (Client.codex, "codex")] {
            guard let program = await Installer.locate(command) else { continue }
            clientPrograms[client] = program
            let hasEntry = defaults.string(forKey: fingerprintKey(client)) != nil
            record(client, connected: hasEntry ? await cliConnected(client, program) : false, hasEntry: hasEntry)
        }
        clients = found
        staleClients = stale
    }

    // Updates every client that was connected with older settings.
    func applySettings() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for client in staleClients.sorted(by: { $0.rawValue < $1.rawValue }) { await connect(client) }
    }

    // Settings a client was last connected with. Codex hides environment values when it lists servers,
    // so changed settings are detected by comparing against this record instead.
    private var fingerprint: String {
        servers.map { server in
            ([server.name, server.command] + server.environment.keys.sorted().map { "\($0)=\(server.environment[$0]!)" })
                .joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
    }

    private func fingerprintKey(_ client: Client) -> String { "connected." + client.rawValue }

    // A CLI client counts as connected when every server is registered with this app's helper path and
    // the settings have not changed since.
    private func cliConnected(_ client: Client, _ program: String) async -> Bool {
        guard defaults.string(forKey: fingerprintKey(client)) == fingerprint else { return false }
        for server in servers {
            let name = client == .codex ? server.codexName : server.name
            guard let result = try? await Installer.runInLoginShell(program, ["mcp", "get", name], timeout: 30),
                  result.exitCode == 0, result.stdout.contains(server.command) else { return false }
        }
        return true
    }

    private func clientsChanged() {
        Task {
            await checkRuntime()
            await detectClients()
        }
    }

    func checkRuntime() async {
        guard enableExec else {
            runtime = .notNeeded("Sandboxed commands are turned off")
            image = .notNeeded("Not needed")
            return
        }
        let choice: RuntimeChoice
        // For testing and support: `defaults write tw.com.eaman.MacControl runtimeOverride managedColima`
        // (or appleContainer) forces a runtime regardless of this Mac.
        let override = defaults.string(forKey: "runtimeOverride")
        if override == "managedColima" {
            choice = .managedColima
        } else if override == "appleContainer" {
            choice = .appleContainer
        } else if cpu == .appleSilicon, macOSMajor >= 26 {
            choice = .appleContainer
        } else if Installer.managedColimaInstalled {
            // Once MacControl installed Colima, keep using it, even if another Docker appears later.
            choice = .managedColima
        } else {
            var workingDocker: String?
            if let docker = await Installer.locate("docker"),
               let info = try? await Installer.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 20), info.exitCode == 0 {
                workingDocker = docker
            }
            choice = RuntimeSelection.choose(cpu: cpu, macOSMajor: macOSMajor, workingDocker: workingDocker)
        }
        runtimeChoice = choice
        switch choice {
        case .appleContainer:
            runtime = Installer.appleContainerInstalled ? .done("Apple container is installed") : .needsAction("Apple container needs to be installed")
        case .existingDocker(let docker):
            runtime = .done("Using the Docker that is already running (\(docker))")
        case .managedColima:
            if !Installer.managedColimaInstalled {
                runtime = .needsAction("No running Docker was found, so Colima will be downloaded (about 80 MB). If you use Docker Desktop or OrbStack, start it and reopen this window instead.")
            } else {
                runtime = await Installer.colimaRunning() ? .done("Colima is running") : .needsAction("Colima is installed but not running")
            }
        }
        if runtime.isDone {
            image = await Installer.imagePresent(Installer.runtime(for: choice)) ? .done("The sandbox image is built") : .needsAction("The sandbox image needs to be built")
        } else {
            image = .notNeeded("Waits for the sandbox runtime")
        }
    }

    // MARK: Actions

    func setUpEverything() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if enableExec {
            await setUpRuntime()
            if runtime.isDone { await setUpImage() }
        }
        for client in enabledClients where location.isDone && !(clients[client]?.isDone ?? false) {
            await connect(client)
        }
        busy = false
        await refresh()
        if summary.level == .ready { onReady?() }
    }

    func setUpRuntime() async {
        guard let choice = runtimeChoice else { return }
        if let problem = workspaceProblem {
            runtime = .failed("The workspace cannot be used: \(problem)")
            return
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let progress: @Sendable (String) -> Void = { line in Task { @MainActor in self.note(line); self.runtime = .working(line) } }
        do {
            switch choice {
            case .appleContainer:
                if !Installer.appleContainerInstalled {
                    try await Installer.openAppleContainerInstaller(progress: progress)
                    runtime = .needsAction("Finish the Apple container installer, then click Set Up again.")
                    return
                }
                progress("Starting Apple container…")
                try await Installer.startAppleContainer()
            case .existingDocker:
                break
            case .managedColima:
                if !Installer.managedColimaInstalled { try await Installer.installManagedColima(cpu: cpu, progress: progress) }
                try await Installer.startColima(workspace: workspace, readOnly: [], cpu: cpu, progress: progress)
            }
            runtime = .done("\(choice.label) is ready")
        } catch {
            runtime = .failed(String(describing: error))
            note("Error: \(error)")
        }
    }

    func setUpImage() async {
        guard let choice = runtimeChoice else { return }
        let runtime = Installer.runtime(for: choice)
        let progress: @Sendable (String) -> Void = { line in Task { @MainActor in self.note(line); self.image = .working(line) } }
        do {
            try requireUsableWorkspace()
            if !(await Installer.imagePresent(runtime)) { try await Installer.buildImage(runtime, progress: progress) }
            progress("Testing the sandbox…")
            try await Installer.smokeTest(runtime, workspace: workspace)
            image = .done("The sandbox works")
            note("Sandbox test passed.")
        } catch {
            image = .failed(String(describing: error))
            note("Error: \(error)")
        }
    }

    func connect(_ client: Client) async {
        // Clients store the helper paths, so they must point into /Applications, not a copy that may move.
        guard location.isDone else {
            clients[client] = .needsAction("Move MacControl to Applications first, then connect.")
            return
        }
        clients[client] = .working("Connecting…")
        do {
            if enableExec { try requireUsableWorkspace() }
            switch client {
            case .claudeDesktop:
                try connectClaudeDesktop()
            case .claudeCode, .codex:
                try await connectCLI(client)
            }
            note("Connected \(client.rawValue). \(client.reloadHint)")
        } catch {
            clients[client] = .failed(String(describing: error))
            note("Error: \(error)")
            return
        }
        await detectClients()
    }

    func disconnect(_ client: Client) async {
        clients[client] = .working("Disconnecting…")
        do {
            switch client {
            case .claudeDesktop:
                let fm = FileManager.default
                if fm.fileExists(atPath: claudeDesktopConfig.path) {
                    let existing = try Data(contentsOf: claudeDesktopConfig)
                    let removed = try ClientConfig.removeFromClaudeDesktop(existing)
                    if removed != existing {
                        try keepOriginal(existing, of: claudeDesktopConfig)
                        try removed.write(to: claudeDesktopConfig, options: .atomic)
                    }
                }
            case .claudeCode, .codex:
                // Without its CLI the client cannot run the servers, so there is nothing left to remove.
                if let program = clientPrograms[client] {
                    // `mcp get` fails both for a missing server and for a broken CLI, so first make sure the CLI
                    // works; only then does a failing `get` mean the server is not registered.
                    let list = try await Installer.runInLoginShell(program, ["mcp", "list"], timeout: 120)
                    guard list.exitCode == 0 else {
                        throw ConfigFailure(description: "\(client.rawValue) did not answer (\(list.stderr.suffix(200))), so nothing was removed. Try again.")
                    }
                    for name in ClientConfig.managedNames {
                        let serverName = client == .codex ? name.replacingOccurrences(of: "-", with: "_") : name
                        // Ask whether the server exists instead of reading error text, which varies by version.
                        func registered() async throws -> Bool {
                            try await Installer.runInLoginShell(program, ["mcp", "get", serverName], timeout: 30).exitCode == 0
                        }
                        guard try await registered() else { continue }
                        let arguments = client == .codex ? ["mcp", "remove", serverName] : ["mcp", "remove", "--scope", "user", serverName]
                        let result = try await Installer.runInLoginShell(program, arguments)
                        if try await registered() {
                            throw ConfigFailure(description: "\(client.rawValue) still has \(serverName) after removing it: \(result.stderr.suffix(300))")
                        }
                    }
                }
                defaults.removeObject(forKey: fingerprintKey(client))
            }
            note("Disconnected \(client.rawValue). \(client.reloadHint)")
        } catch {
            clients[client] = .failed(String(describing: error))
            note("Error: \(error)")
            return
        }
        await detectClients()
    }

    private func connectClaudeDesktop() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeDesktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A file that exists but cannot be read is an error, never a reason to start a new file.
        let existing: Data? = fm.fileExists(atPath: claudeDesktopConfig.path) ? try Data(contentsOf: claudeDesktopConfig) : nil
        let merged = try ClientConfig.mergeClaudeDesktop(existing, servers: servers)
        guard existing != merged else { return }
        if let existing { try keepOriginal(existing, of: claudeDesktopConfig) }
        try merged.write(to: claudeDesktopConfig, options: .atomic)
    }

    private func connectCLI(_ client: Client) async throws {
        guard let program = clientPrograms[client] else {
            manualCommands = servers.flatMap { server in
                (client == .codex ? ClientConfig.codexCommands(server) : ClientConfig.claudeCodeCommands(server))
                    .dropFirst().map { ClientConfig.displayCommand(client == .codex ? "codex" : "claude", $0) }
            }
            throw ConfigFailure(description: "\(client.rawValue) was not found. Run the commands shown below in Terminal.")
        }
        for server in servers {
            let commands = client == .codex ? ClientConfig.codexCommands(server) : ClientConfig.claudeCodeCommands(server)
            _ = try? await Installer.runInLoginShell(program, commands[0]) // removing an entry that does not exist is fine
            let result = try await Installer.runInLoginShell(program, commands[1])
            guard result.exitCode == 0 else {
                throw ConfigFailure(description: "\(client.rawValue) refused the server \(server.name): \(result.stderr.suffix(400))")
            }
        }
        if client == .codex, servers.contains(where: { $0.name == "mac-exec" }) { try setCodexExecTimeout() }
        defaults.set(fingerprint, forKey: fingerprintKey(client))
    }

    // Sandbox commands may run for up to 600 seconds, longer than Codex allows tools by default.
    private func setCodexExecTimeout() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let toml = try? String(contentsOf: file, encoding: .utf8) else { return }
        let updated = ClientConfig.setCodexServerOption(toml, server: "mac_exec", key: "tool_timeout_sec", value: "620")
        guard updated != toml else { return }
        try keepOriginal(Data(toml.utf8), of: file)
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    // Saves the file as it was before MacControl first changed it, and keeps that copy on later changes.
    private func keepOriginal(_ data: Data, of file: URL) throws {
        let backup = file.appendingPathExtension("before-maccontrol")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
    }

    func moveToApplications() {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(paths.bundle.lastPathComponent)
        let staging = URL(fileURLWithPath: "/Applications").appendingPathComponent(".MacControl-\(UUID().uuidString).app")
        do {
            try fm.copyItem(at: paths.bundle, to: staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
            NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            try? fm.removeItem(at: staging)
            location = .failed("Could not copy MacControl to Applications: \(error.localizedDescription). Drag it there in Finder instead.")
        }
    }

    func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = workspace.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { workspacePath = url.path }
    }
}
