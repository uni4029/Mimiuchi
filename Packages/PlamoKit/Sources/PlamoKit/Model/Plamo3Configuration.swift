// Mirrors `ModelArgs` of PFN's `modeling_plamo_mlx.py`; see the license note in Plamo3Model.swift.

import Foundation

/// Per-layer quantization parameters (MLX affine quantization).
public struct QuantizationSpec: Sendable, Equatable {
    public var groupSize: Int
    public var bits: Int
}

/// `config.json` of a PLaMo 3 (MLX) checkpoint.
///
/// Mirrors `ModelArgs` in PFN's `modeling_plamo_mlx.py`.
public struct Plamo3Configuration: Sendable {
    public var modelType: String
    public var hiddenSize: Int
    public var numHiddenLayers: Int
    public var rmsNormEps: Float
    public var tieWordEmbeddings: Bool
    public var scaleEmbedding: Bool
    public var ropeScalingFactor: Float?
    public var numAttentionHeads: Int
    public var numKeyValueHeads: Int
    public var headDim: Int
    public var maxPositionEmbeddings: Int
    public var windowSize: Int
    public var slidingWindowPattern: Int
    public var intermediateSize: Int
    public var vocabSize: Int
    /// FP32-exact inverse RoPE frequencies serialized by PFN (`plamo_rope_inv_freq`).
    public var ropeInvFreqFull: [Float]
    public var ropeInvFreqLocal: [Float]
    /// Default quantization (nil = unquantized checkpoint).
    public var defaultQuantization: QuantizationSpec?
    /// Per-module overrides: `nil` value means "not quantized".
    public var quantizationOverrides: [String: QuantizationSpec?]

    public func isFullAttention(layer: Int) -> Bool {
        (layer + 1) % slidingWindowPattern == 0
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlamoError.invalidConfiguration("config.json is not an object")
        }
        try self.init(json: json)
    }

    public init(json: [String: Any]) throws {
        func int(_ key: String, _ def: Int? = nil) throws -> Int {
            if let v = json[key] as? NSNumber { return v.intValue }
            if let def { return def }
            throw PlamoError.invalidConfiguration("missing \(key)")
        }
        func float(_ key: String, _ def: Float? = nil) throws -> Float {
            if let v = json[key] as? NSNumber { return v.floatValue }
            if let def { return def }
            throw PlamoError.invalidConfiguration("missing \(key)")
        }
        func bool(_ key: String, _ def: Bool) -> Bool {
            (json[key] as? NSNumber)?.boolValue ?? def
        }

        modelType = json["model_type"] as? String ?? "plamo3"
        guard modelType == "plamo3" else {
            throw PlamoError.invalidConfiguration("unsupported model_type \(modelType)")
        }
        hiddenSize = try int("hidden_size")
        numHiddenLayers = try int("num_hidden_layers")
        rmsNormEps = try float("rms_norm_eps", 1e-6)
        tieWordEmbeddings = bool("tie_word_embeddings", true)
        scaleEmbedding = bool("scale_embedding", false)
        ropeScalingFactor = (json["rope_scaling_factor"] as? NSNumber)?.floatValue
        numAttentionHeads = try int("num_attention_heads")
        numKeyValueHeads = try int("num_key_value_heads")
        headDim = try int("head_dim", 128)
        maxPositionEmbeddings = try int("max_position_embeddings", 2048)
        if let sw = json["sliding_window"] as? NSNumber {
            windowSize = sw.intValue
        } else {
            windowSize = try int("window_size", 2048)
        }
        slidingWindowPattern = try int("sliding_window_pattern", 8)
        intermediateSize = try int("intermediate_size")
        vocabSize = try int("vocab_size")

        guard let rope = json["plamo_rope_inv_freq"] as? [String: Any],
            let full = rope["full"] as? [NSNumber], let local = rope["local"] as? [NSNumber]
        else {
            throw PlamoError.invalidConfiguration(
                "config.json lacks plamo_rope_inv_freq; re-download the model files")
        }
        ropeInvFreqFull = full.map { $0.floatValue }
        ropeInvFreqLocal = local.map { $0.floatValue }
        guard ropeInvFreqFull.count == headDim / 2, ropeInvFreqLocal.count == headDim / 2 else {
            throw PlamoError.invalidConfiguration("invalid RoPE dimensions")
        }

        var overrides: [String: QuantizationSpec?] = [:]
        if let q = (json["quantization"] ?? json["quantization_config"]) as? [String: Any] {
            let gs = (q["group_size"] as? NSNumber)?.intValue ?? 64
            let bits = (q["bits"] as? NSNumber)?.intValue ?? 4
            if let mode = q["mode"] as? String, mode != "affine" {
                throw PlamoError.invalidConfiguration("unsupported quantization mode \(mode)")
            }
            defaultQuantization = QuantizationSpec(groupSize: gs, bits: bits)
            for (key, value) in q where key != "group_size" && key != "bits" && key != "mode" {
                if let dict = value as? [String: Any] {
                    overrides[key] = QuantizationSpec(
                        groupSize: (dict["group_size"] as? NSNumber)?.intValue ?? gs,
                        bits: (dict["bits"] as? NSNumber)?.intValue ?? bits)
                } else if let flag = value as? NSNumber, !flag.boolValue {
                    overrides[key] = .some(nil)
                }
            }
        } else {
            defaultQuantization = nil
        }
        quantizationOverrides = overrides
    }
}

public enum PlamoError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case missingFile(String)
    case modelNotLoaded
    case inputTooLong(tokens: Int, limit: Int)
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): return "モデル設定が不正です: \(m)"
        case .missingFile(let f): return "モデルファイルが見つかりません: \(f)"
        case .modelNotLoaded: return "モデルが読み込まれていません"
        case .inputTooLong(let t, let l): return "入力が長すぎます（\(t) トークン / 上限 \(l)）"
        case .emptyInput: return "翻訳するテキストがありません"
        }
    }
}
