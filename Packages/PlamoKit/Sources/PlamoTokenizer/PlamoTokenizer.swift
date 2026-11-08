// Derived from `tokenization_plamo.py` in PFN's PLaMo 3 Translate repositories
// (Copyright © Preferred Networks, Inc.). As PLaMo tokenizer code it is subject to the PLaMo
// Community License (Licenses/PLaMo-Community-License-*.txt); see Packages/PlamoKit/NOTICE.md.
//
// Swift port of PFN's PLaMo tokenizer (`tokenization_plamo.py`, Plamo3Tokenizer).
//
// The tokenizer is a Unigram model evaluated with an Aho-Corasick automaton. This port
// reproduces the reference exactly: the same flattened table layout, scores rounded with
// `round(score * 1e4)`, boundary characters around special tokens and long runs, and UTF-8
// byte fallback. All string handling is done on Unicode scalars (code points), matching the
// Python implementation which operates on UTF-32 code points.

import Foundation

public enum PlamoTokenizerError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidVocabulary(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "Tokenizer file not found: \(url.path)"
        case .invalidVocabulary(let message): return "Invalid tokenizer vocabulary: \(message)"
        }
    }
}

public final class PlamoTokenizer: @unchecked Sendable {
    public static let unkTokenId: Int32 = 0
    public static let bosTokenId: Int32 = 1
    public static let eosTokenId: Int32 = 2
    public static let padTokenId: Int32 = 3
    public static let tagTokenId: Int32 = 16

    static let invalidScore: Int32 = -20_000_000
    static let unknownScore: Int32 = -10_000_000
    /// U+EE00 (private use) is used internally as a hard token boundary.
    static let boundaryScalar: UInt32 = 0xEE00
    static let boundaryTokenId: Int32 = 10_000_000

    public let vocabSize: Int

    private let pieces: [String]
    private let pieceBytes: [[UInt8]]
    private let byteTokenIds: [Int32]  // byte value -> token id
    private let pieceToId: [String: Int32]

    // Flattened Aho-Corasick table (struct-of-arrays).
    private let tableLength: [Int32]
    private let tableTokenId: [Int32]
    private let tableScore: [Int32]
    private let tablePieceId: [Int32]
    /// (code point << 32 | suffix id) -> suffix id.
    private let toSuffixId: [UInt64: Int32]

    private let consecutiveSpacesThreshold: Int?
    private let repeatedCharsThreshold: Int?

    /// Loads `tokenizer.jsonl` and the break-around thresholds from `tokenizer_config.json`.
    public convenience init(directory: URL) throws {
        var spaces: Int? = nil
        var repeated: Int? = nil
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            spaces = (json["break_around_consecutive_spaces_threshold"] as? NSNumber)?.intValue
            repeated = (json["break_around_repeated_chars_threshold"] as? NSNumber)?.intValue
        }
        try self.init(
            vocabularyURL: directory.appendingPathComponent("tokenizer.jsonl"),
            breakAroundConsecutiveSpacesThreshold: spaces,
            breakAroundRepeatedCharsThreshold: repeated)
    }

    public init(
        vocabularyURL: URL, breakAroundConsecutiveSpacesThreshold: Int?,
        breakAroundRepeatedCharsThreshold: Int?
    ) throws {
        guard FileManager.default.fileExists(atPath: vocabularyURL.path) else {
            throw PlamoTokenizerError.fileNotFound(vocabularyURL)
        }
        let rows = try Self.parseVocabulary(Data(contentsOf: vocabularyURL))
        self.vocabSize = rows.count
        self.consecutiveSpacesThreshold = breakAroundConsecutiveSpacesThreshold
        self.repeatedCharsThreshold = breakAroundRepeatedCharsThreshold

        var pieces = [String]()
        var pieceBytes = [[UInt8]]()
        var byteTokenIds = [Int32](repeating: -1, count: 256)
        var pieceToId = [String: Int32]()
        pieces.reserveCapacity(rows.count)
        pieceBytes.reserveCapacity(rows.count)
        pieceToId.reserveCapacity(rows.count)

        // Reversed trie: node(s) is the child of node(s[1:]) via edge s[0].
        // Every node corresponds to a suffix of some token; preorder over this trie with
        // children sorted by code point equals Python's `sort(key=lambda x: x[::-1])`.
        var edges = [UInt64: Int32]()  // (scalar << 32 | parent) -> child
        edges.reserveCapacity(rows.count * 4)
        var nodeScore = [Double](arrayLiteral: .nan)
        var nodeTokenId = [Int32](arrayLiteral: -1)
        var edgeList = [(parent: Int32, scalar: UInt32, child: Int32)]()
        edgeList.reserveCapacity(rows.count * 4)

        func insert(_ scalars: [UInt32], tokenId: Int32, score: Double) {
            var node: Int32 = 0
            for c in scalars.reversed() {
                let key = UInt64(c) << 32 | UInt64(UInt32(bitPattern: node))
                if let child = edges[key] {
                    node = child
                } else {
                    let child = Int32(nodeScore.count)
                    nodeScore.append(.nan)
                    nodeTokenId.append(-1)
                    edges[key] = child
                    edgeList.append((node, c, child))
                    node = child
                }
            }
            nodeScore[Int(node)] = score
            nodeTokenId[Int(node)] = tokenId
        }

        for (index, row) in rows.enumerated() {
            let id = Int32(index)
            pieces.append(row.piece)
            if pieceToId[row.piece] == nil { pieceToId[row.piece] = id }
            if row.isByte {
                let scalars = Array(row.piece.unicodeScalars)
                guard scalars.count == 6, row.piece.hasPrefix("<0x"), row.piece.hasSuffix(">"),
                    let value = UInt8(String(row.piece.dropFirst(3).prefix(2)), radix: 16)
                else {
                    throw PlamoTokenizerError.invalidVocabulary("bad byte token \(row.piece)")
                }
                byteTokenIds[Int(value)] = id
                pieceBytes.append([value])
                continue
            }
            pieceBytes.append(Array(row.piece.utf8))
            insert(row.piece.unicodeScalars.map(\.value), tokenId: id, score: row.score)
        }
        insert([Self.boundaryScalar], tokenId: Self.boundaryTokenId, score: 0)
        if let missing = byteTokenIds.firstIndex(of: -1) {
            throw PlamoTokenizerError.invalidVocabulary(
                "byte token for <0x\(String(format: "%02X", missing))> is not set")
        }

        // Children in CSR form, sorted by code point.
        let nodeCount = nodeScore.count
        edgeList.sort { $0.parent != $1.parent ? $0.parent < $1.parent : $0.scalar < $1.scalar }
        var childStart = [Int32](repeating: 0, count: nodeCount + 1)
        for e in edgeList { childStart[Int(e.parent) + 1] += 1 }
        for i in 0 ..< nodeCount { childStart[i + 1] += childStart[i] }

        @inline(__always) func child(_ node: Int32, _ c: UInt32) -> Int32 {
            node < 0 ? -1 : (edges[UInt64(c) << 32 | UInt64(UInt32(bitPattern: node))] ?? -1)
        }

        // Preorder traversal shared by both passes. `trailing[j]` holds the node of
        // path[j..<depth] (the reversed form of the prefix s[:depth-j] of suffix s), or -1.
        func traverse(_ visit: (_ node: Int32, _ depth: Int, _ trailing: [Int32]) -> Void) {
            var stack: [(node: Int32, depth: Int, next: Int32)] = [(0, 0, childStart[0])]
            var trailingStack: [[Int32]] = [[]]
            visit(0, 0, [])
            while let top = stack.last {
                let end = childStart[Int(top.node) + 1]
                if top.next >= end {
                    stack.removeLast()
                    trailingStack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let edge = edgeList[Int(top.next)]
                let parentTrailing = trailingStack[trailingStack.count - 1]
                var trailing = [Int32]()
                trailing.reserveCapacity(top.depth + 1)
                for j in 0 ..< top.depth {
                    trailing.append(child(parentTrailing[j], edge.scalar))
                }
                trailing.append(child(0, edge.scalar))
                visit(edge.child, top.depth + 1, trailing)
                stack.append((edge.child, top.depth + 1, childStart[Int(edge.child)]))
                trailingStack.append(trailing)
            }
        }

        // Pass 1: table offsets (suffix ids).
        var tableStart = [Int32](repeating: 0, count: nodeCount)
        var numPieces: Int32 = 0
        traverse { node, _, trailing in
            tableStart[Int(node)] = numPieces
            var count: Int32 = 1  // sentinel
            for n in trailing where n >= 0 { count += 1 }
            numPieces += count
        }
        guard tableStart[0] == 0 else {
            throw PlamoTokenizerError.invalidVocabulary("root suffix id must be 0")
        }

        // Pass 2: rows, longest piece first, then a sentinel row.
        let total = Int(numPieces)
        var tableLength = [Int32](repeating: 0, count: total)
        var tableTokenId = [Int32](repeating: 0, count: total)
        var tableScore = [Int32](repeating: 0, count: total)
        var tablePieceId = [Int32](repeating: 0, count: total)
        traverse { node, depth, trailing in
            var i = Int(tableStart[Int(node)])
            for j in 0 ..< depth {
                let piece = trailing[j]
                guard piece >= 0 else { continue }
                let score = nodeScore[Int(piece)]
                tableLength[i] = Int32(depth - j)
                tableTokenId[i] = nodeTokenId[Int(piece)]
                tableScore[i] =
                    score.isFinite ? Int32((score * 1e4).rounded(.toNearestOrEven)) : Self.invalidScore
                tablePieceId[i] = tableStart[Int(piece)]
                i += 1
            }
            tableLength[i] = 1
            tableTokenId[i] = -1
            tableScore[i] = Self.unknownScore
            tablePieceId[i] = 0
        }

        var toSuffixId = [UInt64: Int32]()
        toSuffixId.reserveCapacity(edgeList.count)
        for e in edgeList {
            let key = UInt64(e.scalar) << 32 | UInt64(UInt32(bitPattern: tableStart[Int(e.parent)]))
            toSuffixId[key] = tableStart[Int(e.child)]
        }

        self.pieces = pieces
        self.pieceBytes = pieceBytes
        self.byteTokenIds = byteTokenIds
        self.pieceToId = pieceToId
        self.tableLength = tableLength
        self.tableTokenId = tableTokenId
        self.tableScore = tableScore
        self.tablePieceId = tablePieceId
        self.toSuffixId = toSuffixId
    }

    // MARK: - Public API

    /// Same as HF `encode(text, add_special_tokens=False)` (no BOS is added).
    public func encode(_ text: String) -> [Int32] {
        var data = text.unicodeScalars.map(\.value)
        data = Self.markSpecialTokens(data)
        data = markRuns(data)
        return encodeScalars(data)
    }

    /// Same as HF `decode(ids)`: special tokens are kept, byte tokens are merged and
    /// invalid UTF-8 is replaced with U+FFFD.
    public func decode(_ ids: [Int32]) -> String {
        var bytes = [UInt8]()
        for id in ids { bytes.append(contentsOf: self.bytes(for: id)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func bytes(for id: Int32) -> [UInt8] {
        guard id >= 0, Int(id) < pieceBytes.count else { return [] }
        return pieceBytes[Int(id)]
    }

    public func piece(for id: Int32) -> String {
        guard id >= 0, Int(id) < pieces.count else { return "" }
        return pieces[Int(id)]
    }

    public func tokenId(for piece: String) -> Int32? {
        pieceToId[piece]
    }

    // MARK: - Pre-processing

    /// Python `re.sub(r"(<\|plamo:[^|\s]{,64}\|>)", B + r"\1" + B, data)`.
    static func markSpecialTokens(_ data: [UInt32]) -> [UInt32] {
        let prefix: [UInt32] = Array("<|plamo:".unicodeScalars.map(\.value))
        let bar: UInt32 = 0x7C  // |
        let gt: UInt32 = 0x3E  // >
        guard data.count >= prefix.count + 2 else { return data }
        var out = [UInt32]()
        var i = 0
        var copied = 0
        let n = data.count
        while i + prefix.count + 2 <= n {
            if data[i] == prefix[0] && Array(data[i ..< i + prefix.count]) == prefix {
                var j = i + prefix.count
                while j < n && j - (i + prefix.count) <= 64 && data[j] != bar
                    && !isPythonWhitespace(data[j])
                {
                    j += 1
                }
                let bodyLength = j - (i + prefix.count)
                if bodyLength <= 64 && j + 1 < n && data[j] == bar && data[j + 1] == gt {
                    if out.isEmpty { out.reserveCapacity(n + 8) }
                    out.append(contentsOf: data[copied ..< i])
                    out.append(boundaryScalar)
                    out.append(contentsOf: data[i ... j + 1])
                    out.append(boundaryScalar)
                    i = j + 2
                    copied = i
                    continue
                }
            }
            i += 1
        }
        if copied == 0 { return data }
        out.append(contentsOf: data[copied...])
        return out
    }

    /// Python `re.sub(r"((.)\2{R-1,}| {S,})", B + r"\1" + B, data)`.
    /// `.` matches anything except "\n"; both alternatives consume a maximal run.
    func markRuns(_ data: [UInt32]) -> [UInt32] {
        guard repeatedCharsThreshold != nil || consecutiveSpacesThreshold != nil else { return data }
        let n = data.count
        var out = [UInt32]()
        var copied = 0
        var i = 0
        while i < n {
            let c = data[i]
            var r = 1
            while i + r < n && data[i + r] == c { r += 1 }
            var matched = false
            if let rep = repeatedCharsThreshold, c != 0x0A, r >= rep { matched = true }
            if !matched, let sp = consecutiveSpacesThreshold, c == 0x20, r >= sp { matched = true }
            if matched {
                if out.isEmpty { out.reserveCapacity(n + 8) }
                out.append(contentsOf: data[copied ..< i])
                out.append(Self.boundaryScalar)
                out.append(contentsOf: data[i ..< i + r])
                out.append(Self.boundaryScalar)
                copied = i + r
            }
            i += r
        }
        if copied == 0 { return data }
        out.append(contentsOf: data[copied...])
        return out
    }

    /// Characters matched by Python's `\s` in str patterns.
    @inline(__always) static func isPythonWhitespace(_ c: UInt32) -> Bool {
        switch c {
        case 0x09 ... 0x0D, 0x1C ... 0x20, 0x85, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029,
            0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    // MARK: - Unigram DP (port of AhoCorasick._encode)

    func encodeScalars(_ data: [UInt32]) -> [Int32] {
        let n = data.count
        if n == 0 { return [] }
        let tableCount = tableScore.count
        var scores = [Int64](repeating: 1 << 60, count: n + 1)
        scores[n] = 0
        var pathLength = [Int32](repeating: 0, count: n + 1)
        var pathToken = [Int32](repeating: 0, count: n + 1)
        var pathCount = [Int32](repeating: 0, count: n + 1)
        let unknown = Self.unknownScore
        let invalid = Self.invalidScore

        tableScore.withUnsafeBufferPointer { score in
            tableLength.withUnsafeBufferPointer { length in
                tableTokenId.withUnsafeBufferPointer { tokenId in
                    tablePieceId.withUnsafeBufferPointer { pieceId in
                        var suffixId: Int32 = 0
                        var i = n - 1
                        while i >= 0 {
                            let c = data[i]
                            let high = UInt64(c) << 32
                            var p = Int(suffixId)
                            while p < tableCount {
                                suffixId = toSuffixId[high | UInt64(UInt32(bitPattern: pieceId[p]))] ?? 0
                                if suffixId > 0 || score[p] == unknown { break }
                                p += 1
                            }
                            p = Int(suffixId)
                            while p < tableCount {
                                let s = score[p]
                                if s > invalid {
                                    let len = Int(length[p])
                                    let candidate = scores[i + len] - Int64(s)
                                    if candidate < scores[i] {
                                        scores[i] = candidate
                                        pathLength[i] = Int32(len)
                                        pathToken[i] = tokenId[p]
                                        pathCount[i] = pathCount[i + len] + 1
                                        if s == unknown {
                                            pathCount[i] +=
                                                (c >= 0x80 ? 1 : 0) + (c >= 0x800 ? 1 : 0)
                                                + (c >= 0x10000 ? 1 : 0)
                                        }
                                    }
                                }
                                if s == unknown { break }
                                p += 1
                            }
                            i -= 1
                        }
                    }
                }
            }
        }

        var result = [Int32]()
        result.reserveCapacity(Int(pathCount[0]))
        var pos = 0
        while pos < n {
            let token = pathToken[pos]
            if token >= 0 {
                if token != Self.boundaryTokenId { result.append(token) }
            } else {
                // Byte fallback (UTF-8 encoding of the code point).
                let c = data[pos]
                let s = 1 + (c >= 0x80 ? 1 : 0) + (c >= 0x800 ? 1 : 0) + (c >= 0x10000 ? 1 : 0)
                for k in 0 ..< s {
                    let b: UInt32 = s == 1 ? c : (k == 0 ? (0xF00 >> UInt32(s)) & 0xFF : 0x80)
                    let value = b | ((c >> UInt32((s - k - 1) * 6)) & 0x3F)
                    result.append(byteTokenIds[Int(value & 0xFF)])
                }
            }
            let step = Int(pathLength[pos])
            precondition(step > 0, "tokenizer made no progress at \(pos)")
            pos += step
        }
        return result
    }

    // MARK: - Vocabulary parsing

    struct Row {
        var piece: String
        var score: Double
        var isByte: Bool
    }

    /// Parses JSONL rows `[piece, score, type]` with a single JSONSerialization call.
    static func parseVocabulary(_ data: Data) throws -> [Row] {
        var joined = Data()
        joined.reserveCapacity(data.count + 2)
        joined.append(UInt8(ascii: "["))
        var first = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var lineStart = 0
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0 ... bytes.count {
                if i == bytes.count || bytes[i] == UInt8(ascii: "\n") {
                    var end = i
                    if end > lineStart && bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                    if end > lineStart {
                        if !first { joined.append(UInt8(ascii: ",")) }
                        joined.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[lineStart ..< end]))
                        first = false
                    }
                    lineStart = i + 1
                }
            }
        }
        joined.append(UInt8(ascii: "]"))
        guard let array = try JSONSerialization.jsonObject(with: joined) as? [[Any]] else {
            throw PlamoTokenizerError.invalidVocabulary("tokenizer.jsonl rows must be arrays")
        }
        var rows = [Row]()
        rows.reserveCapacity(array.count)
        for (i, item) in array.enumerated() {
            guard item.count >= 2, let piece = item[0] as? String, let score = item[1] as? NSNumber
            else {
                throw PlamoTokenizerError.invalidVocabulary("row \(i)")
            }
            let type = item.count > 2 ? item[2] as? String : nil
            rows.append(Row(piece: piece, score: score.doubleValue, isByte: type == "BYTE"))
        }
        return rows
    }
}
