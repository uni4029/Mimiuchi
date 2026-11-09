import Foundation
import NaturalLanguage
import Observation
import PlamoKit

/// Detects the language of a text with Apple's NaturalLanguage framework.
enum LanguageDetector {
    static func detect(_ text: String) -> PlamoLanguage? {
        let sample = String(text.prefix(600))
        guard sample.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return nil }
        // Kana is unambiguous evidence of Japanese (NL sometimes picks Chinese for kanji-heavy text).
        if sample.unicodeScalars.contains(where: { (0x3040 ... 0x30FF).contains($0.value) }) {
            return .japanese
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
            confidence >= 0.3
        else { return nil }
        return PlamoLanguage.matching(bcp47: language.rawValue)
    }
}

/// State of one translator surface (the main window or the overlay panel).
@Observable
final class TranslationSession {
    enum Phase: Equatable {
        case idle, loadingModel, translating, finished, failed(String)
    }

    var sourceText = "" {
        didSet {
            guard sourceText != oldValue else { return }
            sourceChanged()
        }
    }
    private(set) var translatedText = ""
    /// Changes when a different document is opened, so both panes reset their scroll position.
    private(set) var documentID = UUID()
    /// `nil` = automatic detection.
    var sourceLanguage: String? { didSet { if sourceLanguage != oldValue { retranslate() } } }
    var targetLanguage: String { didSet { if targetLanguage != oldValue { userPickedTarget = true; retranslate() } } }
    var formality: FormalityOption { didSet { if formality != oldValue { retranslate() } } }
    var context = "" { didSet { if context != oldValue { scheduleTranslation(delay: 0.8) } } }

    private(set) var detectedLanguage: PlamoLanguage?
    private(set) var phase: Phase = .idle
    private(set) var statistics: TranslationStatistics?
    private(set) var translatedModelLabel: String?

    /// Translate automatically while the user types.
    var translateWhileTyping = true
    /// Record finished translations in the history.
    var recordsHistory = true

    @ObservationIgnored let models: ModelManager
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored let glossary: GlossaryStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var userPickedTarget = false
    @ObservationIgnored private var suppressAutoTarget = false
    @ObservationIgnored private var historyEntryID: UUID?
    @ObservationIgnored private var historyEntryDate = Date.distantPast
    @ObservationIgnored private var lastRequest: TranslationRequest?

    init(models: ModelManager, settings: AppSettings, history: HistoryStore, glossary: GlossaryStore) {
        self.models = models
        self.settings = settings
        self.history = history
        self.glossary = glossary
        self.targetLanguage = settings.primaryLanguage
        self.formality = settings.formality
    }

    var isBusy: Bool { phase == .translating || phase == .loadingModel }

    var effectiveSourceLanguage: PlamoLanguage? {
        if let code = sourceLanguage { return PlamoLanguage.language(code: code) }
        return detectedLanguage
    }

    /// Replaces the whole content (used by ⌘C+C and history), translating immediately.
    func load(text: String, sourceLanguage: String? = nil, targetLanguage: String? = nil) {
        documentID = UUID()
        task?.cancel()
        debounce?.cancel()
        suppressAutoTarget = true
        self.sourceLanguage = sourceLanguage
        if let targetLanguage {
            self.targetLanguage = targetLanguage
            userPickedTarget = true
        } else {
            userPickedTarget = false
        }
        suppressAutoTarget = false
        historyEntryID = nil
        sourceText = text
        translateNow()
    }

    func clear() {
        documentID = UUID()
        task?.cancel()
        debounce?.cancel()
        sourceText = ""
        translatedText = ""
        detectedLanguage = nil
        statistics = nil
        phase = .idle
        userPickedTarget = false
        historyEntryID = nil
        lastRequest = nil
    }

    func swapLanguages() {
        guard let source = effectiveSourceLanguage, source.code != targetLanguage,
            PlamoLanguage.language(code: targetLanguage)?.targetOnly == false
        else { return }
        let newSource = targetLanguage
        let newText = translatedText
        documentID = UUID()
        task?.cancel()
        debounce?.cancel()
        suppressAutoTarget = true
        sourceLanguage = newSource
        targetLanguage = source.code
        suppressAutoTarget = false
        if !newText.isEmpty {
            historyEntryID = nil
            sourceText = newText
        }
        translateNow()
    }

    func cancel() {
        task?.cancel()
        debounce?.cancel()
        if isBusy { phase = translatedText.isEmpty ? .idle : .finished }
    }

    func retranslate() {
        guard !suppressAutoTarget else { return }
        lastRequest = nil
        scheduleTranslation(delay: 0.05)
    }

    private func sourceChanged() {
        updateDetection()
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task?.cancel()
            debounce?.cancel()
            translatedText = ""
            statistics = nil
            phase = .idle
            lastRequest = nil
            return
        }
        if translateWhileTyping {
            scheduleTranslation(delay: 0.45)
        }
    }

    private func updateDetection() {
        detectedLanguage = LanguageDetector.detect(sourceText)
        // DeepL-like behaviour: if the text is already in the target language, switch targets.
        if sourceLanguage == nil, !userPickedTarget || detectedLanguage?.code == targetLanguage {
            let preferred = settings.preferredTarget(forDetected: detectedLanguage?.code)
            if preferred != targetLanguage, detectedLanguage != nil {
                suppressAutoTarget = true
                targetLanguage = preferred
                userPickedTarget = false
                suppressAutoTarget = false
            }
        }
    }

    func scheduleTranslation(delay: TimeInterval) {
        debounce?.cancel()
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    func makeRequest() -> TranslationRequest {
        let target = targetLanguage
        let form = target == "ja" ? formality.plamoForm : nil
        let terms = settings.glossaryEnabled ? glossary.entries(matching: sourceText) : []
        return TranslationRequest(
            text: sourceText, sourceLanguage: sourceLanguage, targetLanguage: target, form: form,
            context: context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : context,
            glossary: terms)
    }

    func translateNow() {
        debounce?.cancel()
        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = makeRequest()
        if request == lastRequest, phase == .finished || phase == .translating { return }
        lastRequest = request
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(request)
        }
    }

    private func run(_ request: TranslationRequest) async {
        let wasEmpty = translatedText.isEmpty
        if models.loadedModelId == nil { phase = .loadingModel } else { phase = .translating }
        do {
            let translator = try await models.translatorForUse()
            try Task.checkCancellation()
            phase = .translating
            var output = ""
            var first = true
            for try await event in translator.translate(request) {
                try Task.checkCancellation()
                switch event {
                case .prefilled:
                    break
                case .text(let chunk):
                    output += chunk
                    if first {
                        first = false
                    }
                    translatedText = output
                case .finished(let stats):
                    statistics = stats
                }
            }
            try Task.checkCancellation()
            translatedText = output
            translatedModelLabel = models.activeModel?.sizeLabel
            phase = .finished
            recordHistory(request: request, translation: output)
        } catch is CancellationError {
            // A newer request replaced this one.
        } catch {
            if wasEmpty { translatedText = "" }
            phase = .failed(error.localizedDescription)
            lastRequest = nil
        }
    }

    private func recordHistory(request: TranslationRequest, translation: String) {
        guard recordsHistory, settings.saveHistory, !translation.isEmpty else { return }
        let source = detectedLanguage?.code ?? request.sourceLanguage
        // Typing continues the same entry for a while instead of creating many entries.
        if let id = historyEntryID, Date().timeIntervalSince(historyEntryDate) < 90 {
            history.update(id: id, source: request.text, translation: translation, sourceLanguage: source, targetLanguage: request.targetLanguage)
        } else {
            historyEntryID = history.add(source: request.text, translation: translation, sourceLanguage: source, targetLanguage: request.targetLanguage)
        }
        historyEntryDate = Date()
    }
}
