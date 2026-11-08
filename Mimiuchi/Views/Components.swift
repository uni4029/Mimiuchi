import AppKit
import PlamoKit
import SwiftUI

extension Color {
    /// Mimiuchi brand accent (deep blue).
    static let brand = Color(red: 0.05, green: 0.27, blue: 0.53)
    static let paneBackground = Color(nsColor: .textBackgroundColor)
    static let targetPaneBackground = Color(nsColor: .underPageBackgroundColor).opacity(0.35)
}

/// DeepL-style language button with a searchable grid popover.
struct LanguagePickerButton: View {
    enum Kind { case source, target }

    let kind: Kind
    /// `nil` means automatic detection (source only).
    @Binding var selection: String?
    var detected: PlamoLanguage? = nil

    @State private var showPopover = false
    @State private var query = ""

    private var title: String {
        if let code = selection, let lang = PlamoLanguage.language(code: code) { return lang.japaneseName }
        if let detected { return "\(detected.japaneseName)（検出）" }
        return "言語を検出"
    }

    private var languages: [PlamoLanguage] {
        let base = kind == .source ? PlamoLanguage.sourceLanguages : PlamoLanguage.all
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.japaneseName.localizedCaseInsensitiveContains(query)
                || $0.englishName.localizedCaseInsensitiveContains(query) || $0.code.hasPrefix(query.lowercased())
        }
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(showPopover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("言語を検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(170), alignment: .leading), count: 3), spacing: 2) {
                        if kind == .source && query.isEmpty {
                            languageCell(code: nil, name: "言語を検出", english: "Detect language")
                        }
                        ForEach(languages) { lang in
                            languageCell(code: lang.code, name: lang.japaneseName, english: lang.englishName)
                        }
                    }
                }
                .frame(height: 340)
            }
            .padding(14)
            .frame(width: 560)
        }
    }

    private func languageCell(code: String?, name: String, english: String) -> some View {
        Button {
            selection = code
            showPopover = false
            query = ""
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(selection == code ? 1 : 0)
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 13))
                    Text(english).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selection == code ? Color.brand.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Small icon button used in pane toolbars.
struct PaneIconButton: View {
    let systemImage: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.brand : .secondary)
        .help(help)
    }
}

/// Copy button with a short "copied" confirmation.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        PaneIconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "訳文をコピー", active: copied) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        }
        .disabled(text.isEmpty)
    }
}

/// Placeholder-aware, transparent text editor.
struct SourceTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 20
    @FocusState.Binding var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: fontSize))
                .scrollContentBackground(.hidden)
                .focused($focused)
        }
    }
}

/// Status line for the active model ("PLaMo 3 Translate 0.8B · 152 tok/s").
struct ModelStatusLabel: View {
    @Environment(AppModel.self) private var model
    var statistics: TranslationStatistics?

    var body: some View {
        HStack(spacing: 6) {
            switch model.models.loadState {
            case .loading:
                ProgressView().controlSize(.mini)
                Text("モデルを読み込み中…")
            case .failed(_, let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1)
            default:
                if let active = model.models.activeModel {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    Text(active.displayName)
                    if let s = statistics, s.generatedTokens > 0 {
                        Text("·")
                        Text(String(format: "%.0f tok/s", s.tokensPerSecond))
                            .monospacedDigit()
                    }
                } else {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("モデル未インストール")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// Shared help text for the ⌘C+C permissions.
enum PermissionHelp {
    static let staleSwitch = "システム設定で Mimiuchi がオンなのに未許可のままのときは、以前のビルドへの許可が残っています。「許可する…」を押すと古い許可を取り除いてから改めて許可を求めるので、もう一度オンにしてください。"
    static let relaunch = "入力監視はオンになっていますが、macOS では Mimiuchi を再起動するまで有効になりません。"
}

/// One privacy permission with its state and a button to grant it.
struct PermissionRow: View {
    let name: String
    let granted: Bool
    let purpose: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text("\(name): \(granted ? "許可済み" : "未許可")")
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Button("システム設定を開く", action: openSettings)
            } else {
                Button("許可する…", action: request)
            }
        }
    }
}
