import PlamoKit
import SwiftUI

/// Content of the ⌘C+C overlay panel: selected text + translation.
struct OverlayView: View {
    @Bindable var session: TranslationSession
    let controller: OverlayController
    @Environment(AppModel.self) private var model
    @State private var pinned = false
    @State private var sourceExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            sourceSection
            Divider().opacity(0.6)
            translationSection
            Divider().opacity(0.6)
            footer
        }
        .background(.regularMaterial)
        .ignoresSafeArea()
        .onExitCommand { controller.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "character.bubble.fill")
                .foregroundStyle(Color.brand)
                .font(.system(size: 15))
                .padding(.leading, 4)
            LanguagePickerButton(kind: .source, selection: $session.sourceLanguage, detected: session.detectedLanguage)
                .controlSize(.small)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            LanguagePickerButton(
                kind: .target,
                selection: Binding(get: { session.targetLanguage }, set: { session.targetLanguage = $0 ?? model.settings.primaryLanguage }))
            if session.targetLanguage == "ja" {
                Picker(selection: $session.formality) {
                    ForEach(FormalityOption.allCases) { Text($0.label).tag($0) }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            Spacer(minLength: 4)
            PaneIconButton(systemImage: pinned ? "pin.fill" : "pin", help: pinned ? "固定を解除" : "パネルを固定（クリックしても閉じない）", active: pinned) {
                pinned.toggle()
                controller.togglePin()
            }
            PaneIconButton(systemImage: "macwindow", help: "メインウィンドウで開く") {
                controller.openInMainWindow()
            }
            PaneIconButton(systemImage: "xmark", help: "閉じる (esc)") {
                controller.close()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("選択したテキスト")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(session.sourceText.count) 文字")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Button(sourceExpanded ? "折りたたむ" : "編集") { sourceExpanded.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
            if session.sourceText.isEmpty {
                Text("テキストが選択されていません。テキストを選択してから \(model.settings.shortcut.displayString) を押してください。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if sourceExpanded {
                TextEditor(text: $session.sourceText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 140)
            } else {
                ScrollView {
                    Text(session.sourceText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 92)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Translation

    private var translationSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if case .failed(let message) = session.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    if !model.models.hasInstalledModel {
                        Button("モデルストアを開く") {
                            controller.close()
                            model.showSection(.models)
                        }
                    }
                }
                if session.translatedText.isEmpty {
                    HStack(spacing: 8) {
                        if session.isBusy { ProgressView().controlSize(.small) }
                        Text(session.phase == .loadingModel ? "モデルを読み込み中…" : (session.isBusy ? "翻訳中…" : ""))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 15))
                } else {
                    Text(session.translatedText)
                        .font(.system(size: 17))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            CopyButton(text: session.translatedText)
            PaneIconButton(systemImage: "speaker.wave.2", help: "読み上げ") {
                model.speech.speak(session.translatedText, languageCode: session.targetLanguage)
            }
            .disabled(session.translatedText.isEmpty)
            PaneIconButton(systemImage: "arrow.clockwise", help: "再翻訳") {
                session.retranslate()
            }
            .disabled(session.sourceText.isEmpty || session.isBusy)
            Button {
                controller.replaceSelection()
            } label: {
                Label("置き換え", systemImage: "text.insert")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.translatedText.isEmpty || session.isBusy)
            .help("元のテキストを訳文で置き換え（貼り付け）")
            .padding(.leading, 6)
            Spacer()
            ModelStatusLabel(statistics: session.statistics)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
