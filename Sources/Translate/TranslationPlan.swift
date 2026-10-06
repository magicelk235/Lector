import Foundation
import LectorKit

/// What happens to each paragraph of a capture: translated from the language it is
/// in, or left exactly as it is on screen.
///
/// Left alone: paragraphs already in the target language, and those a translator could
/// only damage — numbers, keyboard shortcuts, code, addresses (`Untranslatable`). A
/// capture is read paragraph by paragraph, so a chat in three languages comes out as
/// three translations instead of two of them passed through as "the same language".
struct TranslationPlan {
    enum Item: Equatable {
        case keep
        case translate(Locale.Language)
    }

    /// What the capture as a whole comes to.
    enum Outcome: Equatable {
        case translate
        /// Every word in it is in the target language already.
        case alreadyInTarget
        /// Only numbers, shortcuts, code and addresses.
        case nothingToTranslate
        /// Words, but in no language that could be told.
        case unknownLanguage
    }

    /// Paragraphs in one language, in reading order: they go to the same engines.
    struct Group: Equatable {
        let source: Locale.Language
        let paragraphs: [Int]
    }

    /// One per paragraph.
    let items: [Item]
    /// By language, the language of the first paragraph read first. Simplified and
    /// Traditional Chinese are two.
    let groups: [Group]
    /// The language most of the text to translate is in.
    let source: Locale.Language?
    let outcome: Outcome

    /// - Parameters:
    ///   - chosen: the language the user said the text is in, if they did.
    ///   - firmly: chosen for this very text (Tab), not remembered from before.
    init(_ texts: [String], target: Locale.Language, choosing chosen: Locale.Language?, firmly: Bool = false,
         preferring preferred: [String] = LanguageDetector.defaultPreferred) {
        let detected = LanguageDetector.languages(of: texts, preferring: preferred, choosing: chosen, firmly: firmly)
        var items: [Item] = []
        var inTarget = false, undetermined = false
        for (index, text) in texts.enumerated() {
            guard Untranslatable.kind(of: text) == nil else {
                items.append(.keep)
                continue
            }
            guard let language = detected.languages[index] else {
                undetermined = undetermined || text.contains(where: \.isLetter)
                items.append(.keep)
                continue
            }
            if LanguageDetector.same(language, target) {
                inTarget = true
                items.append(.keep)
            } else {
                items.append(.translate(language))
            }
        }
        self.items = items

        var groups: [Group] = []
        for (index, item) in items.enumerated() {
            guard case .translate(let source) = item else { continue }
            if let at = groups.firstIndex(where: { LanguageDetector.same($0.source, source) }) {
                groups[at] = Group(source: groups[at].source, paragraphs: groups[at].paragraphs + [index])
            } else {
                groups.append(Group(source: source, paragraphs: [index]))
            }
        }
        self.groups = groups
        source = groups.max { a, b in
            a.paragraphs.reduce(0) { $0 + texts[$1].count } < b.paragraphs.reduce(0) { $0 + texts[$1].count }
        }?.source

        outcome = if !groups.isEmpty { .translate }
            else if undetermined { .unknownLanguage }
            else if inTarget { .alreadyInTarget }
            else { .nothingToTranslate }
    }

    /// The paragraphs that are to be translated.
    var translated: [Int] {
        groups.flatMap(\.paragraphs)
    }
}

/// Neighbouring paragraphs sent to Apple's translation as one line, with a mark between
/// them, and split back apart at the marks.
///
/// Apple translates line by line: each paragraph alone, however the request is cut,
/// knows nothing of the others. On one line they are context for each other, and it
/// shows — measured on macOS 27, into Hebrew: the settings labels "General", "Save",
/// "Cancel" came back as the army rank, "rescued" and "he cancelled" one at a time, and
/// as the settings words together; "It is red" after "I bought a car" took the car's
/// gender, and "bank" after a walk along the river became the riverbank. The marks come
/// back in place, so each paragraph still lands in its own spot on screen, and the
/// labels took 25% less time together than one by one. A translation whose marks don't
/// match up is sent again paragraph by paragraph.
enum ContextWindows {
    /// The marks, in order of preference; one that the text itself contains is skipped.
    static let separators = [" | ", " · ", " ¶ "]
    /// The first window's size in characters when nothing else is on screen meanwhile:
    /// a sentence or a few labels, back in about half a second.
    static let lead = 40

    /// Consecutive paragraphs grouped for one request each, in reading order: up to
    /// `maxCount` of them and `maxCharacters` together, and a paragraph of `alone`
    /// characters or more by itself — it is context enough for itself, and a long
    /// window would hold every paragraph in it back until the longest is done.
    /// Characters are counted as `weight` counts them.
    ///
    /// - Parameter lead: when set, the first window holds no more than this many
    ///   characters (and at least one paragraph), so something lands soon where there's
    ///   no offline draft to look at meanwhile.
    static func windows(_ texts: [String], maxCharacters: Int = 360, maxCount: Int = 16,
                        alone: Int = 240, lead: Int? = nil) -> [Range<Int>] {
        let weights = texts.map(weight)
        var windows: [Range<Int>] = []
        var start = 0, characters = 0
        for index in texts.indices {
            let limit = windows.isEmpty ? min(lead ?? maxCharacters, maxCharacters) : maxCharacters
            let full = index - start >= maxCount || characters + weights[index] > limit
            if index > start, full || weights[index] >= alone || weights[index - 1] >= alone {
                windows.append(start..<index)
                start = index
                characters = 0
            }
            characters += weights[index]
        }
        if start < texts.count { windows.append(start..<texts.count) }
        return windows
    }

    /// Characters, with each of a script written without spaces counted three times:
    /// one carries about as much as a short word, and takes as long to translate.
    static func weight(_ text: String) -> Int {
        text.reduce(0) { $0 + (Paragraphs.isSpaceless($1) ? 3 : 1) }
    }

    /// The first mark none of `texts` contains, or nil when they use all of them.
    static func separator(for texts: [String]) -> String? {
        separators.first { separator in
            let mark = separator.trimmingCharacters(in: .whitespaces)
            return !texts.contains { $0.contains(mark) }
        }
    }

    static func join(_ texts: [String], separator: String) -> String {
        texts.joined(separator: separator)
    }

    /// `count` parts, or nil when the translation has more or fewer marks than were
    /// sent, or an empty part between two.
    static func split(_ translation: String, separator: String, count: Int) -> [String]? {
        let mark = separator.trimmingCharacters(in: .whitespaces)
        let parts = translation.components(separatedBy: mark).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == count, !parts.contains(where: \.isEmpty) else { return nil }
        return parts
    }
}
