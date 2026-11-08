import AppKit
import PlamoKit
import SwiftUI

/// Developer diagnostics: `MIMIUCHI_SNAPSHOT_DIR=/path open Mimiuchi.app`
///
/// Drives the real UI end to end (main translator, a simulated ⌘C+C overlay, model store,
/// settings), renders the app's own windows to PNG and writes `report.json`, then quits.
@MainActor
enum SnapshotRunner {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["MIMIUCHI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func run(model: AppModel, directory: URL) {
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var report: [[String: Any]] = []
            // Terms of Use gate. Without the user's agreement the rest of the run shows the gate
            // and translations fail with "termsNotAccepted" (that is the expected locked state).
            await snapshot(TermsGateView(forceFirstLaunchTitle: true).environment(model), size: NSSize(width: 1080, height: 760), to: directory.appendingPathComponent("terms.png"))
            report.append(["surface": "terms", "loaded": TermsOfUse.current != nil, "accepted": model.settings.hasAcceptedCurrentTerms])
            if let id = ProcessInfo.processInfo.environment["MIMIUCHI_SNAPSHOT_MODEL"],
                let d = PlamoModelCatalog.all.first(where: { $0.sizeLabel.lowercased() == id.lowercased() })
            {
                model.models.select(d)
            }

            // 0. Optional: exercise the model store (delete + download with progress) via the app's own code.
            if ProcessInfo.processInfo.environment["MIMIUCHI_SNAPSHOT_REDOWNLOAD"] == "1" {
                let d = PlamoModelCatalog.defaultModel
                do { try model.models.delete(d) } catch { report.append(["surface": "delete", "error": error.localizedDescription]) }
                report.append(["surface": "afterDelete", "installed": model.models.store.isInstalled(d)])
                model.models.download(d)
                var sawProgress = false
                for i in 0 ..< 1200 {
                    try? await Task.sleep(for: .milliseconds(250))
                    let state = model.models.state(for: d)
                    if case .downloading(let p) = state, p.fraction > 0.3, !sawProgress {
                        sawProgress = true
                        await snapshot(ModelStoreView().environment(model), size: NSSize(width: 900, height: 860), to: directory.appendingPathComponent("models-downloading.png"))
                        report.append(["surface": "downloading", "fraction": p.fraction, "bytesPerSecond": p.bytesPerSecond, "file": p.currentFile])
                    }
                    if state.isInstalled || i == 1199 {
                        if case .failed(let message) = state { report.append(["surface": "download", "error": message]) }
                        break
                    }
                    if case .failed(let message) = state {
                        report.append(["surface": "download", "error": message])
                        break
                    }
                }
                report.append(["surface": "afterDownload", "installed": model.models.store.isInstalled(d), "selected": model.settings.selectedModelId])
                model.models.select(d)
            }

            // 1. Main window translation (ja -> en, auto-detected).
            model.showOnboarding = false
            model.showMainWindow(text: "会議は来週の月曜日に変更されました。資料は前日までに共有してください。")
            await waitFinished(model.mainSession)
            report.append(entry("main", model.mainSession))
            snapshot(window: model.mainWindow, to: directory.appendingPathComponent("main.png"))

            // 1b. Key-path self-test: feed ⌘C events through DoubleCopyMonitor's real handler.
            if ProcessInfo.processInfo.environment["MIMIUCHI_SNAPSHOT_KEYTEST"] == "1" {
                await keyPathSelfTest(model: model, directory: directory, report: &report)
            }

            // 2. Simulated ⌘C+C: the copied text is read from the pasteboard and shown in the overlay.
            let copied = "Apple silicon brings incredible performance and efficiency to the Mac, so you can translate on device without sending text anywhere."
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
            let trigger = ShortcutTrigger(
                sourceApplication: NSWorkspace.shared.frontmostApplication,
                changeCountAtTrigger: NSPasteboard.general.changeCount,
                changeCountAtFirstPress: NSPasteboard.general.changeCount,
                mouseLocation: NSPoint(x: 300, y: 700))
            model.overlay.handle(trigger)
            try? await Task.sleep(for: .milliseconds(600))
            await waitFinished(model.overlay.session)
            report.append(entry("overlay", model.overlay.session))
            snapshot(window: NSApp.windows.first { $0 is OverlayPanel }, to: directory.appendingPathComponent("overlay.png"))
            model.overlay.close()

            // 3. Other screens, rendered standalone.
            await snapshot(ModelStoreView().environment(model), size: NSSize(width: 900, height: 860), to: directory.appendingPathComponent("models.png"))
            await snapshot(SettingsView().environment(model), size: NSSize(width: 640, height: 560), to: directory.appendingPathComponent("settings.png"))
            await snapshot(HistoryView().environment(model), size: NSSize(width: 800, height: 520), to: directory.appendingPathComponent("history.png"))
            await snapshot(OnboardingView().environment(model), size: NSSize(width: 560, height: 560), to: directory.appendingPathComponent("onboarding.png"))
            await snapshot(AboutSettings().environment(model), size: NSSize(width: 640, height: 1000), to: directory.appendingPathComponent("about.png"))
            await snapshot(LicenseTextView(document: .plamoJapanese), size: NSSize(width: 600, height: 520), to: directory.appendingPathComponent("license.png"))

            // 4. Standard About panel (credits with the "Built with PLaMo" notice).
            AboutPanel.show()
            try? await Task.sleep(for: .milliseconds(500))
            let aboutPanel = NSApp.windows.first { $0.isVisible && type(of: $0) == NSPanel.self }
            report.append(["surface": "aboutPanel", "found": aboutPanel != nil, "windows": NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) }])
            snapshot(window: aboutPanel, to: directory.appendingPathComponent("about-panel.png"))
            aboutPanel?.close()

            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
        }
    }

    /// Scenarios run through `DoubleCopyMonitor` exactly as global key events would be.
    private static func keyPathSelfTest(model: AppModel, directory: URL, report: inout [[String: Any]]) async {
        let c = UInt16(8)  // kVK_ANSI_C
        let v = UInt16(9)  // kVK_ANSI_V
        var t = ProcessInfo.processInfo.systemUptime
        func press(_ key: UInt16, _ mods: NSEvent.ModifierFlags = .command, repeat r: Bool = false, after dt: TimeInterval) async {
            t += dt
            // Like the frontmost app, ⌘C copies the "selection" before we see the second press.
            if key == c && !r && mods == .command {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentSelection, forType: .string)
            }
            model.monitor.injectForSelfTest(keyCode: key, modifiers: mods, isRepeat: r, timestamp: t)
            try? await Task.sleep(for: .milliseconds(Int(dt * 1000)))
        }
        func shown() -> Bool { model.overlay.isVisible }

        // (a) single ⌘C → nothing
        currentSelection = "Single copy only."
        await press(c, after: 0.05)
        try? await Task.sleep(for: .milliseconds(700))
        report.append(["surface": "keytest-single", "overlayShown": shown()])

        // (b) ⌘C, ⌘V, ⌘C → nothing (another key in between)
        await press(c, after: 0.6)
        await press(v, after: 0.1)
        await press(c, after: 0.1)
        try? await Task.sleep(for: .milliseconds(700))
        report.append(["surface": "keytest-interrupted", "overlayShown": shown()])

        // (c) holding ⌘C (auto-repeat) → nothing
        await press(c, after: 0.6)
        await press(c, repeat: true, after: 0.05)
        await press(c, repeat: true, after: 0.05)
        try? await Task.sleep(for: .milliseconds(700))
        report.append(["surface": "keytest-autorepeat", "overlayShown": shown()])

        // (d) ⌘C ⌘C within the interval → overlay with the copied text and its translation
        currentSelection = "Select any text and press Command-C twice to see the translation right where you are."
        await press(c, after: 0.8)
        await press(c, after: 0.2)
        try? await Task.sleep(for: .milliseconds(600))
        await waitFinished(model.overlay.session)
        report.append([
            "surface": "keytest-double", "overlayShown": shown(),
            "source": model.overlay.session.sourceText, "translation": model.overlay.session.translatedText,
            "sourceMatchesCopiedText": model.overlay.session.sourceText == currentSelection,
        ])
        snapshot(window: NSApp.windows.first { $0 is OverlayPanel }, to: directory.appendingPathComponent("overlay-keytest.png"))
        model.overlay.close()
    }

    private static var currentSelection = ""

    private static func waitFinished(_ session: TranslationSession) async {
        for _ in 0 ..< 600 {
            try? await Task.sleep(for: .milliseconds(100))
            switch session.phase {
            case .finished, .failed: return
            default: continue
            }
        }
    }

    private static func entry(_ name: String, _ session: TranslationSession) -> [String: Any] {
        var e: [String: Any] = [
            "surface": name, "source": session.sourceText, "translation": session.translatedText,
            "target": session.targetLanguage, "detected": session.detectedLanguage?.code ?? "",
        ]
        if case .failed(let message) = session.phase { e["error"] = message }
        if let s = session.statistics {
            e["tokensPerSecond"] = s.tokensPerSecond
            e["generatedTokens"] = s.generatedTokens
            e["promptTokens"] = s.promptTokens
        }
        return e
    }

    /// Renders a window of this app (no screen-recording permission needed).
    static func snapshot(window: NSWindow?, to url: URL) {
        guard let window, let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Renders a SwiftUI view in a plain window (materials/vibrancy can't be captured offscreen).
    static func snapshot<V: View>(_ view: V, size: NSSize, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}
