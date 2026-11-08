import Foundation

/// Incremental, UTF-8-safe detokenizer for streaming generation output.
///
/// Byte-fallback tokens can split a character across several tokens; incomplete
/// trailing sequences are held back until they are complete.
public struct StreamingDetokenizer: Sendable {
    private let tokenizer: PlamoTokenizer
    private var pending: [UInt8] = []
    public private(set) var text: String = ""

    public init(tokenizer: PlamoTokenizer) {
        self.tokenizer = tokenizer
    }

    /// Appends a token and returns the newly completed text ("" while a character is incomplete).
    public mutating func append(_ id: Int32) -> String {
        pending.append(contentsOf: tokenizer.bytes(for: id))
        let complete = Self.completePrefixLength(pending)
        guard complete > 0 else { return "" }
        let chunk = String(decoding: pending[0 ..< complete], as: UTF8.self)
        pending.removeFirst(complete)
        text += chunk
        return chunk
    }

    /// Flushes pending bytes (an invalid or truncated tail becomes U+FFFD).
    public mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        let chunk = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        text += chunk
        return chunk
    }

    /// Length of the longest prefix that does not end in an incomplete UTF-8 sequence.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        // Look back at most 3 bytes for the lead byte of the final sequence.
        var i = n - 1
        var continuation = 0
        while i >= 0 && n - i <= 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 {
                continuation += 1
                i -= 1
                continue
            }
            let expected: Int
            if b & 0x80 == 0 {
                expected = 1
            } else if b & 0xE0 == 0xC0 {
                expected = 2
            } else if b & 0xF0 == 0xE0 {
                expected = 3
            } else if b & 0xF8 == 0xF0 {
                expected = 4
            } else {
                return n  // invalid lead byte: let the decoder substitute it
            }
            return continuation + 1 < expected ? i : n
        }
        return n  // only continuation bytes: invalid, emit as replacement
    }
}
