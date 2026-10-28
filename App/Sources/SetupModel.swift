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
    // Clients that are turned off but still have this app's servers.
    @Published var stillConnected: Set<Client> = []
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
        if busy || steps.contains(where: \.isWorking) { return Summary(level: .working, text: String(localized: "Setting up…")) }
        if !hasChecked { return Summary(level: .working, text: String(localized: "Checking this Mac…")) }
        // Set Up cannot fix a translocated copy; only moving the app can.
        if isTranslocated {
            return Summary(level: .needsAction, text: String(localized: "Quit MacControl, then open it from Applications."))
        }
        if steps.contains(where: \.isFailed) { return Summary(level: .failed, text: String(localized: "Something needs attention below.")) }
        if !staleClients.isEmpty {
            let count = staleClients.count
            return Summary(level: .needsAction, text: count == 1
                ? String(localized: "Settings changed. Apply them to 1 client.")
                : String(localized: "Settings changed. Apply them to \(count) clients."))
        }
        let remaining = steps.filter { !$0.isDone }.count
        if remaining > 0 {
            return Summary(level: .needsAction, text: remaining == 1
                ? String(localized: "1 step left. Click Set Up.")
                : String(localized: "\(remaining) steps left. Click Set Up."))
        }
        if enabledClients.isEmpty {
            return Summary(level: .needsAction, text: String(localized: "Install or turn on Claude Desktop, Claude Code, or Codex."))
        }
        let count = enabledClients.count
        let text: String
        switch (count == 1, enableExec) {
        case (true, true): text = String(localized: "Ready: 1 client connected, sandbox ready.")
        case (true, false): text = String(localized: "Ready: 1 client connected.")
        case (false, true): text = String(localized: "Ready: \(count) clients connected, sandbox ready.")
        case (false, false): text = String(localized: "Ready: \(count) clients connected.")
        }
        return Summary(level: .ready, text: text)
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            note(String(localized: "Could not change Open at Login: \(error.localizedDescription)"))
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

    static var setupLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacControl/setup.log")
    }
    static var auditLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/mac-exec/audit.log")
    }

    private func note(_ line: String) {
        log.append(line)
        let file = Self.setupLog
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamped = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: stamped)
        } else {
            try? stamped.write(to: file)
        }
    }

    // MARK: Help, logs, and the sandbox VM

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: Permissions of MacControlHelper

    struct HelperPermissions: Equatable {
        let accessibility: Bool
        let screenRecording: Bool
        var complete: Bool { accessibility && screenRecording }
    }

    // Desktop clients run mac-control on its own behalf, so macOS asks for the permissions in the name of
    // MacControlHelper. Command-line clients get them from the terminal app instead.
    @Published var helperPermissions: HelperPermissions?
    var needsHelperPermissions: Bool { enabledClients.contains(.claudeDesktop) || enabledClients.contains(.codex) }
    var helperPermissionsMissing: Bool { needsHelperPermissions && helperPermissions?.complete == false }

    var accessibilityPaneName: String {
        PrivacyPane.accessibilityRenamed(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            ? String(localized: "Device Control and Data Access") : String(localized: "Accessibility")
    }

    // The helper is started through Launch Services, so macOS checks the helper itself rather than MacControl.
    private func runHelper(_ arguments: [String], timeout: TimeInterval) async -> Bool {
        guard FileManager.default.fileExists(atPath: paths.controlServer.path),
              let result = try? await Installer.run("/usr/bin/open", ["-W", "-n", "-g", paths.controlHelperApp.path, "--args"] + arguments,
                                                    timeout: timeout) else { return false }
        return result.exitCode == 0
    }

    func checkHelperPermissions() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maccontrol-permissions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard await runHelper(["--check-permissions", file.path], timeout: 30) else { helperPermissions = nil; return }
        // `open -W` can return before a helper this quick has written its answer, so wait briefly for the file.
        for _ in 0..<25 where !FileManager.default.fileExists(atPath: file.path) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            helperPermissions = nil
            return
        }
        helperPermissions = HelperPermissions(accessibility: info["accessibility"] == true,
                                              screenRecording: info["screen_recording"] == true)
    }

    // macOS does not let an app turn these on; this shows its prompts and puts MacControlHelper in both
    // lists, so only the switches are left for the user.
    func requestHelperPermissions() async {
        defaults.set(true, forKey: "askedForHelperPermissions")
        note(String(localized: "Asking macOS for permissions for MacControlHelper…"))
        _ = await runHelper(["--request-permissions"], timeout: 60)
        await checkHelperPermissions()
    }

    // A newer release on GitHub, if any. Only the public release list is read; nothing is sent about this Mac.
    @Published var availableUpdate: (version: String, page: URL)?
    static let releasesAPI = URL(string: "https://api.github.com/repos/rudinyu/mac-control-mcp/releases/latest")!

    // Only the network call is throttled; the last release seen is kept, so the banner survives a relaunch
    // and disappears once this copy is up to date.
    func checkForUpdate(force: Bool = false) async {
        let last = defaults.double(forKey: "lastUpdateCheck")
        if force || Date().timeIntervalSince1970 - last > 24 * 3600 {
            var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = release["tag_name"] as? String,
               let page = release["html_url"] as? String {
                defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                defaults.set(tag, forKey: "latestReleaseTag")
                defaults.set(page, forKey: "latestReleasePage")
            }
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let tag = defaults.string(forKey: "latestReleaseTag"),
              let page = defaults.string(forKey: "latestReleasePage").flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com",
              AppVersion.isNewer(tag, than: current) else { availableUpdate = nil; return }
        availableUpdate = (tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page)
    }

    @Published var vmDetail: String?
    @Published var vmRunning = false

    // Start and Stop work for the runtimes MacControl installed itself: its Colima VM and Apple container.
    var canControlVM: Bool {
        switch runtimeChoice {
        case .managedColima: return Installer.managedColimaInstalled
        case .appleContainer: return Installer.appleContainerInstalled
        default: return false
        }
    }

    func refreshVM() async {
        if runtimeChoice == .appleContainer {
            guard canControlVM else { vmDetail = nil; vmRunning = false; return }
            // A status command that could not run says nothing about the service, so show nothing.
            guard let status = try? await Installer.run(paths.appleContainer.path, ["system", "status"], timeout: 30) else {
                vmDetail = nil; vmRunning = false; return
            }
            vmRunning = status.exitCode == 0
            vmDetail = vmRunning
                ? String(localized: "Apple container is running.")
                : String(localized: "Apple container is stopped. It starts by itself when an agent needs it.")
            return
        }
        guard canControlVM,
              let result = try? await Installer.run(paths.colima.path, ["list", "--profile", Installer.colimaProfile, "--json"],
                                                    environment: Installer.managedEnvironment, timeout: 30),
              let line = result.stdout.split(separator: "\n").first,
              let info = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            vmDetail = nil
            vmRunning = false
            return
        }
        vmRunning = (info["status"] as? String) == "Running"
        let cpus = info["cpus"] as? Int ?? 0
        let gigabytes = Int(((info["memory"] as? NSNumber)?.doubleValue ?? 0) / 1_073_741_824)
        vmDetail = vmRunning
            ? String(localized: "Linux VM running: \(cpus) CPUs, \(gigabytes) GB memory")
            : String(localized: "Linux VM stopped. It starts by itself when an agent needs it.")
    }

    func stopVM() async {
        guard canControlVM, !busy else { return }
        busy = true
        defer { busy = false }
        if runtimeChoice == .appleContainer {
            note(String(localized: "Stopping Apple container…"))
            _ = try? await Installer.run(paths.appleContainer.path, ["system", "stop"], timeout: 180)
        } else {
            note(String(localized: "Stopping the Linux VM…"))
            _ = try? await Installer.run(paths.colima.path, ["stop", "--profile", Installer.colimaProfile],
                                         environment: Installer.managedEnvironment, timeout: 180)
        }
        await refreshVM()
    }

    func startVM() async {
        guard canControlVM, !busy else { return }
        busy = true
        defer { busy = false }
        await setUpRuntime()
        await refreshVM()
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }

    func openLog(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) } else { reveal(file) }
    }

    func openWeb(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    // Removes everything MacControl added to this Mac, except the workspace and the logs, which may hold
    // the user's own work. Each step is checked; on any failure nothing is reported as removed and the
    // app stays open so the user can retry. On success the app is shown in Finder and quits, so nothing
    // it runs can write its settings back.
    func removeEverything() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // Checks that could stop the removal run before anything is changed.
        // The workspace can never be inside the support folder (mountRejection refuses ~/Library), but check
        // anyway, since the user's files must survive.
        if isSame(resolvedPath(workspace), orInside: resolvedPath(paths.support)) {
            note(String(localized: "Nothing was removed: the workspace is inside MacControl's support folder. Choose another workspace first."))
            return
        }
        note(String(localized: "Removing MacControl from this Mac…"))
        var failures: [String] = []
        for client in detectedClients {
            await disconnect(client)
            if clients[client]?.isFailed == true { failures.append(client.rawValue) }
        }
        // In the user's own Docker or in Apple container, only the sandbox image is MacControl's; the runtime
        // stays. An image that cannot be checked because the runtime is not running is left, and noted.
        if let choice = runtimeChoice, choice != .managedColima, choice != .appleContainer || Installer.appleContainerInstalled {
            let runtime = Installer.runtime(for: choice)
            let ready = (try? await Installer.run(runtime.program, runtime.readyArguments(), environment: runtime.environment, timeout: 30))?.exitCode == 0
            if !ready {
                note(String(localized: "\(choice.label) is not running, so the sandbox image was left in it."))
            } else if await Installer.imagePresent(runtime) {
                _ = try? await Installer.run(runtime.program, runtime.removeImageArguments(Installer.image), environment: runtime.environment, timeout: 120)
                if await Installer.imagePresent(runtime) { failures.append(String(localized: "the sandbox image")) }
            }
        }
        // A VM that is already gone counts as removed, so a retry after a partial removal can finish. It is
        // only gone when neither Colima nor the disk still shows it, and the tools that can delete it are
        // kept until then.
        if await Installer.colimaProfileExists() {
            let deleted = Installer.managedColimaInstalled
                ? try? await Installer.run(paths.colima.path, ["delete", "--profile", Installer.colimaProfile, "--force"],
                                           environment: Installer.managedEnvironment, timeout: 300)
                : nil
            let stillThere = await Installer.colimaProfileExists()
            if deleted?.exitCode != 0 || stillThere {
                failures.append(String(localized: "the Linux VM"))
            }
        }
        // Permissions given to MacControlHelper go too. Entries the user added by hand for an older copy
        // may remain; System Settings can remove those.
        for service in ["Accessibility", "ScreenCapture"] {
            _ = try? await Installer.run("/usr/bin/tccutil", ["reset", service, PrivacyPane.helperBundleID], timeout: 30)
        }
        if failures.isEmpty, FileManager.default.fileExists(atPath: paths.support.path) {
            do { try FileManager.default.removeItem(at: paths.support) } catch { failures.append(String(localized: "the downloaded tools")) }
        }
        guard failures.isEmpty else {
            let list = ListFormatter.localizedString(byJoining: failures)
            note(String(localized: "Could not remove \(list). The other steps may already be done; fix the problem and click Remove again."))
            return
        }
        if openAtLogin { setOpenAtLogin(false) }
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        note(String(localized: "Removed. Your workspace and logs were kept. Move MacControl from Applications to the Trash to finish."))
        NSWorkspace.shared.activateFileViewerSelecting([paths.bundle])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        NSApp.terminate(nil)
    }

    // MARK: Checks

    func refresh() async {
        guard !busy else { return }
        checkLocation()
        await checkRuntime()
        await detectClients()
        await checkHelperPermissions()
        hasChecked = true
        await checkForUpdate()
    }

    // macOS runs a quarantined app that was not moved into place by Finder from a random read-only copy.
    var isTranslocated: Bool { paths.bundle.path.contains("/AppTranslocation/") }

    func checkLocation() {
        if isTranslocated {
            location = .needsAction(String(localized: "macOS is running a protected copy of MacControl. Quit it, drag MacControl into Applications in Finder, then open it from there."))
            return
        }
        location = paths.bundle.path.hasPrefix("/Applications/")
            ? .done(String(localized: "Installed in \(paths.bundle.deletingLastPathComponent().path)"))
            : .needsAction(String(localized: "Move MacControl to the Applications folder, so clients keep finding it."))
    }

    private func requireUsableWorkspace() throws {
        if let problem = workspaceProblem { throw InstallFailure(description: String(localized: "The workspace cannot be used: \(problem)")) }
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
        var leftover: Set<Client> = []
        func record(_ client: Client, connected: Bool, hasEntry: Bool) {
            // Until MacControl runs from Applications, its helper paths differ from what clients use, so a
            // comparison would wrongly call every client outdated.
            if !location.isDone, isEnabled(client) {
                // Whether the entry works cannot be told from here, so only say that one exists. The Location
                // step keeps the summary from reporting Ready meanwhile.
                found[client] = .notNeeded(hasEntry ? String(localized: "Previously set up. Checked once MacControl runs from Applications.")
                                                    : String(localized: "Connects once MacControl runs from Applications."))
                return
            }
            if !isEnabled(client) {
                if hasEntry { leftover.insert(client) }
                found[client] = .notNeeded(hasEntry ? String(localized: "Turned off, but still connected") : String(localized: "Turned off"))
            } else if connected {
                found[client] = .done(String(localized: "Connected"))
            } else if hasEntry {
                found[client] = .needsAction(String(localized: "Connected with older settings"))
                stale.insert(client)
            } else {
                found[client] = .needsAction(String(localized: "Not connected yet"))
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
        stillConnected = leftover
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
            runtime = .notNeeded(String(localized: "Sandboxed commands are turned off"))
            image = .notNeeded(String(localized: "Not needed"))
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
        var reachable = false
        switch choice {
        case .appleContainer:
            reachable = Installer.appleContainerInstalled
            runtime = reachable
                ? .done(String(localized: "Ready. Each command runs in its own small VM (Apple container)."))
                : .needsAction(String(localized: "Apple's container tool needs to be installed. MacControl downloads Apple's signed installer."))
        case .existingDocker(let docker):
            reachable = true
            runtime = .done(String(localized: "Ready. Uses the Docker already running on this Mac (\(docker))."))
        case .managedColima:
            if !Installer.managedColimaInstalled {
                runtime = .needsAction(String(localized: "No running Docker was found, so MacControl will download a small Linux VM (about 80 MB). If you use Docker Desktop or OrbStack, start it and reopen this window instead."))
            } else {
                // A stopped VM is fine: mac-exec starts it when an agent needs it.
                reachable = await Installer.colimaRunning()
                runtime = .done(reachable
                    ? String(localized: "Ready. A Linux VM managed by MacControl runs your commands.")
                    : String(localized: "Ready. The Linux VM is stopped and starts by itself when needed."))
            }
        }
        await refreshVM()
        let imageReady = String(localized: "Ready. Linux tools such as Python, Node.js, and git are installed.")
        if reachable {
            let present = await Installer.imagePresent(Installer.runtime(for: choice))
            defaults.set(present, forKey: "imageReady")
            image = present ? .done(imageReady) : .needsAction(String(localized: "Needs to be built once. This takes a few minutes."))
        } else if runtime.isDone, defaults.bool(forKey: "imageReady") {
            // The image cannot be checked while the VM is stopped; use the last check.
            image = .done(imageReady)
        } else {
            image = .notNeeded(String(localized: "Waits for the sandbox"))
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
        // Asked once by Set Up; the Permissions section can ask again.
        if location.isDone, helperPermissionsMissing, !defaults.bool(forKey: "askedForHelperPermissions") {
            await requestHelperPermissions()
        }
        busy = false
        await refresh()
        if summary.level == .ready { onReady?() }
    }

    func setUpRuntime() async {
        guard let choice = runtimeChoice else { return }
        if let problem = workspaceProblem {
            runtime = .failed(String(localized: "The workspace cannot be used: \(problem)"))
            return
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let progress: @Sendable (String) -> Void = { line in Task { @MainActor in self.note(line); self.runtime = .working(line) } }
        do {
            switch choice {
            case .appleContainer:
                if !Installer.appleContainerInstalled {
                    try await Installer.openAppleContainerInstaller(progress: progress)
                    progress(String(localized: "Waiting for the Apple container installer to finish…"))
                    guard await waitForAppleContainerInstall() else {
                        runtime = .needsAction(String(localized: "Finish the Apple container installer, then click Set Up again."))
                        return
                    }
                    note(String(localized: "Apple container is installed. Continuing setup."))
                }
                progress(String(localized: "Starting Apple container…"))
                try await Installer.startAppleContainer()
            case .existingDocker:
                break
            case .managedColima:
                if !Installer.managedColimaInstalled { try await Installer.installManagedColima(cpu: cpu, progress: progress) }
                try await Installer.startColima(workspace: workspace, readOnly: [], cpu: cpu, progress: progress)
            }
            runtime = .done(String(localized: "\(choice.label) is ready"))
        } catch {
            runtime = .failed(String(describing: error))
            note(String(localized: "Error: \(String(describing: error))"))
        }
    }

    // Continues setup by itself once the installer has put the container command in place. It stops waiting
    // when the installer quits without installing it, or after an hour, so Set Up is never stuck.
    private func waitForAppleContainerInstall() async -> Bool {
        let started = Date()
        var sawInstaller = false
        while Date().timeIntervalSince(started) < 3600, !Task.isCancelled {
            if Installer.appleContainerInstalled { return true }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.installer").isEmpty
            if running { sawInstaller = true }
            // Allow the installer some time to open before taking "not running" to mean it was closed.
            if !running, sawInstaller || Date().timeIntervalSince(started) > 30 {
                try? await Task.sleep(for: .seconds(3))
                return Installer.appleContainerInstalled
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return Installer.appleContainerInstalled
    }

    func setUpImage() async {
        guard let choice = runtimeChoice else { return }
        let runtime = Installer.runtime(for: choice)
        let progress: @Sendable (String) -> Void = { line in Task { @MainActor in self.note(line); self.image = .working(line) } }
        do {
            try requireUsableWorkspace()
            if !(await Installer.imagePresent(runtime)) { try await Installer.buildImage(runtime, progress: progress) }
            progress(String(localized: "Testing the sandbox…"))
            try await Installer.smokeTest(runtime, workspace: workspace)
            image = .done(String(localized: "Ready. The sandbox passed its test."))
            defaults.set(true, forKey: "imageReady")
            note(String(localized: "Sandbox test passed."))
        } catch {
            image = .failed(String(describing: error))
            note(String(localized: "Error: \(String(describing: error))"))
        }
    }

    func connect(_ client: Client) async {
        // Clients store the helper paths, so they must point into /Applications, not a copy that may move.
        guard location.isDone else {
            clients[client] = .needsAction(String(localized: "Move MacControl to Applications first, then connect."))
            return
        }
        clients[client] = .working(String(localized: "Connecting…"))
        do {
            if enableExec { try requireUsableWorkspace() }
            switch client {
            case .claudeDesktop:
                try connectClaudeDesktop()
            case .claudeCode, .codex:
                try await connectCLI(client)
            }
            note(String(localized: "Connected \(client.rawValue). \(client.reloadHint)"))
        } catch {
            clients[client] = .failed(String(describing: error))
            note(String(localized: "Error: \(String(describing: error))"))
            return
        }
        await detectClients()
    }

    func disconnect(_ client: Client) async {
        clients[client] = .working(String(localized: "Disconnecting…"))
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
                        throw ConfigFailure(description: String(localized: "\(client.rawValue) did not answer (\(list.stderr.suffix(200))), so nothing was removed. Try again."))
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
                            throw ConfigFailure(description: String(localized: "\(client.rawValue) still has \(serverName) after removing it: \(result.stderr.suffix(300))"))
                        }
                    }
                }
                defaults.removeObject(forKey: fingerprintKey(client))
            }
            note(String(localized: "Disconnected \(client.rawValue). \(client.reloadHint)"))
        } catch {
            clients[client] = .failed(String(describing: error))
            note(String(localized: "Error: \(String(describing: error))"))
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
            throw ConfigFailure(description: String(localized: "\(client.rawValue) was not found. Run the commands shown below in Terminal."))
        }
        for server in servers {
            let commands = client == .codex ? ClientConfig.codexCommands(server) : ClientConfig.claudeCodeCommands(server)
            _ = try? await Installer.runInLoginShell(program, commands[0]) // removing an entry that does not exist is fine
            let result = try await Installer.runInLoginShell(program, commands[1])
            guard result.exitCode == 0 else {
                throw ConfigFailure(description: String(localized: "\(client.rawValue) refused the server \(server.name): \(result.stderr.suffix(400))"))
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
            location = .failed(String(localized: "Could not copy MacControl to Applications: \(error.localizedDescription). Drag it there in Finder instead."))
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
