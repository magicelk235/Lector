import Foundation

/// A paragraph with its glossary terms swapped out for marks the translators carry
/// through untouched, and put back into the translation afterwards.
///
/// Neither Apple's translation nor the offline packs take a glossary, so the terms are
/// hidden from them: "Talk to Zelda before you leave Kakariko" goes out as "Talk to
/// ZX1Q before you leave ZX2Q", and the translation gets "Zelda" and the term's own
/// translation back in their places. Marks of that shape came back intact from both
/// engines, in place and with the sentence translated around them, from English,
/// French, German and Japanese into Hebrew, English and Japanese (measured on macOS
/// 27); bracketed ones and numbers did not — a number was translated as a quantity.
struct GlossaryText: Equatable {
    /// What the translators are given.
    let text: String
    /// What each mark stands for in the translation: the first for ZX1Q, and so on.
    let replacements: [String]

    /// - Parameter target: the language translated into; a term's translation applies
    ///   only to translations into its own language, a kept term to all of them.
    init(_ text: String, terms: [GlossaryTerm], target: String) {
        let applicable = terms
            .filter { !$0.original.isEmpty && ($0.translation == nil || $0.target == target) }
            .sorted { $0.original.count > $1.original.count }
        // Text that already has something shaped like a mark couldn't be told from one.
        guard !applicable.isEmpty, text.range(of: "zx", options: .caseInsensitive) == nil else {
            self.text = text
            replacements = []
            return
        }
        // Longest first, so "Hyrule Castle" goes as one before "Hyrule" could split it.
        var found: [(range: Range<String.Index>, replacement: String)] = []
        for term in applicable {
            var from = text.startIndex
            while let range = text.range(of: term.original, options: [.caseInsensitive], range: from..<text.endIndex) {
                from = range.upperBound
                guard Self.isWhole(range, in: text), !found.contains(where: { $0.range.overlaps(range) }) else { continue }
                // A kept term comes back the way this text has it, capitals and all.
                found.append((range, term.translation ?? String(text[range])))
            }
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var marked = ""
        var at = text.startIndex
        for (number, match) in found.enumerated() {
            marked += text[at..<match.range.lowerBound]
            marked += Self.mark(number + 1)
            at = match.range.upperBound
        }
        marked += text[at...]
        self.text = marked
        replacements = found.map(\.replacement)
    }

    static func mark(_ number: Int) -> String {
        "ZX\(number)Q"
    }

    /// The translation with each mark replaced by what it stands for. A translator that
    /// spaced a mark out or changed its case still has it found.
    func restore(_ translation: String) -> String {
        guard !replacements.isEmpty else { return translation }
        var result = ""
        var at = translation.startIndex
        for match in translation.matches(of: Self.markPattern) {
            guard let number = Int(match.output.1), replacements.indices.contains(number - 1) else { continue }
            result += translation[at..<match.range.lowerBound]
            result += replacements[number - 1]
            at = match.range.upperBound
        }
        result += translation[at...]
        return result
    }

    /// Nothing to translate around the terms: a label that is just a name. The
    /// translation is the terms themselves.
    var isOnlyTerms: Bool {
        !replacements.isEmpty && !text.replacing(Self.markPattern, with: "").contains(where: { $0.isLetter })
    }

    nonisolated(unsafe) private static let markPattern = #/[Zz]\s?[Xx]\s?(\d+)\s?[Qq]/#

    /// Whether `range` is a whole word of `text`, not part of a longer one: "Link" in
    /// "Link's" but not in "Linked". Scripts written without spaces have no word edges
    /// to look for, so there any match counts.
    private static func isWhole(_ range: Range<String.Index>, in text: String) -> Bool {
        let first = text[range.lowerBound], last = text[text.index(before: range.upperBound)]
        if range.lowerBound > text.startIndex, isSpacedWordCharacter(first),
           isSpacedWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isSpacedWordCharacter(last), isSpacedWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func isSpacedWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF, // Thai, Lao
             0x0F00...0x0FFF, // Tibetan
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF, // Khmer
             0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, // kana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: // Han
            return false
        default:
            return true
        }
    }
}

extension [GlossaryTerm] {
    /// The term for `original`, matched as glossary matching does: whatever the case.
    func firstIndex(matching original: String) -> Int? {
        firstIndex { $0.original.compare(original, options: .caseInsensitive) == .orderedSame }
    }
}
