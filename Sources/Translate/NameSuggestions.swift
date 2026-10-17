import Foundation
import NaturalLanguage

/// Names that keep turning up in an app's text — a game's characters and places —
/// offered for its glossary, so they stop being translated as words ("Cloud" as a
/// cloud) or spelled a new way in every line.
///
/// Held in memory only, like `TranslationMemory`: nothing captured is written anywhere
/// until the user adds a name to a glossary themselves.
@MainActor
@Observable
final class NameSuggestions {
    /// A name is offered once it has been seen in this many different paragraphs.
    static let threshold = 2

    /// Per app, per name, the paragraphs it was seen in, by hash.
    private var seen: [String: [String: Set<Int>]] = [:]
    /// Per app, the names already offered over a capture, which aren't offered there again.
    private var offered: [String: Set<String>] = [:]

    func note(_ paragraphs: [String], app: String) {
        var names = seen[app, default: [:]]
        for paragraph in paragraphs {
            let hash = paragraph.hashValue
            for name in Self.candidates(in: paragraph) {
                names[name, default: []].insert(hash)
            }
        }
        seen[app] = names
    }

    /// Names worth adding to `app`'s glossary, the most often seen first: never one
    /// already in `glossary`.
    func suggestions(for app: String, excluding glossary: [GlossaryTerm]) -> [String] {
        (seen[app] ?? [:])
            .filter { $0.value.count >= Self.threshold && glossary.firstIndex(matching: $0.key) == nil }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map(\.key)
    }

    /// The name to offer over a capture of `paragraphs` from `app`: one of its
    /// suggestions that this capture has in it and that hasn't been offered before.
    /// Offering it marks it, so a name the user passes over isn't offered again.
    func offer(for app: String, in paragraphs: [String], excluding glossary: [GlossaryTerm]) -> String? {
        let here = Set(paragraphs.flatMap(Self.candidates))
        guard let name = suggestions(for: app, excluding: glossary)
            .first(where: { here.contains($0) && !offered[app, default: []].contains($0) })
        else { return nil }
        offered[app, default: []].insert(name)
        return name
    }

    /// The apps that have something to suggest, for Settings.
    func apps(excluding glossaries: [String: [GlossaryTerm]]) -> [String] {
        seen.keys.filter { !suggestions(for: $0, excluding: glossaries[$0] ?? []).isEmpty }.sorted()
    }

    /// What in `paragraph` could be a name: what the system's name tagger finds (it
    /// knows English, French, German and a few more), and in scripts with capitals,
    /// capitalised words in the middle of a sentence, which in running text are names
    /// far more often than not. Neighbouring ones go together, as "Hyrule Castle".
    /// Scripts without capitals give the second nothing to go on, so Japanese and
    /// Chinese names come only from the tagger, which reads few of them.
    nonisolated static func candidates(in paragraph: String) -> [String] {
        var found: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = paragraph
        tagger.enumerateTags(in: paragraph.startIndex..<paragraph.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                found.append(String(paragraph[range]))
            }
            return true
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = paragraph
        var run: [Range<String.Index>] = []
        func flush() {
            if let first = run.first, let last = run.last {
                found.append(String(paragraph[first.lowerBound..<last.upperBound]))
            }
            run = []
        }
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            guard isCapitalised(paragraph[range]) else {
                flush()
                return true
            }
            // The next word of a name already started goes with it; a new one counts
            // only away from the start of a sentence.
            if continuesRun(run, at: range, in: paragraph) {
                run.append(range)
            } else {
                flush()
                if !startsSentence(at: range.lowerBound, in: paragraph) { run.append(range) }
            }
            return true
        }
        flush()

        var unique: [String] = []
        for name in found where name.count >= 2 && !unique.contains(name) {
            unique.append(name)
        }
        return unique
    }

    /// "Zelda", "Наташа": a capital, then at least one lower-case letter, so neither
    /// "I" nor a word in capitals for emphasis ("SAVE").
    private nonisolated static func isCapitalised(_ word: Substring) -> Bool {
        guard let first = word.first, first.isUppercase, word.count >= 2 else { return false }
        return word.dropFirst().contains(where: \.isLowercase) && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
    }

    /// Whether a word at `index` begins a sentence, where every word has a capital.
    private nonisolated static func startsSentence(at index: String.Index, in text: String) -> Bool {
        var at = index
        while at > text.startIndex {
            at = text.index(before: at)
            let character = text[at]
            if character.isWhitespace || "\"“”«»„'‘’([¿¡".contains(character) { continue }
            return ".!?:;…—–-•。！？：".contains(character)
        }
        return true
    }

    /// Whether `range` follows the last word of `run` with only a space between: the
    /// next word of the same name.
    private nonisolated static func continuesRun(_ run: [Range<String.Index>], at range: Range<String.Index>,
                                                 in text: String) -> Bool {
        guard let last = run.last else { return false }
        return text[last.upperBound..<range.lowerBound] == " "
    }
}
