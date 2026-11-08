import PlamoKit
import SwiftUI

/// First-run sheet: download a model and grant the Accessibility permission.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let recommended = PlamoModelCatalog.all.prefix(2)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mimiuchi へようこそ").font(.system(size: 22, weight: .bold))
                    Text("PLaMo 3 Translate を使って、この Mac の中だけで翻訳します。").foregroundStyle(.secondary)
                }
            }

            step(number: 1, title: "翻訳モデルをダウンロード", done: model.models.hasInstalledModel) {
                ForEach(recommended) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.displayName).fontWeight(.medium)
                            Text(d.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelAction(d)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("モデルは PLaMo Community License で提供されています。ダウンロードして使うと同意したことになります。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("PLaMo Community License を読む", destination: PlamoModelCatalog.licenseURL)
                }
                .font(.caption)
            }

            step(number: 2, title: "⌘C+C のために権限を許可", done: model.shortcutPermissionsGranted && model.monitor.state != .needsRelaunch) {
                Text("テキストを選択して ⌘ を押したまま C を2回押すと、その場に翻訳パネルが表示されます。システム設定 > プライバシーとセキュリティ で、キー入力を検出する「入力監視」と、選択範囲の位置を調べる「アクセシビリティ」を Mimiuchi に許可してください。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.monitor.state == .needsRelaunch {
                    Button("再起動して ⌘C+C を有効にする") { model.relaunch() }
                    Text(PermissionHelp.relaunch)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !model.shortcutPermissionsGranted {
                    HStack {
                        if !model.inputMonitoringGranted {
                            Button("入力監視を許可…") { model.requestInputMonitoring() }
                        }
                        if !model.accessibilityTrusted {
                            Button("アクセシビリティを許可…") { model.requestAccessibility() }
                        }
                    }
                    Text(PermissionHelp.staleSwitch)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(model.models.hasInstalledModel ? "はじめる" : "あとで") {
                    model.settings.hasCompletedOnboarding = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    @ViewBuilder
    private func modelAction(_ d: PlamoModelDescriptor) -> some View {
        switch model.models.state(for: d) {
        case .installed:
            Label("完了", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let p):
            HStack {
                ProgressView(value: p.fraction).frame(width: 110)
                Text("\(Int(p.fraction * 100))%").monospacedDigit().font(.caption)
            }
        case .failed(let message):
            Button("再試行") { model.models.download(d) }.help(message)
        case .notInstalled:
            Button("ダウンロード（\(ByteCountFormatter.string(fromByteCount: d.downloadBytes, countStyle: .file))）") {
                model.models.download(d)
            }
        }
    }

    private func step<Content: View>(number: Int, title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.brand)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }
}
