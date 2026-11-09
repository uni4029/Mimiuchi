import AppKit
import Foundation
@_exported import MimiuchiCore
import Observation
import PlamoKit

/// Where the ⌘C+C overlay appears.
enum OverlayPlacement: String, CaseIterable, Identifiable, Codable {
    case nearSelection, nearMouse, screenCenter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nearSelection: "選択したテキストの近く"
        case .nearMouse: "マウスポインタの近く"
        case .screenCenter: "画面の中央"
        }
    }
}

enum OverlayLayout: String, CaseIterable, Identifiable, Codable {
    case vertical, horizontal
    var id: String { rawValue }
    var label: String { self == .vertical ? "上下分割" : "左右分割" }
}

/// What the ⌘C+C shortcut opens.
enum ShortcutPresentation: String, CaseIterable, Identifiable, Codable {
    case overlay, mainWindow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overlay: "オーバーレイパネル（アプリを切り替えない）"
        case .mainWindow: "メインウィンドウ"
        }
    }
}

/// Japanese politeness (PLaMo `form`), similar to DeepL's formality setting.
enum FormalityOption: String, CaseIterable, Identifiable, Codable {
    case automatic, polite, plain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "自動"
        case .polite: "です・ます調"
        case .plain: "だ・である調"
        }
    }
    var plamoForm: String? {
        switch self {
        case .automatic: nil
        case .polite: "polite"
        case .plain: "plain"
        }
    }
}

struct ExcludedApp: Codable, Hashable, Identifiable, Sendable {
    var bundleIdentifier: String
    var name: String
    var id: String { bundleIdentifier }
}

/// User preferences persisted in `UserDefaults`.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var doubleCopyEnabled: Bool { didSet { defaults.set(doubleCopyEnabled, forKey: Keys.doubleCopyEnabled) } }
    var shortcut: DoublePressShortcut { didSet { save(shortcut, Keys.shortcut) } }
    /// Maximum time between the two key presses.
    var doublePressInterval: Double { didSet { defaults.set(doublePressInterval, forKey: Keys.doublePressInterval) } }
    var shortcutPresentation: ShortcutPresentation { didSet { defaults.set(shortcutPresentation.rawValue, forKey: Keys.presentation) } }
    var overlayPlacement: OverlayPlacement { didSet { defaults.set(overlayPlacement.rawValue, forKey: Keys.placement) } }
    var overlayShowsSource: Bool { didSet { defaults.set(overlayShowsSource, forKey: Keys.overlayShowsSource) } }
    var overlayLayout: OverlayLayout { didSet { defaults.set(overlayLayout.rawValue, forKey: Keys.overlayLayout) } }
    var overlayScrollSync: Bool { didSet { defaults.set(overlayScrollSync, forKey: Keys.overlayScrollSync) } }
    var mainScrollSync: Bool { didSet { defaults.set(mainScrollSync, forKey: Keys.mainScrollSync) } }
    var excludedApps: [ExcludedApp] { didSet { save(excludedApps, Keys.excludedApps) } }

    /// Default target language.
    var primaryLanguage: String { didSet { defaults.set(primaryLanguage, forKey: Keys.primaryLanguage) } }
    /// Used when the source text is already in the primary language.
    var secondaryLanguage: String { didSet { defaults.set(secondaryLanguage, forKey: Keys.secondaryLanguage) } }
    var formality: FormalityOption { didSet { defaults.set(formality.rawValue, forKey: Keys.formality) } }
    var translateWhileTyping: Bool { didSet { defaults.set(translateWhileTyping, forKey: Keys.translateWhileTyping) } }

    var selectedModelId: String { didSet { defaults.set(selectedModelId, forKey: Keys.selectedModel) } }
    /// Unload the model from memory after this many idle minutes (0 = keep loaded).
    var unloadAfterIdleMinutes: Int { didSet { defaults.set(unloadAfterIdleMinutes, forKey: Keys.unloadIdle) } }
    var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) } }
    var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: Keys.saveHistory) } }
    var glossaryEnabled: Bool { didSet { defaults.set(glossaryEnabled, forKey: Keys.glossaryEnabled) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    /// SHA-256 of the Terms of Use the user agreed to (see `TermsOfUse`); empty = never agreed.
    var acceptedTermsHash: String { didSet { defaults.set(acceptedTermsHash, forKey: Keys.acceptedTermsHash) } }
    var termsAcceptedAt: Date? { didSet { defaults.set(termsAcceptedAt, forKey: Keys.termsAcceptedAt) } }

    /// Nothing is downloaded, loaded or translated until this is true. Without the bundled terms
    /// file nobody can agree, so the app stays locked.
    var hasAcceptedCurrentTerms: Bool {
        guard let terms = TermsOfUse.current else { return false }
        return acceptedTermsHash == terms.hash
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.doubleCopyEnabled: true,
            Keys.doublePressInterval: 0.5,
            Keys.primaryLanguage: "ja",
            Keys.secondaryLanguage: "en",
            Keys.translateWhileTyping: true,
            Keys.selectedModel: PlamoModelCatalog.defaultModel.id,
            Keys.unloadIdle: 0,
            Keys.showDockIcon: true,
            Keys.saveHistory: true,
            Keys.glossaryEnabled: false,
            Keys.overlayShowsSource: true,
        ])
        doubleCopyEnabled = defaults.bool(forKey: Keys.doubleCopyEnabled)
        shortcut = Self.load(DoublePressShortcut.self, Keys.shortcut, defaults) ?? .commandC
        doublePressInterval = defaults.double(forKey: Keys.doublePressInterval)
        shortcutPresentation = ShortcutPresentation(rawValue: defaults.string(forKey: Keys.presentation) ?? "") ?? .overlay
        overlayPlacement = OverlayPlacement(rawValue: defaults.string(forKey: Keys.placement) ?? "") ?? .nearSelection
        overlayShowsSource = defaults.bool(forKey: Keys.overlayShowsSource)
        overlayLayout = OverlayLayout(rawValue: defaults.string(forKey: Keys.overlayLayout) ?? "") ?? .vertical
        overlayScrollSync = defaults.bool(forKey: Keys.overlayScrollSync)
        mainScrollSync = defaults.bool(forKey: Keys.mainScrollSync)
        excludedApps = Self.load([ExcludedApp].self, Keys.excludedApps, defaults) ?? []
        primaryLanguage = defaults.string(forKey: Keys.primaryLanguage) ?? "ja"
        secondaryLanguage = defaults.string(forKey: Keys.secondaryLanguage) ?? "en"
        formality = FormalityOption(rawValue: defaults.string(forKey: Keys.formality) ?? "") ?? .automatic
        translateWhileTyping = defaults.bool(forKey: Keys.translateWhileTyping)
        selectedModelId = defaults.string(forKey: Keys.selectedModel) ?? PlamoModelCatalog.defaultModel.id
        unloadAfterIdleMinutes = defaults.integer(forKey: Keys.unloadIdle)
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        saveHistory = defaults.bool(forKey: Keys.saveHistory)
        glossaryEnabled = defaults.bool(forKey: Keys.glossaryEnabled)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        acceptedTermsHash = defaults.string(forKey: Keys.acceptedTermsHash) ?? ""
        termsAcceptedAt = defaults.object(forKey: Keys.termsAcceptedAt) as? Date
    }

    /// Target language for text in `detected` language (DeepL-like automatic switch).
    func preferredTarget(forDetected detected: String?) -> String {
        LanguageRouting.preferredTarget(detected: detected, primary: primaryLanguage, secondary: secondaryLanguage)
    }

    func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Keys {
        static let doubleCopyEnabled = "doubleCopyEnabled"
        static let shortcut = "doublePressShortcut"
        static let doublePressInterval = "doublePressInterval"
        static let presentation = "shortcutPresentation"
        static let placement = "overlayPlacement"
        static let overlayShowsSource = "overlayShowsSource"
        static let overlayLayout = "overlayLayout"
        static let overlayScrollSync = "overlayScrollSync"
        static let mainScrollSync = "mainScrollSync"
        static let excludedApps = "excludedApps"
        static let primaryLanguage = "primaryLanguage"
        static let secondaryLanguage = "secondaryLanguage"
        static let formality = "formality"
        static let translateWhileTyping = "translateWhileTyping"
        static let selectedModel = "selectedModelId"
        static let unloadIdle = "unloadAfterIdleMinutes"
        static let showDockIcon = "showDockIcon"
        static let saveHistory = "saveHistory"
        static let glossaryEnabled = "glossaryEnabled"
        static let onboarding = "hasCompletedOnboarding"
        static let acceptedTermsHash = "acceptedTermsHash"
        static let termsAcceptedAt = "termsAcceptedAt"
    }
}
