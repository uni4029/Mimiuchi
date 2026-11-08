import PlamoKit
import SwiftUI
import UniformTypeIdentifiers

/// DeepL-style two-pane translator.
struct TranslatorView: View {
    @Bindable var session: TranslationSession
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .text

    enum Mode: String, CaseIterable, Identifiable {
        case text, file
        var id: String { rawValue }
        var title: String { self == .text ? "テキスト翻訳" : "ファイル翻訳" }
        var symbol: String { self == .text ? "textformat" : "doc.text" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Mode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        Label(m.title, systemImage: m.symbol)
                            .font(.system(size: 13, weight: mode == m ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(mode == m ? Color.brand : .secondary)
                            .background(mode == m ? Color.brand.opacity(0.1) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            switch mode {
            case .text: TextTranslatorPanel(session: session)
            case .file: FileTranslatorPanel()
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .navigationTitle("翻訳")
    }
}

struct TextTranslatorPanel: View {
    @Bindable var session: TranslationSession
    @Environment(AppModel.self) private var model
    @FocusState private var editorFocused: Bool
    @State private var showContext = false

    var body: some View {
        VStack(spacing: 10) {
            languageBar
            HStack(spacing: 0) {
                sourcePane
                Divider()
                targetPane
            }
            .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
            if showContext {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary).padding(.top, 3)
                    TextField("コンテキスト（例: 社内向けの丁寧なメール、医療文書 など）", text: $session.context, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 3)
                    Button("クリア") { session.context = "" }
                        .buttonStyle(.link)
                        .disabled(session.context.isEmpty)
                }
                .padding(10)
                .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            }
        }
        .onAppear { editorFocused = true }
    }

    // MARK: Language bar

    private var languageBar: some View {
        HStack(spacing: 6) {
            HStack {
                LanguagePickerButton(kind: .source, selection: $session.sourceLanguage, detected: session.detectedLanguage)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            Button {
                session.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.effectiveSourceLanguage == nil ? .tertiary : .secondary)
            .disabled(session.effectiveSourceLanguage == nil)
            .help("原文と訳文の言語を入れ替え")

            HStack(spacing: 8) {
                LanguagePickerButton(
                    kind: .target,
                    selection: Binding(get: { session.targetLanguage }, set: { session.targetLanguage = $0 ?? model.settings.primaryLanguage }))
                Spacer(minLength: 0)
                if session.targetLanguage == "ja" {
                    Picker(selection: $session.formality) {
                        ForEach(FormalityOption.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("文体（です・ます調 / だ・である調）")
                }
                glossaryToggle
                PaneIconButton(systemImage: "text.bubble", help: "コンテキストを追加", active: showContext || !session.context.isEmpty) {
                    showContext.toggle()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var glossaryToggle: some View {
        let count = model.glossary.terms.count
        return Button {
            model.settings.glossaryEnabled.toggle()
            session.retranslate()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "book.closed")
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(model.settings.glossaryEnabled ? Color.brand : .secondary)
            .background(model.settings.glossaryEnabled ? Color.brand.opacity(0.1) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.settings.glossaryEnabled ? "用語集: オン" : "用語集: オフ")
        .contextMenu {
            Button("用語集を編集…") { model.selectedSection = .glossary }
        }
    }

    // MARK: Panes

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                SourceTextEditor(
                    text: $session.sourceText,
                    placeholder: "翻訳するには、テキストを入力するか貼り付けてください。\n\n\(model.settings.shortcut.displayString) で、どのアプリからでも翻訳できます。",
                    focused: $editorFocused)
                    .padding(.leading, 14)
                    .padding(.trailing, 34)
                    .padding(.top, 14)
                if !session.sourceText.isEmpty {
                    PaneIconButton(systemImage: "xmark", help: "クリア") {
                        session.clear()
                        editorFocused = true
                    }
                    .padding(8)
                }
            }
            HStack(spacing: 8) {
                if let detected = session.detectedLanguage, session.sourceLanguage == nil {
                    Text("検出: \(detected.japaneseName)")
                }
                Spacer()
                PaneIconButton(systemImage: "doc.on.clipboard", help: "クリップボードから貼り付け") {
                    if let text = NSPasteboard.general.string(forType: .string) { session.sourceText = text }
                }
                Text("\(session.sourceText.count) 文字").monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var targetPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if case .failed(let message) = session.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 13))
                        if !model.models.hasInstalledModel {
                            Button("モデルストアを開く") { model.selectedSection = .models }
                        }
                    }
                    if session.translatedText.isEmpty {
                        Text(session.isBusy ? (session.phase == .loadingModel ? "モデルを読み込み中…" : "翻訳中…") : "翻訳")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(session.translatedText)
                            .font(.system(size: 20))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 19)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                if session.isBusy {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                ModelStatusLabel(statistics: session.statistics)
                Spacer()
                PaneIconButton(systemImage: "speaker.wave.2", help: "読み上げ") {
                    model.speech.speak(session.translatedText, languageCode: session.targetLanguage)
                }
                .disabled(session.translatedText.isEmpty)
                CopyButton(text: session.translatedText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.targetPaneBackground)
    }
}

/// Plain-text file translation (paragraph by paragraph with translation history).
struct FileTranslatorPanel: View {
    @Environment(AppModel.self) private var model
    @State private var fileURL: URL?
    @State private var paragraphs: [String] = []
    @State private var translations: [String] = []
    @State private var running = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var targetLanguage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                LanguagePickerButton(kind: .target, selection: $targetLanguage)
                Spacer()
                if running {
                    Button("中止") { task?.cancel() }
                }
                Button("ファイルを選択…") { chooseFile() }
                    .disabled(running)
                Button("訳文を保存…") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || translations.isEmpty)
            }
            if paragraphs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.arrow.up").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("テキストファイル（.txt / .md）を翻訳").font(.title3.weight(.semibold))
                    Text("段落ごとに、前の段落の訳文を文脈として参照しながら翻訳します。")
                        .foregroundStyle(.secondary)
                    Button("ファイルを選択…") { chooseFile() }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in load(url) } }
                    }
                    return true
                }
            } else {
                if let fileURL {
                    HStack {
                        Image(systemName: "doc.text")
                        Text(fileURL.lastPathComponent).fontWeight(.medium)
                        Text("\(paragraphs.count) 段落").foregroundStyle(.secondary)
                        Spacer()
                        if running || !translations.isEmpty {
                            ProgressView(value: Double(translations.count), total: Double(max(paragraphs.count, 1)))
                                .frame(width: 180)
                            Text("\(translations.count)/\(paragraphs.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(paragraphs.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 16) {
                                Text(paragraphs[i]).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary)
                                Text(i < translations.count ? translations[i] : "…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            Divider()
                        }
                    }
                    .padding(14)
                }
                .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .onAppear { if targetLanguage == nil { targetLanguage = model.settings.primaryLanguage } }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "ファイルを読み込めませんでした（UTF-8 のテキストのみ対応）"
            return
        }
        fileURL = url
        errorMessage = nil
        translations = []
        paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        start()
    }

    private func start() {
        task?.cancel()
        running = true
        let target = targetLanguage ?? model.settings.primaryLanguage
        let paragraphs = self.paragraphs
        task = Task {
            defer { running = false }
            do {
                let translator = try await model.models.translatorForUse()
                var history: [TranslationTurn] = []
                for paragraph in paragraphs {
                    try Task.checkCancellation()
                    let request = TranslationRequest(text: paragraph, targetLanguage: target, history: Array(history.suffix(2)))
                    let (output, _) = try await translator.translateText(request)
                    translations.append(output)
                    history.append(TranslationTurn(source: paragraph, translation: output))
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let fileURL else { return }
        let panel = NSSavePanel()
        let target = targetLanguage ?? "out"
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "_\(target)." + (fileURL.pathExtension.isEmpty ? "txt" : fileURL.pathExtension)
        if panel.runModal() == .OK, let url = panel.url {
            try? translations.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
