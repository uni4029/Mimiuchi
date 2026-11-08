import AppKit
import PlamoKit
import SwiftUI

@main
struct MimiuchiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .frame(width: 620, height: 520)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Mimiuchi について") { AboutPanel.show() }
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.model)
        } label: {
            Image(systemName: "character.bubble.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchOptions.load()
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem =
            event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServicesProvider(model: model)
        NSUpdateDynamicServices()
        model.start()
        // Like DeepL: stay in the menu bar when started at login, otherwise show the window.
        if !launchedAsLoginItem && SnapshotRunner.outputDirectory == nil && !AppModel.isHeadless {
            model.showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }

    /// Keep running in the menu bar when the window is closed (like DeepL).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// macOS Services menu: "Mimiuchiで翻訳" for selected text in any app.
final class ServicesProvider: NSObject {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    @objc func translateSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else { return }
        MainActor.assumeIsolated {
            model.overlay.show(text: text, source: NSWorkspace.shared.frontmostApplication, anchor: nil, mouse: NSEvent.mouseLocation)
        }
    }
}

/// Menu bar extra menu.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.hasAcceptedCurrentTerms {
            mainMenu
        } else {
            Button("利用規約を確認…") { model.showMainWindow() }
            Divider()
            Button("Mimiuchi を終了") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var mainMenu: some View {
        Button("翻訳ウィンドウを開く") { model.showMainWindow() }
            .keyboardShortcut("o")
        Button("クリップボードを翻訳") { model.translateClipboardInOverlay() }
        Divider()
        Text("ショートカット: \(model.settings.shortcut.displayString)")
        if model.settings.doubleCopyEnabled {
            if model.monitor.state == .needsRelaunch {
                Button("⚠︎ 再起動して ⌘C+C を有効にする") { model.relaunch() }
            } else if !model.shortcutPermissionsGranted {
                Button("⚠︎ ⌘C+C の権限を許可…") { model.requestShortcutPermissions() }
            }
        }
        Divider()
        Menu("翻訳モデル") {
            ForEach(model.models.installedModels) { m in
                Button {
                    model.models.select(m)
                } label: {
                    if model.models.activeModel?.id == m.id {
                        Label(m.displayName, systemImage: "checkmark")
                    } else {
                        Text(m.displayName)
                    }
                }
            }
            if !model.models.installedModels.isEmpty { Divider() }
            Button("モデルストア…") { model.showSection(.models) }
        }
        Button("設定…") { model.showSection(.settings) }
            .keyboardShortcut(",")
        Button("Mimiuchi について") { AboutPanel.show() }
        Divider()
        Button("Mimiuchi を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
