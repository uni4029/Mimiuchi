// Swift/MLX port of PFN's `modeling_plamo_mlx.py` (PLaMo 3), whose header reads:
//   "Portions Copyright © 2026 Apple Inc. (mlx-lm, MIT License; see LICENSE.mlx-lm).
//    Modifications Copyright © 2026 Preferred Networks, Inc."
// The mlx-lm portions are under the MIT License (Licenses/mlx-lm.txt); PFN's model code is
// subject to the PLaMo Community License (Licenses/PLaMo-Community-License-*.txt).
// See Packages/PlamoKit/NOTICE.md.
//
// The operation order and dtype casts intentionally mirror the reference so that
// greedy decoding reproduces the official mlx-lm runtime.

import Foundation
import MLX
import MLXFast
import MLXNN

/// Kernel selection.
///
/// By default the fused MLX RMSNorm kernel is used (same rounding order as the reference:
/// normalize in FP32, round, then scale) and quantization scales are converted to the
/// activation dtype at load time. Both were validated against the official mlx-lm runtime
/// (identical greedy outputs on the golden + 30-sentence sets) and make decoding ~3x faster.
/// Set `PLAMO_REFERENCE=1` to use PFN's exact op sequence and FP16 scales instead.
enum PlamoKernels {
    static let reference = ProcessInfo.processInfo.environment["PLAMO_REFERENCE"] == "1"
    static var fused: Bool { !reference }
}

/// Holds derived arrays without exposing them to `Module` reflection (not parameters).
final class ArrayBox {
    var value: MLXArray?
}

/// RMSNorm with an additive weight offset (`scale = weight + offset`).
///
/// Like HF, the normalized activation is rounded to the input dtype before the scale is applied.
final class PlamoRMSNorm: Module, UnaryLayer {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float
    let offset: Float
    private let cachedScale = ArrayBox()

    init(dimensions: Int, eps: Float, offset: Float = 1.0) {
        self._weight.wrappedValue = MLXArray.zeros([dimensions])
        self.eps = eps
        self.offset = offset
        super.init()
    }

    var scale: MLXArray {
        if offset == 0 { return weight }
        if let s = cachedScale.value { return s }
        let s = weight + offset
        cachedScale.value = s
        return s
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if PlamoKernels.fused {
            return MLXFast.rmsNorm(x, weight: scale, eps: eps)
        }
        let value = x.asType(.float32)
        let normalized = value * rsqrt(mean(value * value, axis: -1, keepDims: true) + eps)
        return normalized.asType(x.dtype) * scale
    }
}

/// Precomputed rotary tables for one forward pass (shared by all layers of a kind).
struct RotaryTables {
    let cos: MLXArray
    let sin: MLXArray

    /// HF YaRN arithmetic: cos/sin in FP32, rounded to the activation dtype, then scaled.
    init(invFreq: MLXArray, concentration: Float, offset: Int, length: Int, dtype: DType) {
        let positions = MLXArray(Int32(0) ..< Int32(length)).asType(.float32) + Float(offset)
        var phase = positions.expandedDimensions(axis: -1) * invFreq
        phase = concatenated([phase, phase], axis: -1)
        var c = MLX.cos(phase).asType(dtype)
        var s = MLX.sin(phase).asType(dtype)
        if concentration != 1 {
            c = c * concentration
            s = s * concentration
        }
        self.cos = c
        self.sin = s
    }

    func apply(_ x: MLXArray) -> MLXArray {
        let half = x.dim(-1) / 2
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return x * cos + rotated * sin
    }
}

final class Plamo3Attention: Module {
    let config: Plamo3Configuration
    let fullAttention: Bool
    let scale: Float
    let qHeads: Int
    let kvHeads: Int
    let headDim: Int

    @ModuleInfo(key: "qkv_proj") var qkvProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: PlamoRMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: PlamoRMSNorm

    init(_ config: Plamo3Configuration, layer: Int) {
        self.config = config
        self.fullAttention = config.isFullAttention(layer: layer)
        self.headDim = config.headDim
        self.scale = pow(Float(config.headDim), -0.5)
        self.qHeads = config.numAttentionHeads
        self.kvHeads = config.numKeyValueHeads
        let qDim = qHeads * headDim
        let kvDim = kvHeads * headDim
        self._qkvProj.wrappedValue = Linear(config.hiddenSize, qDim + 2 * kvDim, bias: false)
        self._oProj.wrappedValue = Linear(qDim, config.hiddenSize, bias: false)
        self._qNorm.wrappedValue = PlamoRMSNorm(dimensions: headDim, eps: config.rmsNormEps, offset: 1.0)
        self._kNorm.wrappedValue = PlamoRMSNorm(dimensions: headDim, eps: config.rmsNormEps, offset: 1.0)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, rope: RotaryTables, cache: KVCache) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        let qDim = qHeads * headDim
        let kvDim = kvHeads * headDim

        // AutoRound stores affine scales in FP16; restore the activation dtype at each linear boundary.
        let qkv = qkvProj(x).asType(x.dtype)
        let parts = qkv.split(indices: [qDim, qDim + kvDim], axis: -1)
        var queries = parts[0].reshaped(b, l, qHeads, headDim).transposed(0, 2, 1, 3)
        var keys = parts[1].reshaped(b, l, kvHeads, headDim).transposed(0, 2, 1, 3)
        let values = parts[2].reshaped(b, l, kvHeads, headDim).transposed(0, 2, 1, 3)

        queries = qNorm(queries)
        keys = kNorm(keys)
        queries = rope.apply(queries)
        keys = rope.apply(keys)

        let offsetBefore = cache.offset
        var (allKeys, allValues) = cache.update(keys: keys, values: values)
        let total = offsetBefore + l

        let mask: MLXFast.ScaledDotProductAttentionMaskMode
        if fullAttention {
            mask = l > 1 ? .causal : .none
        } else {
            // Sliding window of `windowSize` keys including the query itself
            // (same semantics as mlx-lm's RotatingKVCache + create_causal_mask).
            let window = config.windowSize
            if l == 1 {
                if total > window {
                    allKeys = allKeys[.ellipsis, (total - window)..., 0...]
                    allValues = allValues[.ellipsis, (total - window)..., 0...]
                }
                mask = .none
            } else {
                let start = max(0, offsetBefore - (window - 1))
                if start > 0 {
                    allKeys = allKeys[.ellipsis, start..., 0...]
                    allValues = allValues[.ellipsis, start..., 0...]
                }
                let relOffset = offsetBefore - start
                if relOffset + l > window {
                    mask = .array(Self.windowedCausalMask(n: l, offset: relOffset, window: window))
                } else {
                    mask = .causal
                }
            }
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: allKeys, values: allValues, scale: scale, mask: mask)
        let merged = output.transposed(0, 2, 1, 3).reshaped(b, l, qHeads * headDim)
        return oProj(merged).asType(x.dtype)
    }

    static func windowedCausalMask(n: Int, offset: Int, window: Int) -> MLXArray {
        let rinds = MLXArray(Int32(0) ..< Int32(offset + n))[.newAxis]
        let linds = MLXArray(Int32(offset) ..< Int32(offset + n))[0..., .newAxis]
        return (linds .>= rinds) & (linds .< (rinds + Int32(window)))
    }
}

final class Plamo3MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_up_proj") var gateUpProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: Plamo3Configuration) {
        self._gateUpProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize * 2, bias: false)
        self._downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (gate, value) = gateUpProj(x).asType(x.dtype).split(axis: -1)
        // torch's silu rounds once to the input dtype.
        let g32 = gate.asType(.float32)
        let activated = (g32 * sigmoid(g32)).asType(gate.dtype)
        return downProj(activated * value).asType(x.dtype)
    }
}

final class Plamo3DecoderLayer: Module {
    let fullAttention: Bool
    @ModuleInfo(key: "mixer") var mixer: Plamo3Attention
    @ModuleInfo(key: "mlp") var mlp: Plamo3MLP
    @ModuleInfo(key: "pre_mixer_norm") var preMixerNorm: PlamoRMSNorm
    @ModuleInfo(key: "post_mixer_norm") var postMixerNorm: PlamoRMSNorm
    @ModuleInfo(key: "pre_mlp_norm") var preMlpNorm: PlamoRMSNorm
    @ModuleInfo(key: "post_mlp_norm") var postMlpNorm: PlamoRMSNorm

    init(_ config: Plamo3Configuration, layer: Int) {
        self.fullAttention = config.isFullAttention(layer: layer)
        let eps = config.rmsNormEps
        let d = config.hiddenSize
        self._mixer.wrappedValue = Plamo3Attention(config, layer: layer)
        self._mlp.wrappedValue = Plamo3MLP(config)
        self._preMixerNorm.wrappedValue = PlamoRMSNorm(dimensions: d, eps: eps, offset: 1.0)
        self._postMixerNorm.wrappedValue = PlamoRMSNorm(dimensions: d, eps: eps, offset: 1.0 / 5)
        self._preMlpNorm.wrappedValue = PlamoRMSNorm(dimensions: d, eps: eps, offset: 1.0)
        self._postMlpNorm.wrappedValue = PlamoRMSNorm(
            dimensions: d, eps: eps, offset: Float(1.0 / pow(5.0, 1.5)))
        super.init()
    }

    func callAsFunction(_ x: MLXArray, rope: RotaryTables, cache: KVCache) -> MLXArray {
        var h = x + postMixerNorm(mixer(preMixerNorm(x), rope: rope, cache: cache))
        h = h + postMlpNorm(mlp(preMlpNorm(h)))
        return h
    }
}

final class Plamo3Decoder: Module {
    @ModuleInfo(key: "layers") var layers: [Plamo3DecoderLayer]

    init(_ config: Plamo3Configuration) {
        self._layers.wrappedValue = (0 ..< config.numHiddenLayers).map {
            Plamo3DecoderLayer(config, layer: $0)
        }
        super.init()
    }
}

final class Plamo3Backbone: Module {
    let config: Plamo3Configuration
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: Plamo3Decoder
    @ModuleInfo(key: "norm") var norm: PlamoRMSNorm

    let _invFreqFull: MLXArray
    let _invFreqLocal: MLXArray
    let fullConcentration: Float

    init(_ config: Plamo3Configuration) {
        self.config = config
        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = Plamo3Decoder(config)
        self._norm.wrappedValue = PlamoRMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps, offset: 1.0)
        self._invFreqFull = MLXArray(config.ropeInvFreqFull)
        self._invFreqLocal = MLXArray(config.ropeInvFreqLocal)
        if let factor = config.ropeScalingFactor, factor != 1 {
            self.fullConcentration = 1 + 0.1 * log(factor)
        } else {
            self.fullConcentration = 1
        }
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, caches: [KVCache]) -> MLXArray {
        var h = embedTokens(inputs)
        if config.scaleEmbedding {
            h = h * sqrt(Float(config.hiddenSize))
        }
        let offset = caches.first?.offset ?? 0
        let length = h.dim(1)
        let full = RotaryTables(
            invFreq: _invFreqFull, concentration: fullConcentration, offset: offset,
            length: length, dtype: h.dtype)
        let local = RotaryTables(
            invFreq: _invFreqLocal, concentration: 1, offset: offset, length: length,
            dtype: h.dtype)
        for (layer, cache) in zip(layers.layers, caches) {
            h = layer(h, rope: layer.fullAttention ? full : local, cache: cache)
        }
        return norm(h)
    }
}

/// PLaMo 3 causal language model (`Plamo3ForCausalLM`).
final class Plamo3ForCausalLM: Module {
    let config: Plamo3Configuration
    @ModuleInfo(key: "model") var model: Plamo3Backbone
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ config: Plamo3Configuration) {
        self.config = config
        self._model.wrappedValue = Plamo3Backbone(config)
        if !config.tieWordEmbeddings {
            self._lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
        }
        super.init()
    }

    func makeCaches() -> [KVCache] {
        (0 ..< config.numHiddenLayers).map { _ in KVCache() }
    }

    /// Hidden states after the final norm (B, L, D).
    func hidden(_ inputs: MLXArray, caches: [KVCache]) -> MLXArray {
        model(inputs, caches: caches)
    }

    /// FP32 logits for the given hidden states.
    func logits(_ hidden: MLXArray) -> MLXArray {
        if let lmHead {
            return lmHead(hidden).asType(.float32)
        }
        return model.embedTokens.asLinear(hidden).asType(.float32)
    }
}
