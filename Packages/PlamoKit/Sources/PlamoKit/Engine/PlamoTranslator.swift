// The generation loop follows mlx-lm's `generate_step` (Copyright © 2023 Apple Inc., MIT License;
// Licenses/mlx-lm.txt). Prompts use PLaMo's PFML3 format (see PFML3Prompt.swift).

import Foundation
import MLX
import MLXNN
@_exported import PlamoTokenizer

/// A translation request (maps to PLaMo's PFML3 translation options).
public struct TranslationRequest: Sendable, Equatable {
    public var text: String
    /// Source language code (`nil` = let the model detect it).
    public var sourceLanguage: String?
    /// Target language code, e.g. `ja`, `en`, `zh-hans`, `ja-easy`.
    public var targetLanguage: String
    /// `polite` / `plain` (only valid when the target is `ja`).
    public var form: String?
    public var context: String?
    public var glossary: [GlossaryEntry]
    public var history: [TranslationTurn]
    /// Upper bound for generated tokens (`nil` = derived from the input length).
    public var maxTokens: Int?

    public init(
        text: String, sourceLanguage: String? = nil, targetLanguage: String, form: String? = nil,
        context: String? = nil, glossary: [GlossaryEntry] = [], history: [TranslationTurn] = [],
        maxTokens: Int? = nil
    ) {
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.form = form
        self.context = context
        self.glossary = glossary
        self.history = history
        self.maxTokens = maxTokens
    }
}

public struct TranslationStatistics: Sendable, Equatable {
    public enum StopReason: String, Sendable { case endOfText, maxTokens, cancelled }
    public var promptTokens: Int
    public var generatedTokens: Int
    public var prefillSeconds: Double
    public var generationSeconds: Double
    public var stopReason: StopReason
    public var tokensPerSecond: Double {
        generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : 0
    }
}

public enum TranslationEvent: Sendable, Equatable {
    /// The prompt has been processed; generation starts.
    case prefilled(promptTokens: Int)
    /// Newly generated text (append to the previous chunks).
    case text(String)
    case finished(TranslationStatistics)
}

/// Owns a loaded PLaMo 3 Translate model and runs translations one at a time.
public actor PlamoTranslator {
    /// Training context of PLaMo 3 Translate (input + output tokens).
    public static let contextLimit = 32_768
    static let stopTokens: Set<Int32> = [
        PlamoTokenizer.bosTokenId, PlamoTokenizer.tagTokenId, PlamoTokenizer.eosTokenId,
    ]

    public nonisolated let modelDirectory: URL
    public nonisolated let tokenizer: PlamoTokenizer
    public nonisolated let configuration: Plamo3Configuration
    private let model: Plamo3ForCausalLM
    /// Prompt tokens processed per forward pass during prefill.
    public var prefillStepSize = 512

    /// Loads tokenizer, configuration and (quantized) weights from a model directory.
    public init(modelDirectory: URL) throws {
        let (model, config) = try Plamo3Loader.load(directory: modelDirectory)
        self.model = model
        self.configuration = config
        self.tokenizer = try PlamoTokenizer(directory: modelDirectory)
        self.modelDirectory = modelDirectory
    }

    public func setPrefillStepSize(_ size: Int) {
        prefillStepSize = max(16, size)
    }

    /// Streams a translation. Cancelling the consuming task stops generation.
    public nonisolated func translate(_ request: TranslationRequest) -> AsyncThrowingStream<
        TranslationEvent, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Translates and returns the full text.
    public func translateText(_ request: TranslationRequest) async throws -> (String, TranslationStatistics) {
        var output = ""
        var stats: TranslationStatistics?
        try run(request) { event in
            switch event {
            case .text(let t): output += t
            case .finished(let s): stats = s
            case .prefilled: break
            }
        }
        return (output, stats!)
    }

    /// Token ids of the full prompt (BOS + PFML3).
    public nonisolated func promptTokens(for request: TranslationRequest) -> [Int32] {
        let prompt = PFML3.translationPrompt(
            source: PFML3.sanitize(request.text), targetLang: request.targetLanguage,
            sourceLang: request.sourceLanguage, context: request.context.map(PFML3.sanitize),
            glossary: request.glossary.map {
                GlossaryEntry(source: PFML3.sanitize($0.source), target: PFML3.sanitize($0.target))
            },
            form: request.form,
            history: request.history.map {
                TranslationTurn(
                    source: PFML3.sanitize($0.source), translation: PFML3.sanitize($0.translation))
            })
        return [PlamoTokenizer.bosTokenId] + tokenizer.encode(prompt)
    }

    private func run(_ request: TranslationRequest, emit: (TranslationEvent) -> Void) throws {
        // All MLX work (generation of any translator and model loading) is serialized.
        MLXGate.lock.lock()
        defer { MLXGate.lock.unlock() }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlamoError.emptyInput
        }
        let prompt = promptTokens(for: request)
        let sourceTokens = tokenizer.encode(request.text).count
        let available = Self.contextLimit - prompt.count
        guard available > 16 else {
            throw PlamoError.inputTooLong(tokens: prompt.count, limit: Self.contextLimit)
        }
        let maxTokens = min(available, request.maxTokens ?? max(128, sourceTokens * 3 + 64))

        let start = Date()
        let caches = model.makeCaches()

        // Prefill everything except the last prompt token (mirrors mlx-lm generate_step).
        var processed = 0
        while prompt.count - processed > 1 {
            try Task.checkCancellation()
            let n = min(prefillStepSize, prompt.count - processed - 1)
            let chunk = MLXArray(Array(prompt[processed ..< processed + n])).reshaped(1, n)
            _ = model.hidden(chunk, caches: caches)
            eval(caches.flatMap(\.state))
            processed += n
        }

        func step(_ token: MLXArray) -> MLXArray {
            let hidden = model.hidden(token.reshaped(1, 1), caches: caches)
            let logits = model.logits(hidden[0..., -1, 0...])
            let logprobs = logits - logSumExp(logits, axis: -1, keepDims: true)
            return argMax(logprobs, axis: -1)
        }

        var detokenizer = StreamingDetokenizer(tokenizer: tokenizer)
        var next = step(MLXArray([prompt[prompt.count - 1]]))
        asyncEval(next)
        var generated = 0
        var stopReason = TranslationStatistics.StopReason.maxTokens
        var prefillSeconds = 0.0
        var generationStart = Date()

        defer { Memory.clearCache() }
        while true {
            let current = next
            if generated + 1 < maxTokens {
                next = step(current)
                asyncEval(next)
            }
            let token = current.item(Int32.self)
            if generated == 0 {
                prefillSeconds = Date().timeIntervalSince(start)
                generationStart = Date()
                emit(.prefilled(promptTokens: prompt.count))
            }
            if Self.stopTokens.contains(token) {
                stopReason = .endOfText
                break
            }
            generated += 1
            let delta = detokenizer.append(token)
            if !delta.isEmpty { emit(.text(delta)) }
            if generated >= maxTokens { break }
            if Task.isCancelled {
                stopReason = .cancelled
                break
            }
        }
        let tail = detokenizer.finish()
        if !tail.isEmpty { emit(.text(tail)) }
        emit(
            .finished(
                TranslationStatistics(
                    promptTokens: prompt.count, generatedTokens: generated,
                    prefillSeconds: prefillSeconds,
                    generationSeconds: Date().timeIntervalSince(generationStart),
                    stopReason: stopReason)))
        if stopReason == .cancelled { throw CancellationError() }
    }
}

/// Serializes MLX evaluation across translator instances and model loading.
enum MLXGate {
    static let lock = NSLock()
}

enum Plamo3Loader {
    static func load(directory: URL) throws -> (Plamo3ForCausalLM, Plamo3Configuration) {
        MLXGate.lock.lock()
        defer { MLXGate.lock.unlock() }
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw PlamoError.missingFile("config.json")
        }
        let config = try Plamo3Configuration(contentsOf: configURL)
        let model = Plamo3ForCausalLM(config)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "safetensors" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw PlamoError.missingFile("*.safetensors") }

        var weights = [String: MLXArray]()
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                weights[key] = value
            }
        }
        if config.tieWordEmbeddings {
            weights["lm_head.weight"] = nil
        }
        // AutoRound stores affine scales/biases in FP16 while activations are BF16; MLX would
        // promote every quantized matmul to FP32 (slow in the JIT kernels). Store them in the
        // activation dtype instead (see `PlamoKernels`).
        if !PlamoKernels.reference, let activation = weights["model.embed_tokens.weight"]?.dtype {
            for (key, value) in weights
            where (key.hasSuffix(".scales") || key.hasSuffix(".biases")) && value.dtype != activation {
                weights[key] = value.asType(activation)
            }
        }

        if config.defaultQuantization != nil || !config.quantizationOverrides.isEmpty {
            quantize(model: model) { path, module in
                if let override = config.quantizationOverrides[path] {
                    guard let spec = override else { return nil }
                    return (spec.groupSize, spec.bits, .affine)
                }
                guard let spec = config.defaultQuantization,
                    module is Linear || module is Embedding,
                    weights["\(path).scales"] != nil
                else { return nil }
                return (spec.groupSize, spec.bits, .affine)
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return (model, config)
    }
}

// MARK: - Diagnostics

extension PlamoTranslator {
    /// Measures CPU graph-construction time vs. total time per decode step.
    public func profileDecode(steps: Int = 64) -> (buildMs: Double, totalMs: Double) {
        MLXGate.lock.lock()
        defer { MLXGate.lock.unlock() }
        let caches = model.makeCaches()
        let prompt = promptTokens(for: TranslationRequest(text: "This is a profiling run for the decoder.", targetLanguage: "ja"))
        _ = model.hidden(MLXArray(Array(prompt.dropLast())).reshaped(1, -1), caches: caches)
        eval(caches.flatMap(\.state))
        var token = MLXArray([prompt.last!])
        var build = 0.0
        let start = Date()
        for _ in 0 ..< steps {
            let t0 = Date()
            let hidden = model.hidden(token.reshaped(1, 1), caches: caches)
            let logits = model.logits(hidden[0..., -1, 0...])
            let next = argMax(logits - logSumExp(logits, axis: -1, keepDims: true), axis: -1)
            build += Date().timeIntervalSince(t0)
            eval(next)
            token = next
        }
        let total = Date().timeIntervalSince(start)
        return (build * 1000 / Double(steps), total * 1000 / Double(steps))
    }
}
