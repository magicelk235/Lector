import Foundation
import NaturalLanguage

/// Works out what language a piece of recognised text is in.
///
/// A line of real text is easy: every language measured scores 0.99–1.00. Short screen
/// text — a table cell, a button, a menu item — is not: "Feature" scores English 0.49,
/// "Settings" 0.33, and "Menu" comes back Indonesian at 0.54 with English at 0.09.
/// Refusing to guess makes translation fail on exactly the text people point it at,
/// and a wrong guess of a close language costs little next to translating nothing.
///
/// So a weak reading is settled by the languages the user actually reads: when one of
/// them is among the recogniser's candidates at all, it's the likelier answer than an
/// unfamiliar language that merely scored higher. Failing that, by the languages most
/// people read: one misread word makes a Russian menu Kazakh at 0.62, with Russian at
/// 0.38 beside it.
///
/// Some languages the recogniser can't tell at all, and their letters can: it has no
/// Serbian or Macedonian (both read to it as Bulgarian or Kazakh, with certainty) and
/// reads Persian as Arabic at 0.999.
public enum LanguageDetector {
    /// At or above this the recogniser is taken at its word.
    static let confident = 0.8
    /// A preferred language this plausible settles a weak reading in its favour.
    static let preferredFloor = 0.05
    /// Failing that, the top guess is still used if it's at least an even bet.
    static let evenBet = 0.5

    /// The language of `text`, or nil when there's nothing to go on.
    ///
    /// - Parameter preferring: BCP-47 codes of the languages the user reads, most
    ///   preferred first. Defaults to the system's preferred languages plus English.
    public static func language(of text: String,
                                preferring preferred: [String] = defaultPreferred) -> Locale.Language? {
        pick(hypotheses(for: text), preferring: preferred)
    }

    private static func pick(_ hypotheses: [(key: NLLanguage, value: Double)], preferring preferred: [String]) -> Locale.Language? {
        guard let top = hypotheses.first else { return nil }

        if top.value >= confident { return language(top.key) }

        let preferredCodes = preferred.map(code)
        for wanted in preferredCodes {
            if let match = hypotheses.first(where: { code($0.key.rawValue) == wanted }),
               match.value >= preferredFloor {
                return language(match.key)
            }
        }

        // A less used language leading a weak reading gives way to a widely used one of
        // its script that the recogniser finds plausible too.
        if !widelyUsed.contains(code(top.key.rawValue)) {
            let script = scripts(of: language(top.key))
            if let major = hypotheses.first(where: { candidate in
                widelyUsed.contains(code(candidate.key.rawValue)) && candidate.value >= preferredFloor
                    && !scripts(of: language(candidate.key)).isDisjoint(with: script)
            }) {
                return language(major.key)
            }
        }

        return top.value >= evenBet ? language(top.key) : nil
    }

    /// The languages macOS itself comes in, and the most spoken of the rest that share a
    /// script with one of them: what a weak reading in their script most likely is,
    /// rather than a smaller neighbour such as Kazakh or Bulgarian beside Russian.
    static let widelyUsed: Set<String> = [
        "ar", "ca", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja",
        "ko", "ms", "no", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk", "vi", "zh",
        "fa", "mr", "ur",
    ]

    public static var defaultPreferred: [String] {
        var codes = Locale.preferredLanguages.map(code)
        if !codes.contains("en") { codes.append("en") }
        return codes
    }

    // MARK: - Paragraph by paragraph

    public struct ParagraphLanguages: Sendable, Equatable {
        /// The language most of the capture's letters are in.
        public let dominant: Locale.Language?
        /// One per paragraph; nil where there are no letters to go on.
        public let languages: [Locale.Language?]
    }

    /// Each paragraph's language, so a screen in several languages keeps them all.
    ///
    /// Short text is where the recogniser guesses: "Options" comes back English at 0.90,
    /// "[E] Continue" Portuguese at 0.75, "Menu" Indonesian. So a paragraph of a few
    /// words is taken to be in the language of the rest of the capture — the language of
    /// its plainly readable paragraphs — whenever it's written in that language's script,
    /// unless the recogniser is all but certain otherwise ("Général" is French at 1.00).
    /// A "Menu" among French paragraphs is French, though the user reads English.
    ///
    /// Kanji alone gets its own rules (`kanji(_:_:_:remembering:)`): Japanese and Chinese
    /// write most of it alike, so it is never left without a language for being short.
    ///
    /// - Parameters:
    ///   - chosen: the language the user said the text is in. Remembered from an
    ///     earlier capture of the app, it settles what the recogniser can't: a paragraph
    ///     it finds the chosen language plausible for, reads only weakly, or can't tell
    ///     at all — kanji nothing else on the page settles, and Serbian, Macedonian or
    ///     Persian, which it doesn't have, so they're whatever the letters don't rule
    ///     out. Not a word it plainly reads otherwise: "Enregistrer" is French at 0.93
    ///     however the app was last read.
    ///   - firmly: the choice was made for this very text, so it decides every paragraph
    ///     in its script.
    public static func languages(of paragraphs: [String], preferring preferred: [String] = defaultPreferred,
                                 choosing chosen: Locale.Language? = nil, firmly: Bool = false) -> ParagraphLanguages {
        let readings = paragraphs.map { paragraph -> Reading? in
            guard paragraph.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
            return Reading(paragraph)
        }
        let anchors = zip(paragraphs, readings).map { paragraph, reading in
            (paragraph, reading.flatMap { $0.isPlain ? $0.top : nil })
        }
        let capture = mostWritten(anchors) ?? language(of: paragraphs.joined(separator: "\n"), preferring: preferred)
        // What the recogniser makes of a short paragraph says nothing against a language
        // it doesn't have: "Уреди" in a Serbian menu is Bulgarian to it at 0.995.
        let captureUnread = capture.map { toldByLetters.contains(code($0)) } ?? false
        let page = KanjiEvidence(paragraphs, readings)

        /// What the paragraph is in by detection alone.
        func detect(_ paragraph: String, _ reading: Reading) -> Locale.Language? {
            if reading.isKanjiOnly { return kanji(paragraph, reading, page, remembering: nil) }
            if let capture, isWritten(paragraph, in: capture) {
                let agrees = reading.hypotheses.contains { same(language($0.key), capture) && $0.value >= preferredFloor }
                if reading.isShort,
                   captureUnread || reading.confidence < certain || reading.top.map({ same($0, capture) }) == true {
                    return capture
                }
                if reading.confidence < confident, agrees { return capture }
            }
            if reading.confidence >= confident { return reading.top }
            return pick(reading.hypotheses, preferring: preferred)
                ?? capture.flatMap { isWritten(paragraph, in: $0) ? $0 : nil }
        }

        var languages: [Locale.Language?] = []
        for (paragraph, reading) in zip(paragraphs, readings) {
            guard let reading else {
                languages.append(nil)
                continue
            }
            var language = detect(paragraph, reading)
            if let chosen, isWritten(paragraph, in: chosen) {
                if firmly || !reading.isKanjiOnly && reading.leavesOpen(chosen) {
                    language = chosen
                } else if reading.isKanjiOnly {
                    language = kanji(paragraph, reading, page, remembering: chosen)
                }
            }
            languages.append(language)
        }
        return ParagraphLanguages(dominant: mostWritten(Array(zip(paragraphs, languages))) ?? capture,
                                  languages: languages)
    }

    // MARK: Kanji

    /// The language of a paragraph of kanji alone. Japanese and Chinese write most kanji
    /// alike: "設定" is both, and the recogniser reads it as Chinese at 0.60. It is all
    /// but certain only where a form is one language's own — "検索" Japanese at 1.00,
    /// "刪除" Traditional and "设置" Simplified Chinese — and measured on 78 Japanese
    /// words, never certain of Chinese on one. So in turn:
    ///
    /// - Such a form settles the paragraph.
    /// - Then the page's Japanese or Chinese: kana read as Japanese, or text read with
    ///   certainty as either.
    /// - Then a language remembered for the app, written in kanji.
    /// - Then Chinese: Traditional or Simplified by the forms of its characters (設/设,
    ///   刪/删, 檢/检), else of the page's, else Simplified, which most of its readers
    ///   write. A Chinese paragraph or choice takes its script from the forms too, when
    ///   they tell.
    private static func kanji(_ paragraph: String, _ reading: Reading, _ page: KanjiEvidence,
                              remembering chosen: Locale.Language?) -> Locale.Language {
        if reading.confidence >= certain, let top = reading.top { return top }
        let forms = chineseScript(of: paragraph)
        if let text = page.text {
            return code(text) == "zh" ? forms ?? text : text
        }
        if let chosen {
            return code(chosen) == "zh" ? forms ?? chosen : chosen
        }
        return forms ?? page.forms ?? simplifiedChinese
    }

    private static let simplifiedChinese = Locale.Language(identifier: "zh-Hans")
    private static let traditionalChinese = Locale.Language(identifier: "zh-Hant")

    /// Traditional or Simplified Chinese, by the forms the characters of `text` are in —
    /// the more of them — or nil when it has none the two write differently.
    private static func chineseScript(of text: String) -> Locale.Language? {
        var traditional = 0, simplified = 0
        for scalar in text.unicodeScalars where Script.of(scalar) == .han {
            let character = String(scalar)
            if character.applyingTransform(StringTransform("Hant-Hans"), reverse: false) != character { traditional += 1 }
            if character.applyingTransform(StringTransform("Hans-Hant"), reverse: false) != character { simplified += 1 }
        }
        if traditional > simplified { return traditionalChinese }
        if simplified > traditional { return simplifiedChinese }
        return nil
    }

    /// What a capture says about its paragraphs of kanji alone, worked out once, and only
    /// if one needs it.
    private final class KanjiEvidence {
        private let paragraphs: [String]
        private let readings: [Reading?]

        init(_ paragraphs: [String], _ readings: [Reading?]) {
            self.paragraphs = paragraphs
            self.readings = readings
        }

        /// The language of the capture's Japanese or Chinese that tells — kana read as
        /// Japanese, or text read with certainty as either — the one most letters are in.
        lazy var text: Locale.Language? = LanguageDetector.mostWritten(zip(paragraphs, readings).map { paragraph, reading in
            (paragraph, reading.flatMap { $0.tellsKanji ? $0.top : nil })
        })

        /// Traditional or Simplified, by the forms of all the capture's characters.
        lazy var forms: Locale.Language? = LanguageDetector.chineseScript(of: paragraphs.joined())
    }

    /// Past this a short paragraph's own reading beats the rest of the capture's.
    static let certain = 0.99

    /// Languages the recogniser doesn't have, told here by their letters alone.
    static let toldByLetters: Set<String> = ["sr", "mk", "fa"]

    /// What the recogniser makes of one paragraph.
    private struct Reading {
        let hypotheses: [(key: NLLanguage, value: Double)]
        /// A few words, or a few characters of a script written without spaces.
        let isShort: Bool
        let isKanjiOnly: Bool
        let hasKana: Bool
        let spelling: Spelling

        init(_ paragraph: String) {
            spelling = Spelling(paragraph)
            hypotheses = LanguageDetector.hypotheses(for: paragraph, spelling: spelling)
            let scripts = Script.histogram(of: paragraph)
            let unspaced = scripts.filter { $0.key.joinsWithoutSpaces }.values.reduce(0, +)
            isShort = unspaced * 2 > scripts.values.reduce(0, +)
                ? unspaced <= 6
                : paragraph.split(whereSeparator: \.isWhitespace).filter {
                    $0.unicodeScalars.contains(where: CharacterSet.letters.contains)
                }.count <= 3
            isKanjiOnly = Set(scripts.keys) == [.han]
            hasKana = scripts[.kana] != nil
        }

        var top: Locale.Language? { hypotheses.first.map { LanguageDetector.language($0.key) } }
        var confidence: Double { hypotheses.first?.value ?? 0 }
        /// Long enough, and read with confidence: this one can be taken at its word.
        var isPlain: Bool { !isShort && confidence >= LanguageDetector.confident }

        /// Japanese or Chinese that says which the capture's kanji is: kana read as
        /// Japanese, or either read with certainty.
        var tellsKanji: Bool {
            switch top.map(LanguageDetector.code) {
            case "ja": hasKana || confidence >= LanguageDetector.certain
            case "zh": confidence >= LanguageDetector.certain
            default: false
            }
        }

        /// Whether `language` is as good an answer as the recogniser has: it finds it
        /// plausible or reads nothing better than a coin toss — or, for a language it
        /// doesn't have, the letters don't rule it out.
        func leavesOpen(_ language: Locale.Language) -> Bool {
            let code = LanguageDetector.code(language)
            if LanguageDetector.toldByLetters.contains(code) { return spelling.allows(code) }
            return confidence < LanguageDetector.evenBet || hypotheses.contains {
                LanguageDetector.same(LanguageDetector.language($0.key), language) && $0.value >= LanguageDetector.preferredFloor
            }
        }
    }

    /// The language with the most letters written in it.
    private static func mostWritten(_ paragraphs: [(String, Locale.Language?)]) -> Locale.Language? {
        var letters: [String: (language: Locale.Language, count: Int)] = [:]
        for (paragraph, language) in paragraphs {
            guard let language else { continue }
            let count = paragraph.unicodeScalars.filter(CharacterSet.letters.contains).count
            letters[key(language), default: (language, 0)].count += count
        }
        return letters.values.max { $0.count < $1.count }?.language
    }

    /// Languages `text` might be in, likeliest first, for when its detection is wrong:
    /// the recogniser's runners-up, and for kanji both Japanese and Chinese — Chinese in
    /// the script its forms are in, Simplified and Traditional being two languages.
    public static func candidates(for text: String, excluding excluded: Locale.Language? = nil,
                                  limit: Int = 5) -> [Locale.Language] {
        var languages = hypotheses(for: text).map { language($0.key) }
        let scripts = Script.histogram(of: text)
        if scripts[.han] != nil || scripts[.kana] != nil {
            languages += [Locale.Language(identifier: "ja"), chineseScript(of: text) ?? simplifiedChinese]
        }
        if scripts[.hangul] != nil { languages.append(Locale.Language(identifier: "ko")) }
        var seen: Set<String> = excluded.map { [key($0)] } ?? []
        return Array(languages.filter { seen.insert(key($0)).inserted }.prefix(limit))
    }

    /// True when most of `text`'s letters are in a script `language` is written in.
    public static func isWritten(_ text: String, in language: Locale.Language) -> Bool {
        let histogram = Script.histogram(of: text)
        let total = histogram.values.reduce(0, +)
        guard total > 0 else { return false }
        let own = scripts(of: language)
        return histogram.filter { own.contains($0.key) }.values.reduce(0, +) * 2 >= total
    }

    /// Whether two pieces of text could be one: the script most of either's letters are
    /// in turns up in the other. Kanji and kana are one writing; text with no letters
    /// goes with anything.
    public static func sharesScript(_ text: String, with other: String) -> Bool {
        func writing(_ text: String) -> [Script: Int] {
            Script.histogram(of: text).reduce(into: [:]) { $0[$1.key == .kana ? .han : $1.key, default: 0] += $1.value }
        }
        let a = writing(text), b = writing(other)
        guard let mainA = a.max(by: { $0.value < $1.value })?.key,
              let mainB = b.max(by: { $0.value < $1.value })?.key
        else { return true }
        return b[mainA] != nil || a[mainB] != nil
    }

    private static func scripts(of language: Locale.Language) -> Set<Script> {
        switch script(of: language) {
        case "Jpan": return [.han, .kana]
        case "Kore": return [.hangul, .han]
        case let identifier?: return Script(iso15924: identifier).map { [$0] } ?? []
        case nil: return []
        }
    }

    /// Whether two languages are one: the same language in the same script. Simplified
    /// and Traditional Chinese are translated between, so they are two.
    public static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        key(a) == key(b)
    }

    /// "zh-TW" → "zh-Hant", "en-IL" → "en-Latn".
    private static func key(_ language: Locale.Language) -> String {
        code(language) + (script(of: language).map { "-" + $0 } ?? "")
    }

    /// The ISO 15924 code of the script `language` is written in, its usual one when it
    /// doesn't say.
    private static func script(of language: Locale.Language) -> String? {
        language.script?.identifier ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier
    }

    private static func hypotheses(for text: String, spelling: Spelling? = nil) -> [(key: NLLanguage, value: Double)] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let read = recognizer.languageHypotheses(withMaximum: 10).sorted { $0.value > $1.value }
        guard let spelled = (spelling ?? Spelling(text)).languages else { return read }
        // The letters settle it; the recogniser's guesses stay on as runners-up to offer.
        return spelled + read.filter { guess in !spelled.contains { $0.key == guess.key } }.map { ($0.key, 0) }
    }

    private static func language(_ language: NLLanguage) -> Locale.Language {
        Locale.Language(identifier: language.rawValue)
    }

    /// "en-IL" → "en", "zh-Hans" → "zh"; one code for each language that has two, so a
    /// Norwegian chosen as "no" is the recogniser's "nb".
    private static func code(_ identifier: String) -> String {
        code(Locale.Language(identifier: identifier))
    }

    private static func code(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return aliases[code] ?? code
    }

    /// Bokmål and Nynorsk are both "no" in translation; Filipino is "tl".
    public static let aliases = ["nb": "no", "nn": "no", "fil": "tl"]
}

/// The letters that tell apart languages sharing a script where the recogniser can't:
/// Serbian and Macedonian, which it doesn't have, from Bulgarian and Russian; Persian,
/// which it reads as Arabic, and Urdu.
private struct Spelling {
    private let script: Script?
    private var counts: [Letter: Int] = [:]

    init(_ text: String) {
        script = Script.dominant(in: text)
        for scalar in text.unicodeScalars {
            if let letter = Letter(scalar) { counts[letter, default: 0] += 1 }
        }
    }

    /// The languages the letters point to, likeliest first, or nil when they don't
    /// settle anything. A letter misread now and then doesn't: a language's own letters
    /// must outnumber those it doesn't use.
    var languages: [(key: NLLanguage, value: Double)]? {
        // Letters two languages share go to the likelier, with the other left plausible
        // enough for a choice to settle it.
        let likelier = LanguageDetector.confident
        switch script {
        case .cyrillic?:
            let serbian = count(.serbian), macedonian = count(.macedonian)
            guard serbian + macedonian + count(.serbianOrMacedonian) > count(.otherCyrillic) else { return nil }
            if serbian > macedonian { return [(NLLanguage("sr"), 1)] }
            if macedonian > serbian { return [(NLLanguage("mk"), 1)] }
            // Serbian is read by four times as many people.
            return [(NLLanguage("sr"), likelier), (NLLanguage("mk"), 1 - likelier)]
        case .arabic?:
            // Pashto, Kurdish, Sindhi and others have letters of their own: theirs to tell.
            guard count(.otherArabicScript) == 0 else { return nil }
            let urdu = count(.urdu), shared = count(.persianOrUrdu), arabic = count(.arabicOnly)
            if urdu > 0, urdu + shared > arabic { return [(.urdu, 1)] }
            // Urdu has letters of its own in nearly every sentence; without them, Persian.
            if shared > arabic { return [(.persian, likelier), (.urdu, 1 - likelier)] }
            return nil
        default:
            return nil
        }
    }

    /// Whether nothing in the letters rules out `code`, one of the languages the
    /// recogniser doesn't have: no letter of its neighbours' that it doesn't use.
    func allows(_ code: String) -> Bool {
        switch code {
        case "sr": count(.otherCyrillic) + count(.macedonian) == 0
        case "mk": count(.otherCyrillic) + count(.serbian) == 0
        case "fa": count(.arabicOnly) + count(.urdu) + count(.otherArabicScript) == 0
        default: false
        }
    }

    private func count(_ letter: Letter) -> Int {
        counts[letter, default: 0]
    }

    private enum Letter {
        /// ђ ћ.
        case serbian
        /// ѓ ќ ѕ.
        case macedonian
        /// ј љ њ џ.
        case serbianOrMacedonian
        /// Letters neither uses: Russian's й ы ь ъ э ю я ё щ, Ukrainian's є і ї ґ, and the
        /// like.
        case otherCyrillic
        /// ٹ ڈ ڑ ں ہ ے and the full stop ۔.
        case urdu
        /// پ چ ژ گ ک ی, which Arabic doesn't have, and the non-joiner of می‌خواهم.
        case persianOrUrdu
        /// ي ك ة ى, whose Persian and Urdu forms differ.
        case arabicOnly
        /// The extended letters of the script's other languages.
        case otherArabicScript

        init?(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x0402, 0x0452, 0x040B, 0x045B: self = .serbian
            case 0x0403, 0x0453, 0x040C, 0x045C, 0x0405, 0x0455: self = .macedonian
            case 0x0408, 0x0458, 0x0409, 0x0459, 0x040A, 0x045A, 0x040F, 0x045F: self = .serbianOrMacedonian
            case 0x0401, 0x0451, 0x0404, 0x0454, 0x0406, 0x0456, 0x0407, 0x0457, 0x040E, 0x045E,
                 0x0419, 0x0439, 0x0429, 0x0449, 0x042A...0x042F, 0x044A...0x044F, 0x0490...0x04FF:
                self = .otherCyrillic
            case 0x0679, 0x0688, 0x0691, 0x06BA, 0x06C1...0x06C3, 0x06D2, 0x06D3, 0x06D4: self = .urdu
            case 0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x200C: self = .persianOrUrdu
            case 0x0629, 0x0643, 0x0649, 0x064A: self = .arabicOnly
            // Persian's ۀ and Urdu's ھ, which tell nothing apart.
            case 0x06BE, 0x06C0: return nil
            case 0x0671...0x06D5, 0x06EE, 0x06EF, 0x06FA...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
                self = .otherArabicScript
            default: return nil
            }
        }
    }
}
