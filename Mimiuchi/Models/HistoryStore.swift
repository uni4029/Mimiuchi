import Foundation
import Observation
import PlamoKit

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var source: String
    var translation: String
    var sourceLanguage: String?
    var targetLanguage: String
}

/// Recent translations stored locally (`Application Support/Mimiuchi/history.json`).
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let limit = 500

    init(url: URL = HistoryStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    static var defaultURL: URL {
        ModelStore.defaultRootDirectory.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    @discardableResult
    func add(source: String, translation: String, sourceLanguage: String?, targetLanguage: String) -> UUID {
        let entry = HistoryEntry(
            date: Date(), source: source, translation: translation, sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleSave()
        return entry.id
    }

    func update(id: UUID, source: String, translation: String, sourceLanguage: String?, targetLanguage: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            add(source: source, translation: translation, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            return
        }
        entries[index].source = source
        entries[index].translation = translation
        entries[index].sourceLanguage = sourceLanguage
        entries[index].targetLanguage = targetLanguage
        entries[index].date = Date()
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func removeAll() {
        entries.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let url = self.url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(snapshot).write(to: url, options: .atomic)
        }
    }
}

/// User glossary (DeepL-like). Terms are passed to PLaMo's `glossary` option.
@Observable
final class GlossaryStore {
    struct Term: Codable, Identifiable, Hashable {
        var id = UUID()
        var source: String
        var target: String
    }

    var terms: [Term] = [] { didSet { save() } }
    @ObservationIgnored private let url: URL

    init(url: URL = GlossaryStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([Term].self, from: data)
        {
            terms = decoded
        }
    }

    static var defaultURL: URL {
        ModelStore.defaultRootDirectory.deletingLastPathComponent().appendingPathComponent("glossary.json")
    }

    /// Glossary entries whose source term occurs in `text` (keeps prompts short).
    func entries(matching text: String) -> [GlossaryEntry] {
        terms.compactMap { term in
            let source = term.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty,
                text.range(of: source, options: [.caseInsensitive]) != nil
            else { return nil }
            return GlossaryEntry(source: source, target: target)
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(terms).write(to: url, options: .atomic)
    }
}
