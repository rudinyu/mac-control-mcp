import AppKit
import SwiftUI

// MacControl lives in the menu bar. The Dock icon appears only while the setup window is open, and
// closing the window keeps the app running. Only one copy may run, so two never install at once.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var showWindow: (() -> Void)?
    private var refreshTimer: Timer?
    private var launchedAtLogin = false

    // Only a launch by Open at Login starts quietly in the menu bar; a launch by the user shows the window.
    // If macOS does not mark the login launch, the window simply shows at login too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Task { @MainActor in SetupModel.shared.note("Launched \(launchedAtLogin ? "at login" : "by the user").", show: false) }
    }

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
            let iconShown = MainActor.assumeIsolated { self.leaveDock() }
            // The first time, say where MacControl went.
            let key = iconShown ? "toldAboutMenuBar" : "toldAboutDock"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    if iconShown {
                        alert.messageText = String(localized: "MacControl keeps running in the menu bar")
                        alert.informativeText = String(localized: "Its icon is in the menu bar at the top right. If your menu bar is full and you cannot find it, open MacControl again from Applications or Spotlight.")
                    } else {
                        alert.messageText = String(localized: "MacControl keeps running in the Dock")
                        alert.informativeText = String(localized: "Your menu bar is full, so macOS is hiding MacControl's icon there. MacControl keeps its icon in the Dock instead; click it to open the window.")
                    }
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
            // Once everything is set up, a launch at login starts quietly in the menu bar.
            if self.launchedAtLogin, model.summary.level == .ready { self.hideSetupWindow() }
        }
    }

    // Opening the app again, for example from Finder, shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let showWindow {
            showWindow()
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("setup") == true }) {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func hideSetupWindow() {
        for window in NSApp.windows where window.identifier?.rawValue.contains("setup") == true { window.close() }
        leaveDock()
    }

    // Removes the Dock icon when the window closes, unless the menu bar icon is hidden, which macOS does when
    // the menu bar is full. Then the Dock icon stays, so MacControl can still be found. Returns whether the
    // menu bar icon is shown.
    @MainActor @discardableResult func leaveDock() -> Bool {
        let shown = menuBarIconShown()
        SetupModel.shared.note("Menu bar icon \(shown ? "shown" : "hidden"); Dock icon \(shown ? "removed" : "kept").", show: false)
        NSApp.setActivationPolicy(shown ? .accessory : .regular)
        return shown
    }

    // The status item lives in its own window. macOS moves it off every screen, or hides it, when there is no
    // room for it. If the window cannot be found, the icon counts as hidden, which only keeps the Dock icon.
    @MainActor private func menuBarIconShown() -> Bool {
        NSApp.windows.contains { window in
            String(describing: type(of: window)).contains("StatusBar") && window.isVisible
                && NSScreen.screens.contains { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }
        }
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

    }

    private func open() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "setup")
        NSApp.activate()
    }
}

// Lets the app delegate reopen the window, for example when the app is opened again from Finder. It wraps the
// menu bar icon, which exists for the whole run; an action taken from a closed window would do nothing.
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
            SetupView(model: model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent(model: model, delegate: delegate)
        } label: {
            WindowOpenerCapture(delegate: delegate) {
                Image(systemName: model.summary.level == .ready || model.summary.level == .working
                      ? "cursorarrow.rays" : "exclamationmark.triangle")
                    .accessibilityLabel("MacControl: \(model.summary.text)")
            }
        }
    }
}
