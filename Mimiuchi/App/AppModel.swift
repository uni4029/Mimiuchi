import AVFoundation
import AppKit
import Observation
import PlamoKit
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case translator, glossary, history, models, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .translator: "翻訳"
        case .glossary: "用語集"
        case .history: "履歴"
        case .models: "モデル"
        case .settings: "設定"
        }
    }
    var symbol: String {
        switch self {
        case .translator: "character.bubble"
        case .glossary: "book.closed"
        case .history: "clock.arrow.circlepath"
        case .models: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

/// Developer/test switches: `MIMIUCHI_HEADLESS=1` (menu bar + ⌘C+C overlay only) and
/// `MIMIUCHI_DEBUG_DIR` (diagnostics for Tools/e2e-cmdcc.sh).
///
/// Read from the environment, or from same-named defaults for a LaunchServices launch, which
/// cannot always pass environment variables or arguments. The defaults are one-shot: they are
/// removed as soon as they are read, so the next normal launch is unaffected.
enum LaunchOptions {
    private static let keys = ["MIMIUCHI_HEADLESS", "MIMIUCHI_DEBUG_DIR"]
    private static let values: [String: String] = {
        var result = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
        let defaults = UserDefaults.standard
        for key in keys {
            if result[key] == nil, let value = defaults.string(forKey: key) { result[key] = value }
            defaults.removeObject(forKey: key)
        }
        return result
    }()

    /// Called at launch so that one-shot defaults apply to this launch only.
    static func load() { _ = values }
    static var headless: Bool { values["MIMIUCHI_HEADLESS"] == "1" }
    static var debugDirectory: String? { values["MIMIUCHI_DEBUG_DIR"] }
}

/// Developer diagnostics (`MIMIUCHI_DEBUG_DIR`): timestamped trace of the ⌘C+C path.
enum DebugTrace {
    static func log(_ message: @autoclosure () -> String) {
        guard let dir = LaunchOptions.debugDirectory else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("trace.log")
        let line = Data((String(format: "%.3f ", Date().timeIntervalSince1970) + message() + "\n").utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// Root object shared by all windows.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let models: ModelManager
    let history: HistoryStore
    let glossary: GlossaryStore
    let mainSession: TranslationSession
    let speech = SpeechService()

    var selectedSection: SidebarSection = .translator
    private(set) var accessibilityTrusted = AccessibilityPermission.isTrusted
    private(set) var inputMonitoringGranted = InputMonitoringPermission.isGranted
    /// Both permissions that ⌘C+C needs: Input Monitoring to see the key presses, Accessibility
    /// for the selection position and 「置き換え」.
    var shortcutPermissionsGranted: Bool { accessibilityTrusted && inputMonitoringGranted }
    var showOnboarding = false

    @ObservationIgnored private(set) var monitor: DoubleCopyMonitor!
    @ObservationIgnored private(set) var overlay: OverlayController!
    @ObservationIgnored private var mainWindowController: MainWindowController?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var inputMonitoringRequested = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        let models = ModelManager(settings: settings)
        let history = HistoryStore()
        let glossary = GlossaryStore()
        self.models = models
        self.history = history
        self.glossary = glossary
        self.mainSession = TranslationSession(models: models, settings: settings, history: history, glossary: glossary)
        self.mainSession.translateWhileTyping = settings.translateWhileTyping
        self.monitor = DoubleCopyMonitor(settings: settings)
        self.overlay = OverlayController(model: self)
        monitor.onTrigger = { [weak self] trigger in
            self?.overlay.handle(trigger)
        }
    }

    /// `MIMIUCHI_HEADLESS=1`: run only the menu bar + ⌘C+C overlay (used by automated tests).
    static var isHeadless: Bool { LaunchOptions.headless }

    func start() {
        applyDockIconPolicy()
        if let directory = SnapshotRunner.outputDirectory {
            SnapshotRunner.run(model: self, directory: directory)
            return
        }
        guard settings.hasAcceptedCurrentTerms else {
            // The main window shows the Terms of Use; the monitor only reports why it is idle.
            monitor.start()
            if !Self.isHeadless { showMainWindow() }
            return
        }
        startServices()
    }

    /// Called from the Terms of Use screen.
    func acceptTerms() {
        guard let terms = TermsOfUse.current else { return }
        settings.acceptedTermsHash = terms.hash
        settings.termsAcceptedAt = Date()
        startServices()
    }

    private func startServices() {
        monitor.start()
        models.preload()
        startPermissionPolling()
        if !Self.isHeadless, !settings.hasCompletedOnboarding || !models.hasInstalledModel {
            showMainWindow()
            showOnboarding = true
        }
    }

    // MARK: Windows

    func showMainWindow(text: String? = nil, targetLanguage: String? = nil) {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(model: self)
        }
        if let text {
            selectedSection = .translator
            mainSession.load(text: text, targetLanguage: targetLanguage)
        }
        NSApp.activate()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    var mainWindow: NSWindow? { mainWindowController?.window }

    func showSection(_ section: SidebarSection) {
        selectedSection = section
        showMainWindow()
    }

    /// Translates the current clipboard in the overlay (menu bar command / Services).
    func translateClipboardInOverlay() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        overlay.show(text: text, source: NSWorkspace.shared.frontmostApplication, anchor: nil, mouse: NSEvent.mouseLocation)
    }

    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    // MARK: Permission

    func requestAccessibility() {
        // A switch left on for an earlier build (another code signature) keeps this build
        // untrusted, so start from a fresh entry. This only removes a switch that is off or
        // does not apply to this build.
        if !AccessibilityPermission.isTrusted { AccessibilityPermission.reset() }
        AccessibilityPermission.request()
        AccessibilityPermission.openSystemSettings()
        startPermissionPolling()
    }

    func requestInputMonitoring() {
        // Same as for Accessibility: drop a switch left over from another code signature, but
        // only once per launch so that a switch the user just turned on is never removed.
        if !inputMonitoringRequested && !InputMonitoringPermission.isGranted { InputMonitoringPermission.reset() }
        inputMonitoringRequested = true
        InputMonitoringPermission.request()
        InputMonitoringPermission.openSystemSettings()
        startPermissionPolling()
    }

    /// Fixes whatever still keeps ⌘C+C from working (one step at a time).
    func requestShortcutPermissions() {
        if monitor.state == .needsRelaunch {
            relaunch()
        } else if !InputMonitoringPermission.isGranted {
            requestInputMonitoring()
        } else if !AccessibilityPermission.isTrusted {
            requestAccessibility()
        }
    }

    /// Starts a new instance of Mimiuchi and quits this one (Input Monitoring that was turned on
    /// while the app was running only applies after a restart).
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }

    func refreshPermission() {
        accessibilityTrusted = AccessibilityPermission.isTrusted
        inputMonitoringGranted = InputMonitoringPermission.isGranted
        if inputMonitoringGranted { monitor.start() }
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AccessibilityPermission.isTrusted
                if trusted != self.accessibilityTrusted { self.accessibilityTrusted = trusted }
                let listening = InputMonitoringPermission.isGranted
                if listening != self.inputMonitoringGranted {
                    self.inputMonitoringGranted = listening
                    if listening { self.monitor.start() }
                }
            }
        }
    }

    func shortcutSettingsChanged() {
        monitor.updateConfiguration()
        monitor.start()
    }
}

/// Text-to-speech for the 🔊 buttons.
@MainActor
final class SpeechService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, languageCode: String?) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if let code = languageCode {
            let bcp47: String
            switch code {
            case "zh-hans": bcp47 = "zh-CN"
            case "zh-hant": bcp47 = "zh-TW"
            case "ja-easy": bcp47 = "ja-JP"
            default: bcp47 = code
            }
            utterance.voice = AVSpeechSynthesisVoice(language: bcp47)
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}

/// AppKit window hosting the main SwiftUI interface (DeepL-style translator).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Mimiuchi"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MimiuchiMainWindow")
        window.contentView = NSHostingView(rootView: MainWindowView().environment(model))
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
