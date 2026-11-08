// Follows mlx-lm's `KVCache` (Copyright © 2023 Apple Inc., MIT License; Licenses/mlx-lm.txt).

import MLX

/// Growing key/value cache (same layout and growth policy as mlx-lm's `KVCache`).
///
/// Sliding-window layers also use this cache; the window is applied when attending
/// (see ``Plamo3Attention``), which is mathematically identical to mlx-lm's
/// `RotatingKVCache` but keeps the implementation simple.
final class KVCache {
    private(set) var keys: MLXArray?
    private(set) var values: MLXArray?
    private(set) var offset = 0
    let step = 256

    /// Appends `keys`/`values` (B, H, L, D) and returns all cached entries.
    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = offset
        let needsGrow: Bool
        if let keys {
            needsGrow = previous + newKeys.dim(2) > keys.dim(2)
        } else {
            needsGrow = true
        }

        if needsGrow {
            let b = newKeys.dim(0)
            let heads = newKeys.dim(1)
            let nSteps = (step + newKeys.dim(2) - 1) / step
            let kShape = [b, heads, nSteps * step, newKeys.dim(3)]
            let vShape = [b, heads, nSteps * step, newValues.dim(3)]
            let grownK = MLXArray.zeros(kShape, dtype: newKeys.dtype)
            let grownV = MLXArray.zeros(vShape, dtype: newValues.dtype)
            if var k = keys, var v = values {
                if previous % step != 0 {
                    k = k[.ellipsis, ..<previous, 0...]
                    v = v[.ellipsis, ..<previous, 0...]
                }
                keys = concatenated([k, grownK], axis: 2)
                values = concatenated([v, grownV], axis: 2)
            } else {
                keys = grownK
                values = grownV
            }
        }

        offset += newKeys.dim(2)
        keys![.ellipsis, previous ..< offset, 0...] = newKeys
        values![.ellipsis, previous ..< offset, 0...] = newValues
        return (keys![.ellipsis, ..<offset, 0...], values![.ellipsis, ..<offset, 0...])
    }

    /// Arrays to evaluate in order to materialize the cache.
    var state: [MLXArray] {
        [keys, values].compactMap { $0 }
    }
}
