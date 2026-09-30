import Foundation

/// Marian's tokenizer, as `transformers.MarianTokenizer` defines it: the source language's
/// SentencePiece model splits the text, and the pieces are then looked up in the model's own
/// `vocab.json`, which is shared by both languages. Output ids go back through the same
/// vocabulary, or `target_vocab.json` when the model keeps the two apart.
struct MarianTokenizer: Sendable {
    private let source: SentencePieceModel
    private let sourceVocabulary: [String: Int]
    private let targetPieces: [String]
    private let eosID: Int
    private let unknownID: Int
    /// Ids `decode` leaves out: `</s>`, `<pad>`, `<unk>` and the `>>xxx<<` language tokens.
    private let skippedIDs: Set<Int>

    init(directory: URL) throws {
        source = try SentencePieceModel(contentsOf: directory.appending(path: "source.spm"))
        sourceVocabulary = try Self.readVocabulary(directory.appending(path: "vocab.json"))
        let targetURL = directory.appending(path: "target_vocab.json")
        let targetVocabulary = FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false))
            ? try Self.readVocabulary(targetURL)
            : sourceVocabulary
        var targetPieces = [String](repeating: "", count: (targetVocabulary.values.max() ?? -1) + 1)
        for (piece, id) in targetVocabulary where id >= 0 { targetPieces[id] = piece }
        self.targetPieces = targetPieces

        guard let eos = sourceVocabulary["</s>"], let unknown = sourceVocabulary["<unk>"] else {
            throw SentencePieceError.malformed("vocabulary lacks </s> or <unk>")
        }
        eosID = eos
        unknownID = unknown
        var skipped = Set(["</s>", "<unk>", "<pad>"].compactMap { targetVocabulary[$0] })
        for (piece, id) in targetVocabulary where piece.hasPrefix(">>") && piece.hasSuffix("<<") {
            skipped.insert(id)
        }
        skippedIDs = skipped
    }

    private static func readVocabulary(_ url: URL) throws -> [String: Int] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw SentencePieceError.malformed("\(url.lastPathComponent) is not an object")
        }
        return dictionary.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// Source ids for `text`, ending in `</s>`, behind the target-language token when the
    /// model needs one. Pieces the vocabulary lacks become `<unk>`, as in transformers.
    func encode(_ text: String, languageToken: String? = nil) -> [Int] {
        var ids: [Int] = []
        if let languageToken, let id = sourceVocabulary[languageToken] { ids.append(id) }
        for piece in source.encode(text) {
            ids.append(sourceVocabulary[piece] ?? unknownID)
        }
        ids.append(eosID)
        return ids
    }

    /// Text for generated ids, as `decode(ids, skip_special_tokens=True)` gives it.
    func decode(_ ids: [Int]) -> String {
        var text = ""
        for id in ids where id >= 0 && id < targetPieces.count && !skippedIDs.contains(id) {
            text += targetPieces[id]
        }
        return text.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
