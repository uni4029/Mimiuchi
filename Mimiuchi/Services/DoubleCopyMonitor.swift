import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.hidsystem

/// Context captured when the shortcut fires.
struct ShortcutTrigger {
    var sourceApplication: NSRunningApplication?
    /// Pasteboard change count right before the second press was processed.
    var changeCountAtTrigger: Int
    /// Pasteboard change count when the first press happened.
    var changeCountAtFirstPress: Int
    var mouseLocation: NSPoint
}

/// Receives key-down events from every app through a listen-only CGEvent tap on its own thread.
///
/// macOS only lets an app observe keys typed in other apps with the Input Monitoring permission
/// (Accessibility alone is not enough for any kind of key tap or NSEvent global monitor). A
/// listen-only tap cannot change or delay events, and the callback just queues the key for the
/// main actor, so Mimiuchi can never slow down typing elsewhere.
nonisolated final class KeyEventTap: @unchecked Sendable {
    typealias Handler = @Sendable (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ isRepeat: Bool, _ timestamp: TimeInterval) -> Void

    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Returns `false` when macOS refuses the tap (no Input Monitoring permission yet, or it was
    /// granted while the app was running and takes effect after a relaunch).
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: keyEventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [self] in runTapLoop() }
        thread.name = "Mimiuchi key event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        source = nil
        runLoop = nil
    }

    private func runTapLoop() {
        runLoop = CFRunLoopGetCurrent()
        if let source { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        ready.signal()
        CFRunLoopRun()
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS can turn a tap off (e.g. after a timeout); turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            handler(
                UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                ProcessInfo.processInfo.systemUptime)
        default:
            break
        }
    }
}

nonisolated private func keyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyEventTap>.fromOpaque(refcon).takeUnretainedValue().receive(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// What the ⌘C+C key monitor is doing (shown in the menu bar, window and Settings).
enum ShortcutMonitorState: String {
    /// Turned off in Settings.
    case disabled
    /// Input Monitoring is not granted.
    case needsInputMonitoring
    /// Input Monitoring is on, but macOS applies it to Mimiuchi only after a restart.
    case needsRelaunch
    case monitoring
    /// The user has not agreed to the (current) Terms of Use yet.
    case termsNotAccepted
}

/// Watches global key presses (requires the Input Monitoring permission) and reports ⌘C+C.
@MainActor
@Observable
final class DoubleCopyMonitor {
    @ObservationIgnored var onTrigger: ((ShortcutTrigger) -> Void)?
    private(set) var state: ShortcutMonitorState = .needsInputMonitoring

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var detector: DoublePressDetector
    @ObservationIgnored private var eventTap: KeyEventTap?
    @ObservationIgnored private var changeCountAtFirstPress = 0
    @ObservationIgnored private var permissionTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        self.detector = DoublePressDetector(shortcut: settings.shortcut, interval: settings.doublePressInterval)
    }

    var isRunning: Bool { state == .monitoring }

    /// Starts monitoring as soon as the Input Monitoring permission is available.
    func start() {
        updateConfiguration()
        guard settings.hasAcceptedCurrentTerms else {
            stop()
            setState(.termsNotAccepted)
            return
        }
        guard settings.doubleCopyEnabled else {
            stop()
            setState(.disabled)
            return
        }
        if !installMonitor() {
            waitForPermission()
        }
    }

    func stop() {
        eventTap?.stop()
        eventTap = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        detector.reset()
        setState(settings.doubleCopyEnabled ? .needsInputMonitoring : .disabled)
    }

    func updateConfiguration() {
        detector.shortcut = settings.shortcut
        detector.interval = settings.doublePressInterval
    }

    /// Returns `true` when key events are being received.
    @discardableResult
    private func installMonitor() -> Bool {
        if eventTap != nil { return true }
        guard InputMonitoringPermission.isGranted else {
            setState(.needsInputMonitoring)
            return false
        }
        let monitor = WeakReference(self)
        let tap = KeyEventTap { keyCode, modifiers, isRepeat, timestamp in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    monitor.value?.handle(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, timestamp: timestamp)
                }
            }
        }
        guard tap.start() else {
            // Granted while Mimiuchi was running and the user chose 「あとで行う」: macOS only lets
            // this process see keys after a restart.
            setState(.needsRelaunch)
            return false
        }
        eventTap = tap
        permissionTimer?.invalidate()
        permissionTimer = nil
        setState(.monitoring)
        return true
    }

    private func setState(_ newState: ShortcutMonitorState) {
        if state != newState { state = newState }
        reportStatus()
    }

    /// Developer diagnostics (`MIMIUCHI_DEBUG_DIR`): lets Tools/e2e-cmdcc.sh tell a missing
    /// permission apart from a detection problem.
    private func reportStatus() {
        guard let dir = LaunchOptions.debugDirectory else { return }
        let url = URL(fileURLWithPath: dir)
        let text = """
            \(state.rawValue)
            mechanism=listen-only event tap
            accessibility=\(AccessibilityPermission.isTrusted) inputMonitoring=\(InputMonitoringPermission.isGranted)

            """
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url.appendingPathComponent("monitor-status.txt"))
    }

    /// Polls until the user grants Input Monitoring in System Settings.
    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.installMonitor()
            }
        }
    }

    /// Feeds a key event through the same path as the global monitor (diagnostics/self-test).
    func injectForSelfTest(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false, timestamp: TimeInterval) {
        handle(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, timestamp: timestamp)
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, timestamp: TimeInterval) {
        guard settings.doubleCopyEnabled else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        DebugTrace.log(keyCode == settings.shortcut.keyCode
            ? "keyDown shortcut-key mods=\(String(modifiers.intersection(DoublePressShortcut.relevantModifiers).rawValue, radix: 16)) repeat=\(isRepeat) t=\(timestamp) front=\(frontmost?.processIdentifier ?? -1)"
            : "keyDown other-key")
        if frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        if settings.isExcluded(bundleIdentifier: frontmost?.bundleIdentifier) {
            detector.reset()
            return
        }
        let fired = detector.handleKeyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, timestamp: timestamp)
        if fired { DebugTrace.log("double press detected") }
        if fired {
            onTrigger?(ShortcutTrigger(
                sourceApplication: frontmost,
                changeCountAtTrigger: NSPasteboard.general.changeCount,
                changeCountAtFirstPress: changeCountAtFirstPress,
                mouseLocation: NSEvent.mouseLocation))
        } else if detector.firstPressTime == timestamp {
            // This press started a new sequence (also after an earlier one expired).
            changeCountAtFirstPress = NSPasteboard.general.changeCount
        }
    }
}

/// Accessibility permission helpers.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open System Settings.
    @discardableResult
    static func request() -> Bool {
        // Value of kAXTrustedCheckOptionPrompt (the global itself is not concurrency-safe in Swift 6).
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Removes Mimiuchi from System Settings > Accessibility (see `PrivacyPermissionReset`).
    @discardableResult
    static func reset() -> Bool { PrivacyPermissionReset.reset(service: "Accessibility") }
}

/// Input Monitoring (System Settings > Privacy & Security > 入力監視): needed to see the ⌘C+C
/// key presses in other apps.
enum InputMonitoringPermission {
    /// Asks TCC on every call (CGPreflightListenEventAccess can keep reporting a process's
    /// first answer until it restarts).
    static var isGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// Shows the system prompt and adds Mimiuchi to the Input Monitoring list.
    static func request() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func reset() -> Bool { PrivacyPermissionReset.reset(service: "ListenEvent") }
}

/// `tccutil reset <service> <bundle id>` for Mimiuchi's own entry.
///
/// macOS binds privacy permissions to the code signature. A switch that was turned on for an
/// earlier build with a different signature stays on but does not apply to this build; after a
/// reset, the next request adds a fresh entry for this build.
enum PrivacyPermissionReset {
    static func reset(service: String) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Reads the text that the frontmost app copied and where it is on screen.
enum SelectionCapture {
    /// Waits briefly for the frontmost app to finish handling the copy, then reads the pasteboard.
    static func copiedText(after trigger: ShortcutTrigger, simulateCopy: Bool) async -> String? {
        let pasteboard = NSPasteboard.general
        if simulateCopy {
            let before = pasteboard.changeCount
            TextInserter.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
            for _ in 0 ..< 25 where pasteboard.changeCount == before {
                try? await Task.sleep(for: .milliseconds(20))
            }
        } else {
            // The frontmost app handles both presses concurrently with us, so its copies may
            // already be on the pasteboard. Once a copy made during the shortcut is visible (both
            // presses copy the same selection), give the second one only a short grace period.
            let copyVisible = trigger.changeCountAtTrigger != trigger.changeCountAtFirstPress
            for _ in 0 ..< (copyVisible ? 2 : 15) where pasteboard.changeCount == trigger.changeCountAtTrigger {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        DebugTrace.log("pasteboard changeCount=\(pasteboard.changeCount) atTrigger=\(trigger.changeCountAtTrigger) atFirstPress=\(trigger.changeCountAtFirstPress) accessBehavior=\(pasteboard.accessBehavior.rawValue)")
        // The user set Mimiuchi's clipboard access to "deny" in System Settings.
        if pasteboard.accessBehavior == .alwaysDeny {
            return selectedTextViaAccessibility()
        }
        // Nothing was copied during the shortcut (e.g. no selection): prefer the live selection
        // over stale clipboard contents.
        let copiedDuringShortcut = simulateCopy || pasteboard.changeCount != trigger.changeCountAtFirstPress
        if !copiedDuringShortcut, let selected = selectedTextViaAccessibility() {
            return selected
        }
        DebugTrace.log("reading pasteboard string")
        let pasted = pasteboard.string(forType: .string)
        DebugTrace.log("pasteboard string: \(pasted.map { "\($0.count) chars" } ?? "nil")")
        if let text = pasted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return selectedTextViaAccessibility()
    }

    /// The focused element's selected text (fallback when nothing was copied).
    static func selectedTextViaAccessibility() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// Screen rect (Cocoa coordinates) of the current text selection, if the app exposes it.
    static func selectionBounds() -> NSRect? {
        guard let element = focusedElement() else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue
        else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else {
            return nil
        }
        // AX uses a top-left origin relative to the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }
}

/// Inserts text into the frontmost app by pasting (used by "置き換え").
enum TextInserter {
    static func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Activates `application`, places `text` on the pasteboard and sends ⌘V.
    static func paste(_ text: String, into application: NSRunningApplication?) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        application?.activate()
        try? await Task.sleep(for: .milliseconds(180))
        postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }
}
