import SwiftUI

private struct StatusIcon: View {
    let state: StepState

    var body: some View {
        Group {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .notNeeded: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .working: ProgressView().controlSize(.small)
            case .needsAction: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(state.accessibilityLabel)
    }
}

private struct StepRow<Leading: View, Action: View>: View {
    let title: LocalizedStringKey
    let state: StepState
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let action: () -> Action

    private var detail: String {
        switch state {
        case .unknown: return String(localized: "Checking…")
        case .working(let text), .done(let text), .needsAction(let text), .failed(let text), .notNeeded(let text): return text
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading()
            StatusIcon(state: state).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(state.isFailed ? .red : .secondary)
                    .lineLimit(state.isFailed ? 3 : nil)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if state.isFailed {
                    // Errors can be long; keep the row short and let the user copy or read the whole text.
                    HStack(spacing: 8) {
                        Button("Copy Error") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detail, forType: .string)
                        }
                        Button("Show Log") { NSWorkspace.shared.open(SetupModel.setupLog) }
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
            action()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

extension StepRow where Leading == EmptyView {
    init(title: LocalizedStringKey, state: StepState, @ViewBuilder action: @escaping () -> Action) {
        self.init(title: title, state: state, leading: { EmptyView() }, action: action)
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).padding(.leading, 2).accessibilityAddTraits(.isHeader)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @State private var confirmHostExec = false
    @State private var clientToDisconnect: Client?
    @State private var confirmRemove = false
    @State private var showPermissions = true
    @State private var userToggledPermissions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.staleClients.isEmpty { applyBanner }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Setup")
                        GroupBox { steps.padding(6) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            userToggledPermissions = true
                            withAnimation { showPermissions.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showPermissions ? "chevron.down" : "chevron.right")
                                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                                SectionTitle(text: "Permissions")
                                if !showPermissions {
                                    Text(collapsedPermissionsHint)
                                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(showPermissions ? "Hides the permission steps" : "Shows the permission steps")
                        if showPermissions { GroupBox { permissions.padding(6) } }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Sandbox settings")
                        GroupBox { settings.padding(6) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Help")
                        GroupBox { help.padding(6) }
                    }
                    if !model.manualCommands.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "Run these commands in Terminal")
                            GroupBox {
                                Text(model.manualCommands.joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                    }
                    if !model.log.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "Activity")
                            GroupBox {
                                Text(model.log.suffix(40).joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 640, minHeight: 640)
        // Once everything works, the permission steps are no longer needed every time; the user can still open them.
        .onChange(of: model.summary.level) { _, level in
            if !userToggledPermissions { showPermissions = level != .ready || model.helperPermissionsMissing }
        }
        .onChange(of: model.helperPermissions) { _, _ in
            if !userToggledPermissions { showPermissions = model.summary.level != .ready || model.helperPermissionsMissing }
        }
        .onAppear {
            if !userToggledPermissions { showPermissions = model.summary.level != .ready || model.helperPermissionsMissing }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        // The client is handed to the buttons, so dismissing the alert cannot clear it before they run.
        .alert("Disconnect this client?", isPresented: Binding(
            get: { clientToDisconnect != nil }, set: { if !$0 { clientToDisconnect = nil } }
        ), presenting: clientToDisconnect) { client in
            Button("Disconnect \(client.rawValue)", role: .destructive) { Task { await model.setEnabled(client, false) } }
            Button("Cancel", role: .cancel) {}
        } message: { client in
            Text("This removes mac-control and mac-exec from \(client.rawValue). You can turn it on again at any time.")
        }
        .alert("Remove MacControl from this Mac?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.removeEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects every client, deletes the sandbox (MacControl's Linux VM, or the sandbox image in your own Docker or in Apple container) and the tools MacControl downloaded, and resets its settings and permissions. Your workspace, your logs, your own Docker, and Apple container stay. Afterwards, move MacControl to the Trash.")
        }
        .alert("Allow commands outside the sandbox?", isPresented: $confirmHostExec) {
            Button("Allow host_exec", role: .destructive) { model.allowHost = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("host_exec runs commands directly on this Mac with all of your permissions. It can read and change any of your files. Only allow it if you need macOS programs, and read every command in the approval prompt before allowing it.")
        }
    }

    // MARK: Header

    private var summaryIcon: (String, Color) {
        switch model.summary.level {
        case .ready: return ("checkmark.seal.fill", .green)
        case .working: return ("hourglass", .secondary)
        case .needsAction: return ("exclamationmark.circle.fill", .orange)
        case .failed: return ("xmark.octagon.fill", .red)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("MacControl").font(.title2.bold())
                HStack(spacing: 6) {
                    Image(systemName: summaryIcon.0).foregroundStyle(summaryIcon.1).accessibilityHidden(true)
                    Text(model.summary.text).font(.callout)
                }
                .accessibilityElement(children: .combine)
                if let update = model.availableUpdate {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue).accessibilityHidden(true)
                        Text("Version \(update.version) is available.").font(.callout)
                        Button("Download") { NSWorkspace.shared.open(update.page) }.controlSize(.small)
                    }
                }
            }
            Spacer()
            if model.summary.level == .ready {
                Button("Check Again") { Task { await model.refresh() } }
                    .controlSize(.large)
                    .disabled(model.busy)
            } else {
                Button {
                    Task { await model.setUpEverything() }
                } label: {
                    Text(model.busy ? "Setting up…" : "Set Up").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || !model.hasChecked || model.isTranslocated)
            }
        }
        .padding(16)
    }

    private var applyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Settings changed. \(ListFormatter.localizedString(byJoining: model.staleClients.map(\.rawValue).sorted())) still use the old settings.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Apply") { Task { await model.applySettings() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !model.location.isDone)
                .help(model.location.isDone ? "" : "Move MacControl to Applications first.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Sections

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            StepRow(title: "Location", state: model.location) {
                if model.isTranslocated {
                    Button("Quit MacControl") { NSApp.terminate(nil) }
                } else if case .needsAction = model.location {
                    Button("Move to Applications") { model.moveToApplications() }
                }
            }
            Divider()
            if model.detectedClients.isEmpty && model.hasChecked {
                StepRow(title: "Clients", state: .needsAction("Install Claude Desktop, Claude Code, or Codex, then reopen this window.")) { EmptyView() }
            }
            ForEach(model.detectedClients) { client in
                StepRow(title: LocalizedStringKey(client.rawValue), state: model.clients[client]!, leading: {
                    Toggle(String(localized: "Connect \(client.rawValue)"), isOn: Binding(
                        get: { model.isEnabled(client) },
                        // Turning a client off removes its servers, so ask first; a misclick should not disconnect it.
                        set: { on in if on { Task { await model.setEnabled(client, true) } } else { clientToDisconnect = client } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.busy)
                }) {
                    if model.isEnabled(client), case .needsAction = model.clients[client]!, !model.staleClients.contains(client) {
                        Button("Connect") { Task { await model.connect(client) } }.disabled(model.busy)
                    } else if !model.isEnabled(client), model.stillConnected.contains(client) {
                        Button("Disconnect") { Task { await model.disconnect(client) } }.disabled(model.busy)
                    } else if case .failed = model.clients[client]! {
                        Button("Retry") { Task { await model.connect(client) } }.disabled(model.busy)
                    }
                }
            }
            Divider()
            StepRow(title: "Sandbox", state: model.runtime) {
                if case .needsAction = model.runtime {
                    Button("Install") { Task { await model.setUpRuntime(); await model.checkRuntime() } }.disabled(model.busy)
                } else if model.canControlVM {
                    let apple = model.runtimeChoice == .appleContainer
                    if model.vmRunning {
                        Button(apple ? LocalizedStringKey("Stop") : "Stop VM") { Task { await model.stopVM() } }.disabled(model.busy)
                            .help("Frees its memory. It starts again by itself when an agent needs it.")
                    } else {
                        Button(apple ? LocalizedStringKey("Start") : "Start VM") { Task { await model.startVM() } }.disabled(model.busy)
                    }
                }
            }
            if model.canControlVM, model.enableExec {
                VStack(alignment: .leading, spacing: 2) {
                    if let detail = model.vmDetail { Text(detail) }
                    if model.runtimeChoice == .managedColima {
                        Text("macOS may say that “colima” can run in the background. That is this VM.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
            }
            if let note = model.appleSiliconNote {
                Text(note).font(.caption).foregroundStyle(.orange).padding(.leading, 28)
            }
            StepRow(title: "Sandbox environment", state: model.image) {
                if case .needsAction = model.image {
                    Button("Build") { Task { await model.setUpImage() } }.disabled(model.busy)
                } else if case .failed = model.image {
                    Button("Retry") { Task { await model.setUpImage() } }.disabled(model.busy)
                }
            }
        }
    }

    private var collapsedPermissionsHint: String {
        guard model.needsHelperPermissions, let state = model.helperPermissions else {
            // Only terminal clients are on, and MacControl cannot check a terminal app's permissions.
            return String(localized: "Set in System Settings. Confirm with mac_status.")
        }
        return state.complete ? String(localized: "MacControlHelper is allowed.")
                              : String(localized: "MacControlHelper still needs permissions.")
    }

    private var paneButtons: some View {
        HStack {
            Button(model.accessibilityPaneName) { model.openPrivacyPane("Privacy_Accessibility") }
            Button("Screen Recording") { model.openPrivacyPane("Privacy_ScreenCapture") }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS asks you to turn these on yourself; no app can turn them on for you. Turn on \(model.accessibilityPaneName) and Screen & System Audio Recording for:")
                .fixedSize(horizontal: false, vertical: true)
            if model.needsHelperPermissions {
                let granted = model.helperPermissions?.complete == true
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "hand.raised.fill")
                        .foregroundStyle(granted ? .green : .blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacControlHelper").font(.headline)
                        Text("Used when Claude Desktop or the Codex app runs mac-control.").font(.callout).foregroundStyle(.secondary)
                        if granted, model.helperGrantedThisRun {
                            Text("Quit and reopen Claude Desktop or the Codex app so it uses these permissions.")
                                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if let state = model.helperPermissions {
                            HStack(spacing: 12) {
                                Label(model.accessibilityPaneName, systemImage: state.accessibility ? "checkmark" : "xmark")
                                Label("Screen Recording", systemImage: state.screenRecording ? "checkmark" : "xmark")
                            }
                            .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !granted {
                        Button("Ask macOS") { Task { await model.requestHelperPermissions(openSettings: true) } }.disabled(model.busy)
                            .help("Shows the macOS prompts and adds MacControlHelper to both lists, or opens System Settings if macOS asked before.")
                    }
                    paneButtons
                }
                .accessibilityElement(children: .contain)
            }
            let terminalClients = model.enabledClients.filter { $0 != .claudeDesktop }
            if !terminalClients.isEmpty {
                // MacControl cannot read a terminal app's permissions, so this row is information, not a to-do.
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ListFormatter.localizedString(byJoining: terminalClients.map(\.rawValue))) in a terminal").font(.headline)
                        Text("Uses your terminal app's permissions (Terminal, iTerm2, …), which MacControl cannot check. After turning them on, quit and reopen the terminal app; to confirm, ask the agent to call mac_status.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    paneButtons
                }
                .accessibilityElement(children: .contain)
            }
            if model.enabledClients.isEmpty {
                Text("No client is turned on.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Version \(model.version)").foregroundStyle(.secondary)
                Spacer()
                Button("Release Notes") { model.openWeb("https://github.com/rudinyu/mac-control-mcp/releases") }
                Button("Guide") { model.openWeb("https://github.com/rudinyu/mac-control-mcp/blob/main/docs/APP.md") }
            }
            HStack {
                Button("Open Workspace") { model.reveal(model.workspace) }.disabled(!model.enableExec)
                Button("Command Log") { model.openLog(SetupModel.auditLog) }
                    .help("Every sandbox and host_exec command, with its result.")
                Button("Setup Log") { model.openLog(SetupModel.setupLog) }
                Spacer()
                Menu {
                    Button("Remove from This Mac…", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.busy)
                .help("More")
                .accessibilityLabel("More")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.enableExec) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run commands in a sandbox (mac-exec)")
                    Text("Gives agents a Linux sandbox for running commands and working with files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Workspace:")
                Text(model.workspacePath).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { model.chooseWorkspace() }
            }
            .disabled(!model.enableExec)
            if let problem = model.workspaceProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Toggle(isOn: Binding(
                    get: { model.allowHost },
                    set: { on in if on { confirmHostExec = true } else { model.allowHost = false } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow host_exec")
                        Text("Runs commands directly on this Mac, outside the sandbox, with all of your permissions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!model.enableExec)
            Text("After a change, an Apply button appears at the top to update the clients.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
