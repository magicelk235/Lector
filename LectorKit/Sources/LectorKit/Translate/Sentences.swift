import Foundation
import NaturalLanguage

/// Where the sentences of a paragraph end, so the translation models get one at a time.
///
/// `NLTokenizer` does most of it, but only knows a language's own marks when told the
/// language: left to guess, it ran a Greek question (`;`) into the sentence after it.
/// So it is told, and as it can still miss a mark in a short paragraph, every piece it
/// returns is cut again after any mark that ends a sentence in `language` and is
/// followed by a space — or by anything, for the full-width marks of Chinese and
/// Japanese, which take no space.
enum Sentences {
    /// `text` cut into sentences, each keeping the spaces after it, so the pieces join
    /// back into `text`.
    static func split(_ text: String, in language: Locale.Language?) -> [String] {
        let greek = language?.languageCode?.identifier == "el"
        return units(of: text, .sentence, in: language).flatMap { cutAfterTerminators($0, semicolonEnds: greek) }
    }

    /// `text` cut at the boundaries of `unit`, with whatever lies between two units
    /// (spaces, punctuation) kept on the first, so the pieces join back into `text`.
    static func units(of text: String, _ unit: NLTokenUnit, in language: Locale.Language?) -> [String] {
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.string = text
        if let language = language.flatMap(naturalLanguage) { tokenizer.setLanguage(language) }
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard !ranges.isEmpty else { return [text] }
        return ranges.indices.map { index in
            let start = index == 0 ? text.startIndex : ranges[index].lowerBound
            let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            return String(text[start..<end])
        }
    }

    /// Marks that end a sentence when a space follows: Latin and Greek `!` `?`, Arabic
    /// `؟`, Urdu `۔`, Devanagari `।` `॥`, Armenian `։`, Ethiopic `።` `፧` and Burmese
    /// `။`. Greek's question mark is `;` once normalised, so only Greek gets that one. The
    /// full stop is left to `NLTokenizer`, which knows "Dr." and "e.g." aren't the end of
    /// anything.
    private static let spacedTerminators: Set<Character> = [
        "!", "?", "‼", "⁇", "⁈", "⁉", "؟", "۔", "।", "॥", "։", "።", "፧", "။",
    ]
    /// Chinese and Japanese marks, which end a sentence with no space after them.
    private static let unspacedTerminators: Set<Character> = ["。", "！", "？", "｡"]
    /// What may follow the mark and still belong to the sentence it ends.
    private static let closers: Set<Character> = [
        "\"", "'", "”", "’", "»", "›", ")", "]", "}", "」", "』", "】", "）", "〉", "》",
    ]

    private static func cutAfterTerminators(_ text: String, semicolonEnds: Bool) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let spaced = spacedTerminators.contains(character) || (semicolonEnds && character == ";")
            guard spaced || unspacedTerminators.contains(character) else {
                index = text.index(after: index)
                continue
            }
            // The rest of the ending: more marks ("?!"), closing quotes and brackets.
            var end = text.index(after: index)
            while end < text.endIndex, spacedTerminators.contains(text[end]) || unspacedTerminators.contains(text[end])
                    || closers.contains(text[end]) {
                end = text.index(after: end)
            }
            var next = end
            while next < text.endIndex, text[next].isWhitespace {
                next = text.index(after: next)
            }
            let ends = next < text.endIndex && (next > end || !spaced)
            if ends {
                pieces.append(String(text[start..<next]))
                start = next
            }
            index = next
        }
        if start < text.endIndex { pieces.append(String(text[start...])) }
        return pieces.isEmpty ? [text] : pieces
    }

    private static func naturalLanguage(_ language: Locale.Language) -> NLLanguage? {
        guard let code = language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return NLLanguage(rawValue: code) }
        let script = language.script?.identifier
            ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier
        return script == "Hant" ? .traditionalChinese : .simplifiedChinese
    }
}
