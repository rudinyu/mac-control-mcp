import AppKit
import SwiftUI

// MacControl lives in the menu bar. The Dock icon appears only while the setup window is open, and
// closing the window keeps the app running. Only one copy may run, so two never install at once.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var showWindow: (() -> Void)?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // For checking both appearances without changing the system:
        // `defaults write tw.com.eaman.MacControl appearanceOverride light` (or dark).
        switch UserDefaults.standard.string(forKey: "appearanceOverride") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if let running = others.first {
            running.activate()
            NSApp.terminate(nil)
            return
        }
        let center = NotificationCenter.default
        // Only the setup window brings back the Dock icon; the menu bar menu and alerts are windows too.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue.contains("setup") == true else { return }
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            // The menu bar menu is a window too; only the setup window controls the Dock icon.
            guard (notification.object as? NSWindow)?.identifier?.rawValue.contains("setup") == true else { return }
            NSApp.setActivationPolicy(.accessory)
            // The first time, say where MacControl went; a full menu bar can hide its icon.
            if !UserDefaults.standard.bool(forKey: "toldAboutMenuBar") {
                UserDefaults.standard.set(true, forKey: "toldAboutMenuBar")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "MacControl keeps running in the menu bar")
                    alert.informativeText = String(localized: "Its icon is in the menu bar at the top right. If your menu bar is full and you cannot find it, open MacControl again from Applications or Spotlight.")
                    alert.runModal()
                }
            }
        }
        // Keep the menu bar status current while the window is closed.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in await SetupModel.shared.refresh() }
        }
        Task { @MainActor in
            let model = SetupModel.shared
            model.onReady = { [weak self] in self?.hideSetupWindow() }
            await model.refresh()
            // Once everything is set up, start quietly in the menu bar.
            if model.summary.level == .ready { self.hideSetupWindow() }
        }
    }

    // Opening the app again, for example from Finder, shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func hideSetupWindow() {
        for window in NSApp.windows where window.identifier?.rawValue.contains("setup") == true { window.close() }
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuContent: View {
    @ObservedObject var model: SetupModel
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        Text(model.summary.text)
        Divider()
        Button("Open MacControl…") { open() }
            .keyboardShortcut("o")
        Button("Check Now") { Task { await model.refresh(); await model.checkForUpdate(force: true) } }
            .disabled(model.busy)
        if let update = model.availableUpdate {
            Button("Download Version \(update.version)…") { NSWorkspace.shared.open(update.page) }
        }
        Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
        Divider()
        Button("Quit MacControl") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { delegate.showWindow = { open() } }
    }

    private func open() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "setup")
        NSApp.activate()
    }
}

// Lets the app delegate reopen the window, for example when the app is opened again from Finder.
private struct WindowOpenerCapture<Content: View>: View {
    let delegate: AppDelegate
    @ViewBuilder let content: () -> Content
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content().onAppear {
            delegate.showWindow = {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "setup")
                NSApp.activate()
            }
        }
    }
}

@main
struct MacControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = SetupModel.shared

    var body: some Scene {
        Window("MacControl", id: "setup") {
            WindowOpenerCapture(delegate: delegate) { SetupView(model: model) }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent(model: model, delegate: delegate)
        } label: {
            Image(systemName: model.summary.level == .ready || model.summary.level == .working
                  ? "cursorarrow.rays" : "exclamationmark.triangle")
                .accessibilityLabel("MacControl: \(model.summary.text)")
        }
    }
}
