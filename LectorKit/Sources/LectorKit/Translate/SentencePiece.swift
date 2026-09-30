import Foundation

enum SentencePieceError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .malformed(let detail): "Malformed SentencePiece model: \(detail)"
        case .unsupported(let detail): "Unsupported SentencePiece model: \(detail)"
        }
    }
}

/// A SentencePiece unigram model read straight from its `.spm` protobuf.
///
/// `encode` reproduces `SentencePieceProcessor.encode(text, out_type=str)` from the reference
/// library: the model's own normaliser (its precompiled character map plus the whitespace
/// rules), then the Viterbi segmentation over the piece scores. Marian then looks the pieces
/// up in its own vocabulary, which is why this returns strings rather than SentencePiece ids.
struct SentencePieceModel: Sendable {
    enum PieceType: Int, Sendable {
        case normal = 1, unknown = 2, control = 3, userDefined = 4, unused = 5, byte = 6
    }

    struct Piece: Sendable {
        let bytes: [UInt8]
        let score: Float
        let type: PieceType
    }

    private let pieces: [Piece]
    private let normalizer: SentencePieceNormalizer
    private let unknownID: Int
    private let minScore: Float
    private let maxScore: Float
    /// Pieces the segmentation may use, keyed by a hash of their bytes. Hashing a growing
    /// prefix one byte at a time finds every piece that starts at a position without building
    /// a trie of a few hundred thousand nodes.
    private let lookup: [UInt64: [Int32]]
    private let longestPiece: Int

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        var pieces: [Piece] = []
        var trainerSpec: ArraySlice<UInt8> = []
        var normalizerSpec: ArraySlice<UInt8> = []
        var reader = ProtobufReader(Array(data)[...])
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, 2): pieces.append(try Self.parsePiece(reader.lengthDelimited()))
            case (2, 2): trainerSpec = try reader.lengthDelimited()
            case (3, 2): normalizerSpec = try reader.lengthDelimited()
            default: try reader.skip(wire)
            }
        }
        guard !pieces.isEmpty else { throw SentencePieceError.malformed("no pieces") }

        var modelType: UInt64 = 1
        var treatWhitespaceAsSuffix = false
        var trainer = ProtobufReader(trainerSpec)
        while let (field, wire) = try trainer.nextField() {
            switch (field, wire) {
            case (3, 0): modelType = try trainer.varint()
            case (24, 0): treatWhitespaceAsSuffix = try trainer.varint() != 0
            default: try trainer.skip(wire)
            }
        }
        guard modelType == 1 else { throw SentencePieceError.unsupported("model type \(modelType) is not unigram") }

        var charsmap: [UInt8] = []
        var addDummyPrefix = true
        var removeExtraWhitespaces = true
        var escapeWhitespaces = true
        var spec = ProtobufReader(normalizerSpec)
        while let (field, wire) = try spec.nextField() {
            switch (field, wire) {
            case (2, 2): charsmap = Array(try spec.lengthDelimited())
            case (3, 0): addDummyPrefix = try spec.varint() != 0
            case (4, 0): removeExtraWhitespaces = try spec.varint() != 0
            case (5, 0): escapeWhitespaces = try spec.varint() != 0
            default: try spec.skip(wire)
            }
        }

        self.pieces = pieces
        normalizer = SentencePieceNormalizer(
            charsmap: charsmap.isEmpty ? nil : try PrecompiledCharsmap(charsmap),
            userDefinedSymbols: pieces.filter { $0.type == .userDefined }.map(\.bytes),
            addDummyPrefix: addDummyPrefix,
            removeExtraWhitespaces: removeExtraWhitespaces,
            escapeWhitespaces: escapeWhitespaces,
            treatWhitespaceAsSuffix: treatWhitespaceAsSuffix
        )
        guard let unknownID = pieces.firstIndex(where: { $0.type == .unknown }) else {
            throw SentencePieceError.malformed("no unknown piece")
        }
        self.unknownID = unknownID

        var minScore = Float.greatestFiniteMagnitude
        var maxScore = -Float.greatestFiniteMagnitude
        var lookup: [UInt64: [Int32]] = [:]
        var longestPiece = 0
        for (id, piece) in pieces.enumerated() {
            if piece.type == .normal {
                minScore = min(minScore, piece.score)
                maxScore = max(maxScore, piece.score)
            }
            // The reference trie holds normal, user-defined and unused pieces; unused ones
            // are found and then skipped, which is the same as leaving them out here.
            guard piece.type == .normal || piece.type == .userDefined, !piece.bytes.isEmpty else { continue }
            var hash = FNV1a()
            piece.bytes.forEach { hash.add($0) }
            lookup[hash.value, default: []].append(Int32(id))
            longestPiece = max(longestPiece, piece.bytes.count)
        }
        self.minScore = minScore
        self.maxScore = maxScore
        self.lookup = lookup
        self.longestPiece = longestPiece
    }

    private static func parsePiece(_ bytes: ArraySlice<UInt8>) throws -> Piece {
        var reader = ProtobufReader(bytes)
        var text: [UInt8] = []
        var score: Float = 0
        var type = PieceType.normal
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, 2): text = Array(try reader.lengthDelimited())
            case (2, 5): score = Float(bitPattern: try reader.fixed32())
            case (3, 0): type = PieceType(rawValue: Int(try reader.varint())) ?? .normal
            default: try reader.skip(wire)
            }
        }
        return Piece(bytes: text, score: score, type: type)
    }

    /// The pieces of `text`, as the reference library's `encode(text, out_type=str)` returns
    /// them. Text no piece covers comes back as itself, a run of such characters merged
    /// into one piece the way `PopulateSentencePieceText` merges them.
    func encode(_ text: String) -> [String] {
        let normalized = normalizer.normalize(Array(text.utf8))
        var merged: [(range: Range<Int>, isUnknown: Bool)] = []
        for (range, id) in segment(normalized) {
            let isUnknown = id == unknownID
            if isUnknown, let last = merged.last, last.isUnknown {
                merged[merged.count - 1].range = last.range.lowerBound..<range.upperBound
            } else {
                merged.append((range, isUnknown))
            }
        }
        return merged.map { String(decoding: normalized[$0.range], as: UTF8.self) }
    }

    /// The unigram Viterbi search, following `unigram::Model::EncodeOptimized`: the best
    /// scoring path through every piece that matches, with a fixed penalty for a character
    /// nothing matches. Ties keep the first path found, as the reference does.
    private func segment(_ text: [UInt8]) -> [(Range<Int>, Int)] {
        let size = text.count
        guard size > 0 else { return [] }
        let unknownScore = minScore - 10
        var bestScore = [Float](repeating: 0, count: size + 1)
        var startsAt = [Int](repeating: -1, count: size + 1)
        var bestID = [Int](repeating: -1, count: size + 1)

        var start = 0
        while start < size {
            let scoreHere = bestScore[start]
            let charLength = min(Self.utf8Length(text[start]), size - start)
            var hasSingleCharacterPiece = false
            var hash = FNV1a()
            var end = start
            while end < size, end - start < longestPiece {
                hash.add(text[end])
                end += 1
                guard let candidates = lookup[hash.value] else { continue }
                let length = end - start
                for candidate in candidates {
                    let piece = pieces[Int(candidate)]
                    guard piece.bytes.count == length, text[start..<end].elementsEqual(piece.bytes) else { continue }
                    let score = piece.type == .userDefined ? Float(length) * maxScore - 0.1 : piece.score
                    let total = score + scoreHere
                    if startsAt[end] == -1 || total > bestScore[end] {
                        bestScore[end] = total
                        startsAt[end] = start
                        bestID[end] = Int(candidate)
                    }
                    if length == charLength { hasSingleCharacterPiece = true }
                }
            }
            if !hasSingleCharacterPiece {
                let end = start + charLength
                let total = unknownScore + scoreHere
                if startsAt[end] == -1 || total > bestScore[end] {
                    bestScore[end] = total
                    startsAt[end] = start
                    bestID[end] = unknownID
                }
            }
            start += charLength
        }

        var result: [(Range<Int>, Int)] = []
        var end = size
        while end > 0 {
            let begin = startsAt[end]
            result.append((begin..<end, bestID[end]))
            end = begin
        }
        return result.reversed()
    }

    static func utf8Length(_ lead: UInt8) -> Int {
        switch lead >> 4 {
        case 0xC, 0xD: 2
        case 0xE: 3
        case 0xF: 4
        default: 1
        }
    }
}

/// SentencePiece's `Normalizer`: the model's compiled normalisation rules (NFKC and friends
/// for Marian) applied longest-match first, with runs of whitespace collapsed, the ends
/// trimmed and every space turned into `▁`.
struct SentencePieceNormalizer: Sendable {
    let charsmap: PrecompiledCharsmap?
    let userDefinedSymbols: [[UInt8]]
    let addDummyPrefix: Bool
    let removeExtraWhitespaces: Bool
    let escapeWhitespaces: Bool
    let treatWhitespaceAsSuffix: Bool

    private static let spaceSymbol: [UInt8] = [0xE2, 0x96, 0x81]

    func normalize(_ input: [UInt8]) -> [UInt8] {
        var position = 0
        if removeExtraWhitespaces {
            while position < input.count {
                let (replacement, consumed) = normalizePrefix(input, at: position)
                guard replacement.elementsEqual([0x20]) else { break }
                position += consumed
            }
        }
        guard position < input.count else { return [] }

        let space = escapeWhitespaces ? Self.spaceSymbol : [0x20]
        var output: [UInt8] = []
        output.reserveCapacity((input.count - position) * 3)
        if !treatWhitespaceAsSuffix && addDummyPrefix { output += space }

        var previousWasSpace = removeExtraWhitespaces
        while position < input.count {
            let (replacement, consumed) = normalizePrefix(input, at: position)
            var piece = replacement[...]
            if previousWasSpace && removeExtraWhitespaces {
                while piece.first == 0x20 { piece = piece.dropFirst() }
            }
            if !piece.isEmpty {
                for byte in piece {
                    if escapeWhitespaces && byte == 0x20 { output += space } else { output.append(byte) }
                }
                previousWasSpace = piece.last == 0x20
            }
            position += consumed
            if !removeExtraWhitespaces { previousWasSpace = false }
        }

        if removeExtraWhitespaces {
            while output.count >= space.count, output.suffix(space.count).elementsEqual(space) {
                output.removeLast(space.count)
            }
        }
        if treatWhitespaceAsSuffix && addDummyPrefix { output += space }
        return output
    }

    /// The normalised form of the text at `position`, and how many input bytes it replaces.
    private func normalizePrefix(_ input: [UInt8], at position: Int) -> (ArraySlice<UInt8>, Int) {
        // User-defined symbols pass through untouched, longest first.
        var longestSymbol = 0
        for symbol in userDefinedSymbols where symbol.count > longestSymbol {
            if input.count - position >= symbol.count,
               input[position..<position + symbol.count].elementsEqual(symbol) {
                longestSymbol = symbol.count
            }
        }
        if longestSymbol > 0 { return (input[position..<position + longestSymbol], longestSymbol) }

        if let charsmap, let (replacement, length) = charsmap.longestMatch(input, at: position) {
            return (replacement, length)
        }
        let length = min(SentencePieceModel.utf8Length(input[position]), input.count - position)
        return (input[position..<position + length], length)
    }
}

/// The `precompiled_charsmap` blob: a Darts-clone double-array trie over UTF-8 byte strings
/// whose values point into a table of NUL-terminated replacements.
struct PrecompiledCharsmap: Sendable {
    private let units: [UInt32]
    private let replacements: [UInt8]

    init(_ blob: [UInt8]) throws {
        guard blob.count >= 4 else { throw SentencePieceError.malformed("charsmap too short") }
        let trieSize = Int(UInt32(blob[0]) | UInt32(blob[1]) << 8 | UInt32(blob[2]) << 16 | UInt32(blob[3]) << 24)
        guard trieSize % 4 == 0, 4 + trieSize <= blob.count else {
            throw SentencePieceError.malformed("charsmap trie size \(trieSize)")
        }
        units = stride(from: 4, to: 4 + trieSize, by: 4).map { offset in
            UInt32(blob[offset]) | UInt32(blob[offset + 1]) << 8 | UInt32(blob[offset + 2]) << 16 | UInt32(blob[offset + 3]) << 24
        }
        replacements = Array(blob[(4 + trieSize)...])
    }

    /// The longest rule matching at `position`, as `Normalizer::NormalizePrefix` picks it.
    func longestMatch(_ input: [UInt8], at position: Int) -> (ArraySlice<UInt8>, Int)? {
        guard !units.isEmpty else { return nil }
        var node = Int(Self.offset(units[0]))
        var best: (value: Int, length: Int)?
        var index = position
        while index < input.count {
            let byte = input[index]
            node ^= Int(byte)
            guard node < units.count else { break }
            let unit = units[node]
            guard Self.label(unit) == UInt32(byte) else { break }
            node ^= Int(Self.offset(unit))
            index += 1
            if Self.hasLeaf(unit), node < units.count {
                best = (Int(units[node] & 0x7FFF_FFFF), index - position)
            }
        }
        guard let best, best.value < replacements.count else { return nil }
        let end = replacements[best.value...].firstIndex(of: 0) ?? replacements.endIndex
        return (replacements[best.value..<end], best.length)
    }

    private static func hasLeaf(_ unit: UInt32) -> Bool { (unit >> 8) & 1 == 1 }
    private static func label(_ unit: UInt32) -> UInt32 { unit & (0x8000_0000 | 0xFF) }
    private static func offset(_ unit: UInt32) -> UInt32 { (unit >> 10) << ((unit & (1 << 9)) >> 6) }
}

/// Just enough protobuf to read a SentencePiece model.
private struct ProtobufReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
    }

    mutating func nextField() throws -> (Int, Int)? {
        guard !bytes.isEmpty else { return nil }
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = bytes.popFirst() {
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            guard shift < 64 else { break }
        }
        throw SentencePieceError.malformed("truncated varint")
    }

    mutating func fixed32() throws -> UInt32 {
        guard bytes.count >= 4 else { throw SentencePieceError.malformed("truncated fixed32") }
        let start = bytes.startIndex
        let value = UInt32(bytes[start]) | UInt32(bytes[start + 1]) << 8 | UInt32(bytes[start + 2]) << 16 | UInt32(bytes[start + 3]) << 24
        bytes = bytes.dropFirst(4)
        return value
    }

    mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
        let length = Int(try varint())
        guard length >= 0, bytes.count >= length else { throw SentencePieceError.malformed("truncated field") }
        let value = bytes.prefix(length)
        bytes = bytes.dropFirst(length)
        return value
    }

    mutating func skip(_ wireType: Int) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1:
            guard bytes.count >= 8 else { throw SentencePieceError.malformed("truncated fixed64") }
            bytes = bytes.dropFirst(8)
        case 2: _ = try lengthDelimited()
        case 5: _ = try fixed32()
        default: throw SentencePieceError.malformed("wire type \(wireType)")
        }
    }
}

/// 64-bit FNV-1a, fed one byte at a time.
private struct FNV1a {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func add(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
}
