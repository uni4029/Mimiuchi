import Carbon.HIToolbox
import PlamoKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("一般", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("ショートカット", systemImage: "keyboard") }
            ExcludedAppsSettings().tabItem { Label("オフにしたアプリ", systemImage: "nosign") }
            ModelSettings().tabItem { Label("モデル", systemImage: "cpu") }
            AboutSettings().tabItem { Label("情報", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("設定")
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("言語") {
                Picker("訳文の言語", selection: $settings.primaryLanguage) {
                    ForEach(PlamoLanguage.all) { Text($0.japaneseName).tag($0.code) }
                }
                Picker("第2言語", selection: $settings.secondaryLanguage) {
                    ForEach(PlamoLanguage.all) { Text($0.japaneseName).tag($0.code) }
                }
                Text("原文がすでに訳文の言語のときは、自動的に第2言語へ翻訳します。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("日本語の文体", selection: $settings.formality) {
                    ForEach(FormalityOption.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("翻訳") {
                Toggle("入力中に自動で翻訳", isOn: $settings.translateWhileTyping)
                    .onChange(of: settings.translateWhileTyping) { _, value in model.mainSession.translateWhileTyping = value }
                Toggle("翻訳履歴を保存（この Mac のみ）", isOn: $settings.saveHistory)
            }
            Section("アプリ") {
                Toggle("Dock にアイコンを表示", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { _, _ in model.applyDockIconPolicy() }
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("選択したテキストをショートカットキーで翻訳", isOn: $settings.doubleCopyEnabled)
                    .onChange(of: settings.doubleCopyEnabled) { _, _ in model.shortcutSettingsChanged() }
                LabeledContent("ショートカットキー") {
                    ShortcutRecorder(shortcut: $settings.shortcut) { model.shortcutSettingsChanged() }
                }
                .disabled(!settings.doubleCopyEnabled)
                LabeledContent("2回押しの間隔") {
                    HStack {
                        Slider(value: $settings.doublePressInterval, in: 0.25 ... 0.8, step: 0.05)
                            .frame(width: 180)
                            .onChange(of: settings.doublePressInterval) { _, _ in model.shortcutSettingsChanged() }
                        Text(String(format: "%.2f 秒", settings.doublePressInterval)).monospacedDigit().frame(width: 60)
                    }
                }
                .disabled(!settings.doubleCopyEnabled)
            } footer: {
                Text("テキストを選択し、修飾キーを押したまま \(settings.shortcut.keyLabel) キーを2回押すと翻訳します。1回目のコピーでは何も起こりません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("表示") {
                Picker("翻訳の表示先", selection: $settings.shortcutPresentation) {
                    ForEach(ShortcutPresentation.allCases) { Text($0.label).tag($0) }
                }
                Picker("オーバーレイの位置", selection: $settings.overlayPlacement) {
                    ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.shortcutPresentation != .overlay)
            }
            Section("権限") {
                PermissionRow(
                    name: "入力監視", granted: model.inputMonitoringGranted,
                    purpose: "ほかのアプリで押した \(settings.shortcut.displayString) を検出するために必要です。",
                    request: { model.requestInputMonitoring() },
                    openSettings: { InputMonitoringPermission.openSystemSettings() })
                PermissionRow(
                    name: "アクセシビリティ", granted: model.accessibilityTrusted,
                    purpose: "選択範囲の位置の取得と「置き換え」に必要です。",
                    request: { model.requestAccessibility() },
                    openSettings: { AccessibilityPermission.openSystemSettings() })
                if model.monitor.state == .needsRelaunch {
                    HStack {
                        Text(PermissionHelp.relaunch)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Mimiuchi を再起動") { model.relaunch() }
                    }
                } else if !model.shortcutPermissionsGranted {
                    Text(PermissionHelp.staleSwitch)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Records "modifiers + key" (pressed twice to trigger), DeepL style.
struct ShortcutRecorder: View {
    @Binding var shortcut: DoublePressShortcut
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "キーを押してください…" : shortcut.displayString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .tint(recording ? Color.brand : nil)
            if shortcut != .commandC {
                Button("⌘C に戻す") {
                    shortcut = .commandC
                    onChange()
                }
                .buttonStyle(.link)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection(DoublePressShortcut.relevantModifiers)
            guard !mods.isEmpty else {
                hint = "修飾キー（⌘ ⌥ ⌃ ⇧）と組み合わせてください"
                return nil
            }
            let label = (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !label.isEmpty, label.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) else {
                hint = "英数字キーまたはスペースを使ってください"
                return nil
            }
            shortcut = DoublePressShortcut(keyCode: event.keyCode, modifiers: mods.rawValue, keyLabel: label == " " ? "Space" : label)
            onChange()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ExcludedAppsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ここに追加したアプリでは \(model.settings.shortcut.displayString) に反応しません。")
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(model.settings.excludedApps) { app in
                    HStack {
                        Image(nsImage: icon(for: app.bundleIdentifier))
                            .resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(app.bundleIdentifier)
                }
            }
            .listStyle(.bordered)
            .overlay {
                if model.settings.excludedApps.isEmpty {
                    Text("オフにしたアプリはありません").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Button { addApp() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                Button {
                    model.settings.excludedApps.removeAll { selection.contains($0.bundleIdentifier) }
                    selection.removeAll()
                } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                !model.settings.excludedApps.contains(where: { $0.bundleIdentifier == id })
            else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            model.settings.excludedApps.append(ExcludedApp(bundleIdentifier: id, name: name))
        }
    }
}

private struct ModelSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("翻訳モデル") {
                Picker("使用するモデル", selection: Binding(get: { model.models.activeModel?.id ?? "" }, set: { id in
                    if let d = PlamoModelCatalog.descriptor(id: id) { model.models.select(d) }
                })) {
                    ForEach(model.models.installedModels) { Text($0.displayName).tag($0.id) }
                    if model.models.installedModels.isEmpty { Text("なし").tag("") }
                }
                Button("モデルストアを開く…") { model.showSection(.models) }
            }
            Section("メモリ") {
                Picker("使用しないときにメモリから解放", selection: $settings.unloadAfterIdleMinutes) {
                    Text("しない").tag(0)
                    Text("5分後").tag(5)
                    Text("15分後").tag(15)
                    Text("60分後").tag(60)
                }
                Text("モデルは次の翻訳時に自動で再読み込みされます（0.8B で約1秒）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
