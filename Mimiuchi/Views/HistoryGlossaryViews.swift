import PlamoKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var confirmClear = false

    private var entries: [HistoryEntry] {
        guard !query.isEmpty else { return model.history.entries }
        return model.history.entries.filter {
            $0.source.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("翻訳履歴").font(.system(size: 22, weight: .bold))
                Spacer()
                TextField("検索", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("すべて削除…", role: .destructive) { confirmClear = true }
                    .disabled(model.history.entries.isEmpty)
            }
            .padding(20)
            if !model.settings.saveHistory {
                Text("履歴の保存はオフになっています（設定 > 一般）").font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            if entries.isEmpty {
                ContentUnavailableView("履歴はありません", systemImage: "clock", description: Text("翻訳したテキストはこの Mac にのみ保存されます。"))
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(entry) }
                            .contextMenu {
                                Button("翻訳画面で開く") { open(entry) }
                                Button("訳文をコピー") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.translation, forType: .string)
                                }
                                Divider()
                                Button("削除", role: .destructive) { model.history.remove([entry.id]) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("履歴")
        .confirmationDialog("履歴をすべて削除しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { model.history.removeAll() }
        }
    }

    private func open(_ entry: HistoryEntry) {
        model.selectedSection = .translator
        model.mainSession.load(text: entry.source, sourceLanguage: nil, targetLanguage: entry.targetLanguage)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(language(entry.sourceLanguage) + " → " + language(entry.targetLanguage))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brand)
                Spacer()
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(entry.source).lineLimit(2).foregroundStyle(.secondary)
            Text(entry.translation).lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    private func language(_ code: String?) -> String {
        guard let code else { return "自動" }
        return PlamoLanguage.language(code: code)?.japaneseName ?? code
    }
}

struct GlossaryView: View {
    @Environment(AppModel.self) private var model
    @State private var newSource = ""
    @State private var newTarget = ""

    var body: some View {
        @Bindable var glossary = model.glossary
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用語集").font(.system(size: 22, weight: .bold))
                    Text("登録した用語は、原文に含まれるときに PLaMo の glossary 指定として翻訳に反映されます。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("用語集を使う", isOn: $settings.glossaryEnabled)
                    .toggleStyle(.switch)
            }
            HStack {
                TextField("原文の用語（例: 管理画面）", text: $newSource).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("訳語（例: dashboard）", text: $newTarget).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("追加", action: add)
                    .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty || newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Table($glossary.terms) {
                TableColumn("原文の用語") { $term in TextField("", text: $term.source) }
                TableColumn("訳語") { $term in TextField("", text: $term.target) }
                TableColumn("") { $term in
                    Button {
                        glossary.terms.removeAll { $0.id == term.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .width(32)
            }
            .overlay {
                if glossary.terms.isEmpty {
                    ContentUnavailableView("用語が登録されていません", systemImage: "book.closed")
                }
            }
        }
        .padding(20)
        .navigationTitle("用語集")
    }

    private func add() {
        let s = newSource.trimmingCharacters(in: .whitespaces)
        let t = newTarget.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !t.isEmpty else { return }
        model.glossary.terms.append(.init(source: s, target: t))
        newSource = ""
        newTarget = ""
    }
}
