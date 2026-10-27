import SwiftUI

private struct StatusIcon: View {
    let state: StepState

    var body: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notNeeded: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .needsAction: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

private struct StepRow<Action: View>: View {
    let title: String
    let state: StepState
    @ViewBuilder let action: () -> Action

    private var detail: String {
        switch state {
        case .unknown: return "Checking…"
        case .working(let text), .done(let text), .needsAction(let text), .failed(let text), .notNeeded(let text): return text
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusIcon(state: state).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
        .padding(.vertical, 4)
    }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Setup") { steps.padding(6) }
                    GroupBox("Permissions") { permissions.padding(6) }
                    GroupBox("Sandbox settings") { settings.padding(6) }
                    if !model.manualCommands.isEmpty {
                        GroupBox("Run these commands in Terminal") {
                            Text(model.manualCommands.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    if !model.log.isEmpty {
                        GroupBox("Activity") {
                            Text(model.log.suffix(40).joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, minHeight: 640)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MacControl").font(.title2.bold())
                Text("Lets Claude and Codex see and control this Mac, and run commands in a sandbox.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.setUpEverything() }
            } label: {
                Text(model.busy ? "Setting up…" : "Set Up").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy)
        }
        .padding(16)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            StepRow(title: "Location", state: model.location) {
                if case .needsAction = model.location { Button("Move to Applications") { model.moveToApplications() } }
            }
            Divider()
            if model.clients.isEmpty {
                StepRow(title: "Clients", state: .needsAction("Install Claude Desktop, Claude Code, or Codex, then reopen this window.")) { EmptyView() }
            }
            ForEach(Client.allCases.filter { model.clients[$0] != nil }) { client in
                StepRow(title: client.rawValue, state: model.clients[client]!) {
                    if !(model.clients[client]?.isDone ?? false) {
                        Button("Connect") { Task { await model.connect(client) } }.disabled(model.busy)
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
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS asks for permission per app. Turn on Accessibility and Screen & System Audio Recording for:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Client.allCases.filter { model.clients[$0] != nil }) { client in
                Text("• \(client.rawValue): \(client.permissionHolder)").fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Accessibility") { model.openPrivacyPane("Privacy_Accessibility") }
                Button("Open Screen Recording") { model.openPrivacyPane("Privacy_ScreenCapture") }
            }
            Text("Then quit and reopen that app, and ask the agent to call mac_status to confirm.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Toggle("Allow host_exec (run commands directly on this Mac, outside the sandbox)", isOn: $model.allowHost)
                .disabled(!model.enableExec)
            Text("Changing these settings marks clients as not connected; click Connect again to update them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
