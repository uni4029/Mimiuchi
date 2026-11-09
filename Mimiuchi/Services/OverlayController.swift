import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Floating panel that shows the selected text and its translation without activating the app
/// (keyboard focus moves to the panel while the source app stays frontmost, like Spotlight).
final class OverlayPanel: NSPanel {
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 360, height: 220)
        backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Text views can consume Escape before it reaches cancelOperation or SwiftUI.
        // Handle it at the panel so dismissal does not depend on keyboard focus.
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        {
            cancelOperation(nil)
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        onClose?()
    }
}

/// Drives the ⌘C+C overlay: captures the selection, positions and shows the panel.
@MainActor
final class OverlayController {
    let session: TranslationSession
    private let settings: AppSettings
    private let model: AppModel
    private var panel: OverlayPanel?
    private var outsideClickMonitor: Any?
    private(set) var sourceApplication: NSRunningApplication?
    private(set) var isPinned = false
    private static let sizeKey = "overlayPanelSize"

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
        self.session = TranslationSession(
            models: model.models, settings: model.settings, history: model.history, glossary: model.glossary)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Handles a ⌘C+C trigger: read the copied text and show it with its translation.
    func handle(_ trigger: ShortcutTrigger) {
        let simulateCopy = !settings.shortcut.isCopyShortcut
        let selection = settings.overlayPlacement == .nearSelection ? SelectionCapture.selectionBounds() : nil
        DebugTrace.log("trigger: simulateCopy=\(simulateCopy) selection=\(selection.map { NSStringFromRect($0) } ?? "nil")")
        Task {
            let text = await SelectionCapture.copiedText(after: trigger, simulateCopy: simulateCopy) ?? ""
            DebugTrace.log("copied text: \(text.count) chars, presentation=\(settings.shortcutPresentation.rawValue)")
            switch settings.shortcutPresentation {
            case .mainWindow:
                model.showMainWindow(text: text)
            case .overlay:
                show(text: text, source: trigger.sourceApplication, anchor: selection, mouse: trigger.mouseLocation)
            }
        }
    }

    func show(text: String, source: NSRunningApplication?, anchor: NSRect?, mouse: NSPoint) {
        guard settings.hasAcceptedCurrentTerms else {
            model.showMainWindow()  // shows the Terms of Use
            return
        }
        DebugTrace.log("show overlay")
        sourceApplication = source
        let panel = self.panel ?? makePanel()
        self.panel = panel
        session.load(text: text)
        let size = Self.savedSize ?? panel.frame.size
        panel.setFrame(frame(for: size, anchor: anchor, mouse: mouse), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installOutsideClickMonitor()
        recordForDiagnosticsIfNeeded(anchor: anchor)
    }

    /// Developer diagnostics (`MIMIUCHI_DEBUG_DIR`): after each overlay translation, render the
    /// panel and append a JSON line, so the real ⌘C+C path can be verified end to end.
    private func recordForDiagnosticsIfNeeded(anchor: NSRect?) {
        guard let dir = LaunchOptions.debugDirectory.map({ URL(fileURLWithPath: $0) }) else { return }
        let session = self.session
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0 ..< 300 {
                if case .finished = session.phase { break }
                if case .failed = session.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, let panel = self.panel else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            SnapshotRunner.snapshot(window: panel, to: dir.appendingPathComponent("overlay-\(stamp).png"))
            let info: [String: Any] = [
                "source": session.sourceText, "translation": session.translatedText,
                "target": session.targetLanguage, "app": self.sourceApplication?.bundleIdentifier ?? "",
                "panelFrame": NSStringFromRect(panel.frame), "anchor": anchor.map { NSStringFromRect($0) } ?? "mouse",
                "tokensPerSecond": session.statistics?.tokensPerSecond ?? 0,
            ]
            if let line = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
                let url = dir.appendingPathComponent("overlay-log.jsonl")
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(line + Data("\n".utf8))
                    try? handle.close()
                } else {
                    try? (line + Data("\n".utf8)).write(to: url)
                }
            }
        }
    }

    func close() {
        panel?.close()
    }

    func togglePin() {
        isPinned.toggle()
    }

    /// Replaces the original selection with the translation (paste into the source app).
    func replaceSelection() {
        let translation = session.translatedText
        guard !translation.isEmpty else { return }
        let app = sourceApplication
        close()
        Task { await TextInserter.paste(translation, into: app) }
    }

    func openInMainWindow() {
        let text = session.sourceText
        let target = session.targetLanguage
        close()
        model.showMainWindow(text: text, targetLanguage: target)
    }

    // MARK: - Private

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        let root = OverlayView(session: session, controller: self)
            .environment(model)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onClose = { [weak self] in
            MainActor.assumeIsolated { self?.didClose() }
        }
        return panel
    }

    private func didClose() {
        if let panel { Self.savedSize = panel.frame.size }
        removeOutsideClickMonitor()
        session.cancel()
        isPinned = false
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible, !self.isPinned else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private static var savedSize: NSSize? {
        get {
            guard let s = UserDefaults.standard.string(forKey: sizeKey) else { return nil }
            let size = NSSizeFromString(s)
            return size.width >= 300 && size.height >= 200 ? size : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(NSStringFromSize(newValue), forKey: sizeKey) }
        }
    }

    /// Below the selection (or above when there is no room), clamped to the visible screen.
    private func frame(for size: NSSize, anchor: NSRect?, mouse: NSPoint) -> NSRect {
        let point = anchor.map { NSPoint(x: $0.minX, y: $0.minY) } ?? mouse
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        switch settings.overlayPlacement {
        case .screenCenter:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case .nearSelection, .nearMouse:
            let rect = settings.overlayPlacement == .nearSelection && anchor != nil
                ? anchor! : NSRect(origin: mouse, size: .zero)
            origin = NSPoint(x: rect.minX - 12, y: rect.minY - size.height - 10)
            if origin.y < visible.minY {
                origin.y = rect.maxY + 10
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }
}
