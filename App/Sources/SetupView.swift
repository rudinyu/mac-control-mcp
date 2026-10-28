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
    let title: String
    let state: StepState
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let action: () -> Action

    private var detail: String {
        switch state {
        case .unknown: return "Checking…"
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
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

extension StepRow where Leading == EmptyView {
    init(title: String, state: StepState, @ViewBuilder action: @escaping () -> Action) {
        self.init(title: title, state: state, leading: { EmptyView() }, action: action)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).padding(.leading, 2).accessibilityAddTraits(.isHeader)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @State private var confirmHostExec = false
    @State private var clientToDisconnect: Client?

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
                        SectionTitle(text: "Permissions")
                        GroupBox { permissions.padding(6) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Sandbox settings")
                        GroupBox { settings.padding(6) }
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
                .disabled(model.busy || !model.hasChecked)
            }
        }
        .padding(16)
    }

    private var applyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Settings changed. \(model.staleClients.map(\.rawValue).sorted().joined(separator: ", ")) still use the old settings.")
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
                if case .needsAction = model.location { Button("Move to Applications") { model.moveToApplications() } }
            }
            Divider()
            if model.detectedClients.isEmpty && model.hasChecked {
                StepRow(title: "Clients", state: .needsAction("Install Claude Desktop, Claude Code, or Codex, then reopen this window.")) { EmptyView() }
            }
            ForEach(model.detectedClients) { client in
                StepRow(title: client.rawValue, state: model.clients[client]!, leading: {
                    Toggle("Connect \(client.rawValue)", isOn: Binding(
                        get: { model.isEnabled(client) },
                        // Turning a client off removes its servers, so ask first; a misclick should not disconnect it.
                        set: { on in if on { Task { await model.setEnabled(client, true) } } else { clientToDisconnect = client } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.busy)
                }) {
                    if model.isEnabled(client), case .needsAction = model.clients[client]!, !model.staleClients.contains(client) {
                        Button("Connect") { Task { await model.connect(client) } }.disabled(model.busy)
                    } else if !model.isEnabled(client), case .notNeeded(let text) = model.clients[client]!, text.contains("still connected") {
                        Button("Disconnect") { Task { await model.disconnect(client) } }.disabled(model.busy)
                    } else if case .failed = model.clients[client]! {
                        Button("Retry") { Task { await model.connect(client) } }.disabled(model.busy)
                    }
                }
            }
            Divider()
            StepRow(title: "Sandbox runtime" + (model.runtimeChoice.map { ": " + $0.label } ?? ""), state: model.runtime) {
                if case .needsAction = model.runtime {
                    Button("Install") { Task { await model.setUpRuntime(); await model.checkRuntime() } }.disabled(model.busy)
                }
            }
            if let note = model.appleSiliconNote {
                Text(note).font(.caption).foregroundStyle(.orange).padding(.leading, 28)
            }
            StepRow(title: "Sandbox image", state: model.image) {
                if case .needsAction = model.image {
                    Button("Build") { Task { await model.setUpImage() } }.disabled(model.busy)
                } else if case .failed = model.image {
                    Button("Retry") { Task { await model.setUpImage() } }.disabled(model.busy)
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS gives these permissions to the app that runs each client, and does not let MacControl check them. Turn on Accessibility and Screen & System Audio Recording for:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.enabledClients) { client in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.rawValue).font(.headline)
                        Text("Turn on: \(client.permissionHolder)").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Accessibility") { model.openPrivacyPane("Privacy_Accessibility") }
                    Button("Screen Recording") { model.openPrivacyPane("Privacy_ScreenCapture") }
                }
                .accessibilityElement(children: .contain)
            }
            if model.enabledClients.isEmpty {
                Text("No client is turned on.").foregroundStyle(.secondary)
            }
            Text("After turning them on, quit and reopen that app. To confirm, ask the agent to call mac_status: it reports \"accessibility\": true and \"screen_recording\": true.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Run commands in a sandbox (mac-exec)", isOn: $model.enableExec)
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
            Text("After changing these settings, click Apply in the banner above to update the clients.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
