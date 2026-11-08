import Foundation
import Observation
import PlamoKit

/// Tracks installed models, downloads, the selected model and the loaded translator.
@Observable
final class ModelManager {
    enum InstallState: Equatable {
        case notInstalled
        case downloading(ModelDownloadProgress)
        case installed(diskBytes: Int64)
        case failed(String)

        var isInstalled: Bool { if case .installed = self { true } else { false } }
        var isDownloading: Bool { if case .downloading = self { true } else { false } }
    }

    enum LoadState: Equatable {
        case unloaded
        case loading(modelId: String)
        case loaded(modelId: String)
        case failed(modelId: String, message: String)
    }

    let store: ModelStore
    let settings: AppSettings
    private(set) var installStates: [String: InstallState] = [:]
    private(set) var loadState: LoadState = .unloaded
    private(set) var availableDiskBytes: Int64 = 0

    @ObservationIgnored private var translator: PlamoTranslator?
    @ObservationIgnored private var loadingTask: Task<PlamoTranslator, Error>?
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var lastUse = Date()

    init(settings: AppSettings, store: ModelStore = ModelStore()) {
        self.settings = settings
        self.store = store
        refresh()
    }

    var models: [PlamoModelDescriptor] { PlamoModelCatalog.all }
    var installedModels: [PlamoModelDescriptor] { models.filter { state(for: $0).isInstalled } }

    var selectedModel: PlamoModelDescriptor {
        PlamoModelCatalog.descriptor(id: settings.selectedModelId) ?? PlamoModelCatalog.defaultModel
    }

    /// The selected model if it is installed, otherwise the first installed model.
    var activeModel: PlamoModelDescriptor? {
        if state(for: selectedModel).isInstalled { return selectedModel }
        return installedModels.first
    }

    var hasInstalledModel: Bool { !installedModels.isEmpty }

    func state(for model: PlamoModelDescriptor) -> InstallState {
        installStates[model.id] ?? .notInstalled
    }

    var isLoading: Bool { if case .loading = loadState { true } else { false } }

    func refresh() {
        for model in models where !(installStates[model.id]?.isDownloading ?? false) {
            installStates[model.id] =
                store.isInstalled(model) ? .installed(diskBytes: store.diskUsage(for: model)) : .notInstalled
        }
        availableDiskBytes = store.availableDiskSpace()
    }

    // MARK: Download / delete

    func download(_ model: PlamoModelDescriptor) {
        guard downloadTasks[model.id] == nil else { return }
        // Downloading the model means agreeing to the PLaMo Community License (Terms of Use, Article 2).
        guard settings.hasAcceptedCurrentTerms else {
            installStates[model.id] = .failed(ModelManagerError.termsNotAccepted.localizedDescription)
            return
        }
        installStates[model.id] = .downloading(
            ModelDownloadProgress(completedBytes: 0, totalBytes: model.downloadBytes, currentFile: "", bytesPerSecond: 0, phase: .listing))
        let store = self.store
        let ref = WeakReference(self)
        downloadTasks[model.id] = Task { [weak self] in
            do {
                try await store.download(model) { progress in
                    Task { @MainActor in
                        guard let manager = ref.value, manager.installStates[model.id]?.isDownloading == true else { return }
                        manager.installStates[model.id] = .downloading(progress)
                    }
                }
                guard let self else { return }
                self.downloadTasks[model.id] = nil
                self.installStates[model.id] = .installed(diskBytes: store.diskUsage(for: model))
                self.availableDiskBytes = store.availableDiskSpace()
                // First installed model becomes the selection automatically.
                if !self.state(for: self.selectedModel).isInstalled {
                    self.select(model)
                }
            } catch {
                guard let self else { return }
                self.downloadTasks[model.id] = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.installStates[model.id] = .notInstalled
                } else {
                    self.installStates[model.id] = .failed(error.localizedDescription)
                }
                self.availableDiskBytes = store.availableDiskSpace()
            }
        }
    }

    func cancelDownload(_ model: PlamoModelDescriptor) {
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        installStates[model.id] = .notInstalled
    }

    func delete(_ model: PlamoModelDescriptor) throws {
        cancelDownload(model)
        if loadedModelId == model.id { unload() }
        try store.delete(model)
        refresh()
        if settings.selectedModelId == model.id, let other = installedModels.first {
            settings.selectedModelId = other.id
        }
    }

    // MARK: Selection / loading

    var loadedModelId: String? {
        if case .loaded(let id) = loadState { return id }
        return nil
    }

    func select(_ model: PlamoModelDescriptor) {
        settings.selectedModelId = model.id
        if state(for: model).isInstalled, loadedModelId != model.id {
            preload()
        }
    }

    /// Loads the active model in the background (no-op if it is already loaded).
    func preload() {
        Task { _ = try? await self.translatorForUse() }
    }

    func unload() {
        loadingTask?.cancel()
        loadingTask = nil
        translator = nil
        loadState = .unloaded
    }

    /// Returns a translator for the active model, loading it if necessary.
    func translatorForUse() async throws -> PlamoTranslator {
        guard settings.hasAcceptedCurrentTerms else { throw ModelManagerError.termsNotAccepted }
        guard let model = activeModel else { throw ModelManagerError.noModelInstalled }
        lastUse = Date()
        scheduleIdleUnload()
        if let translator, loadedModelId == model.id { return translator }
        if let loadingTask, case .loading(let id) = loadState, id == model.id {
            return try await loadingTask.value
        }

        translator = nil
        loadState = .loading(modelId: model.id)
        let directory = store.directory(for: model)
        let task = Task.detached(priority: .userInitiated) {
            try PlamoTranslator(modelDirectory: directory)
        }
        loadingTask = task
        do {
            let loaded = try await task.value
            guard case .loading(let id) = loadState, id == model.id else { throw CancellationError() }
            translator = loaded
            loadingTask = nil
            loadState = .loaded(modelId: model.id)
            return loaded
        } catch {
            loadingTask = nil
            if !(error is CancellationError) {
                loadState = .failed(modelId: model.id, message: error.localizedDescription)
            }
            throw error
        }
    }

    private func scheduleIdleUnload() {
        idleTimer?.invalidate()
        let minutes = settings.unloadAfterIdleMinutes
        guard minutes > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastUse) >= TimeInterval(minutes * 60) - 1 else { return }
                self.unload()
            }
        }
    }
}

/// Sendable weak box used to reach a main-actor object from background callbacks.
final class WeakReference<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

enum ModelManagerError: LocalizedError {
    case noModelInstalled
    case termsNotAccepted

    var errorDescription: String? {
        switch self {
        case .noModelInstalled: "翻訳モデルがインストールされていません。モデルストアからダウンロードしてください。"
        case .termsNotAccepted: "Mimiuchi を使うには、利用規約と PLaMo Community License への同意が必要です。"
        }
    }
}
