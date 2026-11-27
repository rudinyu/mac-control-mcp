import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import SwiftUI

@MainActor
final class CurtainCoordinator: ObservableObject {
    static let shared = CurtainCoordinator()

    @Published private(set) var phase: CurtainPhase
    private var panels: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var lockTimer: Timer?
    private var transitionTimer: Timer?
    private var transitionTarget: CurtainPhase?
    private var transitionDeadline: Date?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let inputLock = SharedLock("input")
    private let recordingLock = SharedLock("recording")
    private var hiddenForNativeLock = false
    private var lastHeartbeat = Date.distantPast
    // Lock when used at the Mac: input from the keyboard or mouse after armedAt locks the Mac, and the unlock
    // that follows restores the desktop, since the person who unlocked it is the user.
    @Published private(set) var lockOnLocalUse = UserDefaults.standard.bool(forKey: lockOnLocalUseKey)
    private var armedAt = Date.distantFuture
    private var lastHotKeyAt = Date.distantPast
    private var lockRequestedAt: Date?
    private var lockedForLocalUse = false

    var isActive: Bool { phase == .active }

    func setLockOnLocalUse(_ on: Bool) {
        if on && lockScreenFunction == nil {
            SetupModel.shared.note("Screen Curtain: this macOS does not offer the lock MacControl uses, so Lock the Mac When Someone Uses It stays off.")
            lockOnLocalUse = false
            return
        }
        lockOnLocalUse = on
        UserDefaults.standard.set(on, forKey: lockOnLocalUseKey)
        armedAt = Date().addingTimeInterval(localUseGraceSeconds)
        SetupModel.shared.note("Screen Curtain: lock when used at the Mac \(on ? "on" : "off").", show: false)
    }

    private init() {
        // The recorded phase, not the checked one: after a crash the marker is stale, and the curtain
        // that was on should come back instead of being left as a fault.
        phase = CurtainStateStore.reading().recorded
        installRecoveryHotKey()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        lockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateForNativeLock()
                self?.confirmCoverage()
                self?.watchForLocalUse()
            }
        }
        if phase == .active || phase == .preparing || phase == .releasing {
            beginTransition(to: .active)
        }
    }

    // Control-Option-Command-F12 is reserved for local recovery. It is handled by the app,
    // while the MCP helper blocks synthetic keyboard input whenever the curtain is active.
    private func installRecoveryHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), curtainHotKeyHandler, 1, &eventType,
                                            nil, &eventHandler)
        SetupModel.shared.note("Screen Curtain: hotkey event handler install returned \(installed).", show: false)
        guard installed == noErr else { return }
        let identifier = EventHotKeyID(signature: OSType(0x4D434354), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_F12), UInt32(controlKey | optionKey | cmdKey), identifier,
                                             GetApplicationEventTarget(), 0, &hotKey)
        SetupModel.shared.note("Screen Curtain: hotkey registration returned \(registered).", show: false)
        if registered != noErr { hotKey = nil }
    }

    func toggleFromLocalHotKey() {
        lastHotKeyAt = Date()
        switch phase {
        case .off:
            enable()
        case .active:
            restore()
        case .preparing, .releasing:
            break
        case .fault:
            restore()
        }
    }

    private func enable() {
        beginTransition(to: .active)
    }

    private func restore() {
        beginTransition(to: .off)
    }

    private func beginTransition(to target: CurtainPhase) {
        guard target == .active || target == .off, !sessionIsLocked else { return }
        let interim: CurtainPhase = target == .active ? .preparing : .releasing
        do {
            try record(interim)
            phase = interim
            transitionTarget = target
            transitionDeadline = Date().addingTimeInterval(10)
            advanceTransition()
        } catch {
            phase = .fault
            try? record(.fault)
        }
    }

    private func advanceTransition() {
        guard let target = transitionTarget else { return }
        do {
            guard try inputLock.tryLock() else {
                if Date() >= (transitionDeadline ?? .distantPast) {
                    transitionTarget = nil
                    phase = .fault
                    try? record(.fault)
                    return
                }
                if transitionTimer == nil {
                    transitionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                        Task { @MainActor in
                            guard let self, self.transitionTarget != nil else { timer.invalidate(); return }
                            self.advanceTransition()
                        }
                    }
                }
                return
            }
            defer { inputLock.unlock() }
            transitionTimer?.invalidate()
            transitionTimer = nil
            transitionTarget = nil
            if target == .active {
                guard try recordingLock.tryLock() else { throw CurtainError.recordingInProgress }
                defer { recordingLock.unlock() }
                try showPanels()
                try record(.active)
                phase = .active
                armedAt = Date().addingTimeInterval(localUseGraceSeconds)
            } else {
                panels.forEach { $0.orderOut(nil); $0.close() }
                panels.removeAll()
                try record(.off)
                phase = .off
            }
        } catch {
            if target == .off { try? showPanels() }
            phase = .fault
            try? record(.fault)
        }
    }

    private func showPanels() throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw CurtainError.noDisplays }
        let replacement = screens.map { screen -> NSPanel in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false, screen: screen)
            panel.identifier = NSUserInterfaceItemIdentifier("mac-control-curtain")
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.orderFrontRegardless()
            return panel
        }
        guard replacement.count == screens.count, replacement.allSatisfy(\.isVisible) else {
            replacement.forEach { $0.close() }
            throw CurtainError.coverageUnavailable
        }
        panels.forEach { $0.close() }
        panels = replacement
        hiddenForNativeLock = false
    }

    private func screensChanged() {
        guard phase == .active else { return }
        if sessionIsLocked {
            panels.forEach { $0.orderOut(nil) }
            hiddenForNativeLock = true
            return
        }
        beginTransition(to: .active)
    }

    private func updateForNativeLock() {
        guard phase == .active else { return }
        if sessionIsLocked {
            if !hiddenForNativeLock {
                panels.forEach { $0.orderOut(nil) }
                hiddenForNativeLock = true
            }
        } else if hiddenForNativeLock {
            if lockedForLocalUse {
                // The person who just unlocked the Mac is the user, so the desktop comes back.
                lockedForLocalUse = false
                SetupModel.shared.note("Screen Curtain: unlocked after a lock for local use; restoring the displays.", show: false)
                beginTransition(to: .off)
            } else {
                beginTransition(to: .active)
            }
        }
    }

    // Keyboard and mouse input in the HID state comes from the Mac's own keyboard and mouse, or from a program
    // posting there. While the curtain is active, mac-control posts nothing there: its keyboard and mouse tools
    // are paused, and background input goes to an app's process. So any such input after a short grace locks
    // the Mac. Modifier keys are not counted, and the recovery shortcut's own key press is let through.
    private func watchForLocalUse() {
        let now = Date()
        if let requested = lockRequestedAt {
            if sessionIsLocked {
                lockRequestedAt = nil
                SetupModel.shared.note("Screen Curtain: the Mac locked after local use.", show: false)
            } else if now.timeIntervalSince(requested) > lockConfirmSeconds {
                failLocalUseLock("the Mac did not lock within \(Int(lockConfirmSeconds)) seconds")
            }
            return
        }
        guard lockOnLocalUse, phase == .active, !hiddenForNativeLock, !sessionIsLocked, now >= armedAt else { return }
        let age = localInputTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        switch LocalUseDecision.decide(now: now, armedAt: armedAt, inputAge: age, lastShortcutAt: lastHotKeyAt) {
        case .wait:
            return
        case .ignoreShortcut:
            armedAt = now
        case .lock:
            SetupModel.shared.note("Screen Curtain: keyboard or mouse used at the Mac; locking it.", show: false)
            guard let lock = lockScreenFunction else {
                failLocalUseLock("this macOS does not offer the lock MacControl uses")
                return
            }
            lockRequestedAt = now
            lockedForLocalUse = true
            // Whether it worked is read from the session on the next ticks, not from what the call returns.
            _ = lock()
        }
    }

    // The Mac did not lock: the curtain stays and agents pause until someone at the Mac restores the displays.
    private func failLocalUseLock(_ reason: String) {
        lockRequestedAt = nil
        lockedForLocalUse = false
        SetupModel.shared.note("Screen Curtain: \(reason) after local use; pausing agents.", show: false)
        phase = .fault
        do { try record(.fault) } catch {
            SetupModel.shared.note("Screen Curtain: could not record the fault (\(error.localizedDescription)); agents pause once the state goes stale.", show: false)
        }
    }

    // The servers trust the marker only while this keeps rewriting it, so a crashed or hung app cannot
    // leave agents working behind panels that are gone. Coverage that no longer matches the displays is
    // rebuilt instead of confirmed.
    private func confirmCoverage() {
        guard phase != .off, phase != .fault else { return }
        if phase == .active, !hiddenForNativeLock,
           panels.count != NSScreen.screens.count || !panels.allSatisfy(\.isVisible) {
            beginTransition(to: .active)
            return
        }
        guard Date().timeIntervalSince(lastHeartbeat) >= CurtainStateStore.heartbeatSeconds else { return }
        // A failed write is tried again on the next tick; until one succeeds, the marker ages and the
        // servers already treat it as a fault.
        try? record(phase)
    }

    private func record(_ phase: CurtainPhase) throws {
        try CurtainStateStore.write(phase)
        lastHeartbeat = Date()
    }

    private var sessionIsLocked: Bool {
        ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
    }
}

private let lockOnLocalUseKey = "curtainLockOnLocalUse"
private let localUseGraceSeconds: TimeInterval = 2
private let lockConfirmSeconds: TimeInterval = 3

// SACLockScreenImmediate locks the session as Control-Command-Q does. It is in the login framework that macOS uses
// for that, which is not public API, so it is looked up once and may be missing.
private let lockScreenFunction: (@convention(c) () -> Int32)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
          let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
}()
private let localInputTypes: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
                                              .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]

private enum CurtainError: Error {
    case noDisplays
    case coverageUnavailable
    case recordingInProgress
}

private let curtainHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var pressed = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
    guard status == noErr, pressed.signature == OSType(0x4D434354), pressed.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    Task { @MainActor in
        SetupModel.shared.note("Screen Curtain: recovery hotkey received.", show: false)
        CurtainCoordinator.shared.toggleFromLocalHotKey()
    }
    return noErr
}
