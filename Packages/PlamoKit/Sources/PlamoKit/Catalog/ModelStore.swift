import CryptoKit
import Foundation

/// Progress of a model download.
public struct ModelDownloadProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var currentFile: String
    public var bytesPerSecond: Double
    public var phase: Phase

    public enum Phase: String, Sendable { case listing, downloading, verifying, finished }

    public init(completedBytes: Int64, totalBytes: Int64, currentFile: String, bytesPerSecond: Double, phase: Phase) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentFile = currentFile
        self.bytesPerSecond = bytesPerSecond
        self.phase = phase
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

public enum ModelStoreError: LocalizedError, Sendable {
    case http(status: Int, url: String)
    case checksumMismatch(file: String)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidListing

    public var errorDescription: String? {
        switch self {
        case .http(let status, let url): return "ダウンロードに失敗しました (HTTP \(status)): \(url)"
        case .checksumMismatch(let f): return "ファイルの検証に失敗しました: \(f)"
        case .sizeMismatch(let f, let e, let a): return "ファイルサイズが一致しません: \(f) (\(a) / \(e) bytes)"
        case .insufficientDiskSpace(let r, let a):
            let fmt = ByteCountFormatter()
            return "ディスクの空き容量が不足しています（必要: \(fmt.string(fromByteCount: r)) / 空き: \(fmt.string(fromByteCount: a))）"
        case .invalidListing: return "モデルのファイル一覧を取得できませんでした"
        }
    }
}

/// Information recorded when a model finished downloading.
public struct InstalledModelManifest: Codable, Sendable {
    public var modelId: String
    public var files: [String: Int64]
    public var installedAt: Date
}

/// Manages model files on disk (download from Hugging Face, verification, deletion).
public final class ModelStore: Sendable {
    public let rootDirectory: URL
    static let manifestName = ".plamo-installed.json"

    public init(rootDirectory: URL = ModelStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    /// `~/Library/Application Support/Mimiuchi/Models`
    public static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimiuchi/Models", isDirectory: true)
    }

    public func directory(for model: PlamoModelDescriptor) -> URL {
        rootDirectory.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    public func manifest(for model: PlamoModelDescriptor) -> InstalledModelManifest? {
        let url = directory(for: model).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledModelManifest.self, from: data)
    }

    public func isInstalled(_ model: PlamoModelDescriptor) -> Bool {
        manifest(for: model) != nil
    }

    /// Bytes used on disk by a model directory (including partial downloads).
    public func diskUsage(for model: PlamoModelDescriptor) -> Int64 {
        let dir = directory(for: model)
        guard
            let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    public func availableDiskSpace() -> Int64 {
        let probe = FileManager.default.fileExists(atPath: rootDirectory.path)
            ? rootDirectory : FileManager.default.homeDirectoryForCurrentUser
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public func delete(_ model: PlamoModelDescriptor) throws {
        let dir = directory(for: model)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Download

    struct RemoteFile: Sendable {
        var path: String
        var size: Int64
        var sha256: String?
    }

    /// Files needed for inference (skips figures and Python code).
    static func isNeeded(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if path.hasPrefix("figures/") || name.hasSuffix(".py") || name == ".gitattributes" { return false }
        if name.hasSuffix(".safetensors") { return true }
        let wanted: Set<String> = [
            "config.json", "generation_config.json", "tokenizer.jsonl", "tokenizer_config.json",
            "special_tokens_map.json", "model.safetensors.index.json", "chat_template.jinja",
            "README.md", "README_ja.md", "LICENSE.mlx-lm",
        ]
        return wanted.contains(name) || path.hasPrefix("LICENSE/")
    }

    func listFiles(_ model: PlamoModelDescriptor, session: URLSession) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(model.id)/tree/main?recursive=true")!
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ModelStoreError.http(status: http.statusCode, url: url.absoluteString)
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ModelStoreError.invalidListing
        }
        let files = items.compactMap { item -> RemoteFile? in
            guard item["type"] as? String == "file", let path = item["path"] as? String,
                Self.isNeeded(path)
            else { return nil }
            let lfs = item["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber ?? item["size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(path: path, size: size, sha256: lfs?["oid"] as? String)
        }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }),
            files.contains(where: { $0.path == "config.json" })
        else { throw ModelStoreError.invalidListing }
        return files
    }

    static let userAgent = "Mimiuchi/1.0 (macOS; PLaMo model store)"

    /// Downloads (or resumes at file granularity) a model. Already complete files are kept.
    public func download(
        _ model: PlamoModelDescriptor,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }
        progress(.init(completedBytes: 0, totalBytes: model.downloadBytes, currentFile: "", bytesPerSecond: 0, phase: .listing))
        let files = try await listFiles(model, session: session)
        let dir = directory(for: model)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent(Self.manifestName)
        try? FileManager.default.removeItem(at: manifestURL)

        let total = files.reduce(0) { $0 + $1.size }
        func existingSize(_ file: RemoteFile) -> Int64? {
            let url = dir.appendingPathComponent(file.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = (attrs[.size] as? NSNumber)?.int64Value
            else { return nil }
            return size
        }
        let pending = files.filter { existingSize($0) != $0.size }
        let remaining = pending.reduce(0) { $0 + $1.size }
        let available = availableDiskSpace()
        if remaining + 200_000_000 > available {
            throw ModelStoreError.insufficientDiskSpace(required: remaining, available: available)
        }

        var completed = total - remaining
        let started = Date()
        var downloadedThisSession: Int64 = 0
        for file in pending {
            try Task.checkCancellation()
            let destination = dir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completed
            let baseSession = downloadedThisSession
            try await FileDownloader.download(
                from: Self.resolveURL(model: model, path: file.path), to: destination, session: session
            ) { written in
                let elapsed = max(0.001, Date().timeIntervalSince(started))
                progress(.init(
                    completedBytes: base + written, totalBytes: total, currentFile: file.path,
                    bytesPerSecond: Double(baseSession + written) / elapsed, phase: .downloading))
            }
            let actual = existingSize(file) ?? -1
            if file.size > 0 && actual != file.size {
                try? FileManager.default.removeItem(at: destination)
                throw ModelStoreError.sizeMismatch(file: file.path, expected: file.size, actual: actual)
            }
            if let sha = file.sha256 {
                progress(.init(completedBytes: base + file.size, totalBytes: total, currentFile: file.path, bytesPerSecond: 0, phase: .verifying))
                let digest = try await Task.detached(priority: .utility) {
                    try Self.sha256(of: destination)
                }.value
                if digest != sha.lowercased() {
                    try? FileManager.default.removeItem(at: destination)
                    throw ModelStoreError.checksumMismatch(file: file.path)
                }
            }
            completed += file.size
            downloadedThisSession += file.size
        }

        let manifest = InstalledModelManifest(
            modelId: model.id,
            files: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) }),
            installedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)
        progress(.init(completedBytes: total, totalBytes: total, currentFile: "", bytesPerSecond: 0, phase: .finished))
    }

    static func resolveURL(model: PlamoModelDescriptor, path: String) -> URL {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(model.id)/resolve/main/\(encoded)")!
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession download task bridged to async/await with byte-level progress.
enum FileDownloader {
    static func download(
        from url: URL, to destination: URL, session: URLSession,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = Delegate(destination: destination, progress: progress)
        var request = URLRequest(url: url)
        request.setValue(ModelStore.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?
        private var lastReport = Date.distantPast

        init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func setContinuation(_ c: CheckedContinuation<Void, Error>) {
            lock.withLock { continuation = c }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            let now = Date()
            let shouldReport = lock.withLock { () -> Bool in
                if now.timeIntervalSince(lastReport) < 0.1 { return false }
                lastReport = now
                return true
            }
            if shouldReport { progress(totalBytesWritten) }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                lock.withLock {
                    failure = ModelStoreError.http(
                        status: http.statusCode, url: downloadTask.originalRequest?.url?.absoluteString ?? "")
                }
                return
            }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
            } catch {
                lock.withLock { failure = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (c, stored) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
                defer { continuation = nil }
                return (continuation, failure)
            }
            if let error = error ?? stored {
                c?.resume(throwing: error)
            } else {
                progress(task.countOfBytesReceived)
                c?.resume()
            }
        }
    }
}
