import CoreGraphics
import Foundation
import LectorKit

/// Rebuilds sentences that OCR split into visual lines, so a wrapped paragraph is
/// translated as one thought instead of line fragments — while a menu, list or UI
/// labels stay one item per line.
///
/// A line runs on into the next when the next sits directly beneath it, in the same
/// column, at the same size and in a script they share, closer than the gap between
/// paragraphs. Beyond that it depends on how the one ends and the other starts:
///
/// - After a full stop, only where the line wrapped — it runs so close to the column's
///   end that the next line's first word wouldn't have fitted after it — and the next
///   is set tight beneath it from the same edge: a sentence of running text that
///   happens to end at the end of a line. Chat messages and list items are spaced
///   apart, new paragraphs indented, and menu items aren't running text.
/// - In lowercase, it continues a line that is nearly as wide as its column.
/// - With a capital — or in a script without case — it continues only a line that
///   wrapped. Even then, in a script with spaces it takes running text, mostly
///   lowercase words, since menus and headings are written in Title Case; and that is
///   judged on the paragraph so far, since German capitalises every noun and "Sie",
///   and a line of it can hold one lowercase word. Names start lines in any language;
///   menu items and list entries start with capitals too.
/// - A line ending in a word broken by a hyphen, a comma or a word no sentence ends on
///   ("to", "the", "und", "с") always continues; one starting with a bullet or a
///   dialogue dash never continues anything.
enum Paragraphs {
    /// One paragraph and where it sits in the recognised image.
    struct Block: Equatable {
        var text: String
        /// Union of its lines, in the image's pixels (top-left origin).
        var rect: CGRect
        /// Height of one of its lines, in pixels.
        var lineHeight: CGFloat
        /// Which of the recognised text's lines it was built from.
        var lines: Range<Int>
    }

    static func split(_ text: RecognizedText) -> [String] {
        blocks(text).map(\.text)
    }

    static func blocks(_ text: RecognizedText) -> [Block] {
        let lines = text.lines
        guard !lines.isEmpty else { return [] }

        let layout = Layout(lines)
        var blocks: [Block] = []
        var current = Block(text: lines[0].text, rect: lines[0].rect, lineHeight: lines[0].rect.height, lines: 0..<1)

        for index in 1..<lines.count {
            let later = lines[index]
            let firstWord = later.wordRange.first.map { text.words[$0].rect.width } ?? later.rect.width
            if continues(lines[index - 1], into: later, paragraph: current.text, firstWordWidth: firstWord,
                         column: layout.columns[index - 1], lineGap: layout.lineGap) {
                current.text = join(current.text, later.text)
                current.rect = current.rect.union(later.rect)
                current.lineHeight = max(current.lineHeight, later.rect.height)
                current.lines = current.lines.lowerBound..<(index + 1)
            } else {
                blocks.append(current)
                current = Block(text: later.text, rect: later.rect, lineHeight: later.rect.height, lines: index..<(index + 1))
            }
        }
        blocks.append(current)
        return blocks.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether `later` carries on `paragraph`, which ends with `earlier`. `column` is the
    /// extent of the column `earlier` sits in; `lineGap` the usual space between two
    /// lines of one paragraph on this page, when there's enough to tell.
    static func continues(_ earlier: RecognizedLine, into later: RecognizedLine, paragraph: String,
                          firstWordWidth: CGFloat, column: CGRect, lineGap: CGFloat?) -> Bool {
        let a = earlier.rect, b = later.rect
        let height = max(a.height, b.height)
        guard height > 0 else { return false }

        // Directly beneath, same column, same size, closer than paragraphs are apart.
        let gap = b.minY - a.maxY
        let widest = lineGap.map { min($0 + height * 0.35, height * 0.8) } ?? height * 0.8
        guard b.minY >= a.midY, gap < widest,
              a.minX < b.maxX, b.minX < a.maxX,
              sameSize(earlier, later)
        else { return false }

        let earlierText = earlier.text.trimmingCharacters(in: .whitespaces)
        let laterText = later.text.trimmingCharacters(in: .whitespaces)
        guard !laterText.isEmpty, !startsItem(laterText),
              LanguageDetector.sharesScript(earlierText, with: laterText)
        else { return false }
        let finished = ended(earlierText)
        if !finished, endsMidWord(earlierText) || endsOnJoiner(earlierText) { return true }
        guard let first = laterText.first(where: \.isLetter) else { return false }

        let rightToLeft = isRightToLeft(earlierText)
        let room = rightToLeft ? a.minX - column.minX : column.maxX - a.maxX
        let spaceless = isSpaceless(first)
        // The next line's first word, or in a script without spaces its first character,
        // would have fitted in the room left. Without spaces the line must hold more than
        // a label, too: a column of two-kanji menu items reaches its own end every time.
        let wrapped = spaceless
            ? room < height * 1.5 && earlierText.filter(isSpaceless).count > longestUnspacedLabel
            : room < firstWordWidth + height * 0.6

        // A sentence that ended where its line wrapped, in a paragraph that runs on.
        if finished {
            let edge = rightToLeft ? abs(a.maxX - b.maxX) : abs(a.minX - b.minX)
            return wrapped && gap < height * 0.5 && edge < height * 0.5 && (spaceless || isRunningText(paragraph))
        }
        if first.isLowercase { return a.width >= column.width * 0.75 }

        // A capital, or a script without case: only after a line that wrapped.
        guard wrapped else { return false }
        return spaceless || isRunningText(paragraph)
    }

    /// Set in the same size of type. A line's box is as tall as what's in it — one with
    /// nothing above the x-height ("инструкциями.") gets half the height of the line
    /// before it, and a long line's box grows as its slant adds up — so lines whose
    /// boxes differ are alike still when their characters are as wide.
    private static func sameSize(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        func ratio(_ x: CGFloat, _ y: CGFloat) -> CGFloat { max(x, y) / max(min(x, y), 0.001) }
        func advance(_ line: RecognizedLine) -> CGFloat { line.rect.width / CGFloat(max(line.text.count, 1)) }
        return ratio(a.rect.height, b.rect.height) < 1.5 || ratio(advance(a), advance(b)) < 1.25
    }

    /// As many characters as a label in a script without spaces runs to — "ウインドウ",
    /// "環境設定": a line any longer can be one of a paragraph.
    private static let longestUnspacedLabel = 6

    /// Joins with a space, except where the script doesn't use them (CJK, Thai) or a
    /// word was broken across the lines.
    static func join(_ earlier: String, _ later: String) -> String {
        guard let last = earlier.last, let first = later.first else { return earlier + later }
        if last == "\u{AD}" { return String(earlier.dropLast()) + later }
        if endsMidWord(earlier) {
            // "trans-" "lation": a break. "well-" "Known", "COVID-" "19": the word's own
            // hyphen. "pre-" "and post-war": a hyphen left hanging for a later word.
            if first.isLowercase {
                let next = later.prefix { $0.isLetter }.lowercased()
                return suspending.contains(next) ? earlier + " " + later : String(earlier.dropLast()) + later
            }
            return earlier + later
        }
        if last == "—", earlier.dropLast().last?.isLetter == true { return earlier + later }
        if isSpaceless(last) && isSpaceless(first) {
            return earlier + later
        }
        return earlier + " " + later
    }

    // MARK: The page

    /// What the whole capture says about one line: the column it's in, and how far
    /// apart the lines of a paragraph sit.
    private struct Layout {
        /// Per line: the union of the lines in its column at about its size.
        let columns: [CGRect]
        let lineGap: CGFloat?

        init(_ lines: [RecognizedLine]) {
            func stacked(_ a: CGRect, _ b: CGRect) -> Bool {
                let height = max(a.height, b.height)
                let gap = b.minY - a.maxY
                return gap > -height * 0.5 && gap < height * 1.5 && a.minX < b.maxX && b.minX < a.maxX
                    && height / max(min(a.height, b.height), 1) < 1.3
            }
            // Runs of lines stacked one under the next: columns, in reading order.
            var runs: [Range<Int>] = []
            var start = 0
            var gaps: [CGFloat] = []
            for index in 1..<max(lines.count, 1) {
                let a = lines[index - 1].rect, b = lines[index].rect
                if stacked(a, b) {
                    gaps.append(max(0, b.minY - a.maxY))
                } else {
                    runs.append(start..<index)
                    start = index
                }
            }
            runs.append(start..<lines.count)
            var columns = Array(repeating: CGRect.null, count: lines.count)
            for run in runs where !run.isEmpty {
                let union = lines[run].reduce(CGRect.null) { $0.union($1.rect) }
                for index in run { columns[index] = union }
            }
            self.columns = columns
            // The lower quartile: paragraph breaks are the wide gaps, and the fewer.
            lineGap = gaps.isEmpty ? nil : gaps.sorted()[gaps.count / 4]
        }
    }

    // MARK: How lines end and start

    private static let terminal: Set<Character> = [".", "!", "?", ":", "。", "！", "？", "؟", "।", "…", "۔"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", "»", ")", "]", "」", "』", "）"]

    /// Ends its sentence, closing quotes and brackets aside. In Greek ";" is the question
    /// mark.
    private static func ended(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !closers.contains($0) }) else { return true }
        return terminal.contains(last) || last == ";" && LanguageDetector.isWritten(text, in: greek)
    }

    private static let greek = Locale.Language(identifier: "el")

    /// A word broken off with a hyphen: "infra-", not "Monday -".
    private static func endsMidWord(_ text: String) -> Bool {
        guard let last = text.last, last == "-" || last == "\u{2010}" || last == "\u{AD}" else { return false }
        return text.dropLast().last?.isLetter == true
    }

    /// Prefixes like "pre-" hang before these to share the word that follows them.
    private static let suspending: Set<String> = ["and", "or", "und", "oder", "et", "ou", "y", "o", "e", "en", "of"]

    /// A comma, an opening bracket or a dash — or, in a line of three words or more, a
    /// lowercase word no sentence ends on. Not a two-word label: "Sign in", "About".
    private static func endsOnJoiner(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if [",", ";", "(", "/", "&", "+", "—", "–"].contains(last) { return true }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, let word = words.last, word.first?.isLowercase == true else { return false }
        return connectors.contains(String(word))
    }

    /// Articles, prepositions and conjunctions, in the languages written with spaces
    /// and capitals that a wrapped line most often ends on. Not words that end
    /// sentences as well: "я" and "ja" (I in Russian and Polish), Polish "nie" and
    /// "się", the Greek pronouns that are also articles ("το σπίτι της", her house).
    private static let connectors: Set<String> = [
        // English
        "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "onto", "about",
        "and", "or", "but", "nor", "as", "than", "that", "which", "who", "whose", "if", "when", "while",
        "because", "is", "are", "was", "were", "be", "been", "has", "have", "had", "will", "would", "can",
        "could", "should", "may", "might", "must", "not", "our", "your", "their", "his", "her", "its", "my",
        "this", "these", "those", "over", "under", "between", "through", "during", "before", "after",
        // German
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder",
        "aber", "mit", "von", "zu", "für", "auf", "im", "an", "am", "bei", "nach", "aus", "über", "unter",
        "vor", "durch", "ist", "sind", "war", "wird", "werden", "hat", "haben", "nicht", "als", "wie", "dass",
        // French
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "mais", "avec", "pour", "par", "sur",
        "dans", "en", "à", "au", "aux", "que", "qui", "ne", "est", "sont", "son", "sa", "ses", "leur", "ce",
        "cette", "ces", "sans",
        // Spanish, Italian, Portuguese, Catalan
        "el", "los", "las", "una", "unos", "unas", "y", "o", "pero", "con", "para", "por", "sobre", "del",
        "al", "se", "es", "su", "sus", "il", "lo", "gli", "di", "della", "che", "e", "uma", "em", "no", "na",
        "do", "da", "amb", "els", "però",
        // Dutch
        "het", "een", "maar", "met", "voor", "van", "op", "aan", "te", "dat",
        // Swedish, Norwegian, Danish, Finnish
        "och", "og", "att", "i", "på", "med", "för", "av", "af", "till", "til", "ett", "som", "eller", "om",
        "från", "fra", "vid", "ved", "hos", "tai", "että", "mutta",
        // Polish, Czech, Slovak, Croatian
        "w", "we", "z", "ze", "u", "od", "po", "za", "dla", "przez", "przy", "pod", "nad", "oraz", "lub", "albo",
        "ale", "że", "aby", "jak", "czy", "k", "ke", "s", "v", "ve", "pro", "při", "pri", "pre", "nebo",
        "alebo", "jako", "ako", "iz", "kao", "ali", "ili",
        // Russian, Ukrainian, Bulgarian, Serbian, Macedonian
        "в", "во", "с", "со", "к", "ко", "и", "а", "о", "об", "у", "на", "по", "за", "из", "от", "до", "для",
        "при", "без", "под", "над", "про", "через", "что", "чтобы", "как", "но", "или", "если", "когда", "не",
        "з", "із", "зі", "і", "й", "та", "від", "під", "що", "щоб", "як", "але", "або", "със", "във", "че",
        "като", "од", "са", "као", "али",
        // Greek
        "και", "να", "θα", "με", "σε", "για", "από", "ως", "ή", "αλλά", "ότι", "που", "ο", "η", "οι", "των",
        "στο", "στη", "στην", "στον", "στα", "στις", "στους", "ένα", "μια", "ένας", "δεν", "μην",
        // Turkish, Hungarian, Romanian
        "ile", "için", "gibi", "ama", "veya", "ancak", "çünkü", "az", "és", "egy", "hogy", "vagy", "și",
        "în", "cu", "pe", "din", "pentru", "că", "sau", "unei", "unui", "care", "dar", "prin", "spre", "despre",
        // Indonesian, Malay, Vietnamese
        "dan", "dari", "yang", "untuk", "dengan", "pada", "atau", "oleh", "karena", "tetapi", "dalam",
        "bagi", "agar", "bahwa", "sebagai", "và", "của", "với", "là", "các", "những", "một", "để", "trong",
        "nhưng", "hoặc",
    ]

    /// A bullet, a number or a dialogue dash: a new item, whatever came before.
    private static func startsItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if ["•", "◦", "▪", "▫", "▸", "►", "‣", "⁃", "●", "○", "■", "□", "*", "·"].contains(first) { return true }
        if ["-", "–", "—"].contains(first) {
            return text.dropFirst().first.map { $0.isWhitespace || $0.isLetter || $0 == "\"" || $0 == "¿" || $0 == "¡" } ?? false
        }
        // "1." "12)" "a)"
        let marker = text.prefix { $0.isNumber }
        let afterNumber = text.dropFirst(marker.count)
        if !marker.isEmpty, marker.count <= 3, let next = afterNumber.first, next == "." || next == ")",
           afterNumber.dropFirst().first?.isWhitespace == true {
            return true
        }
        return false
    }

    /// Mostly lowercase words, four or more: a sentence, not a menu item or a heading.
    /// Without case, five words or more.
    private static func isRunningText(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        let cased = words.compactMap { $0.first(where: \.isLetter) }.filter { $0.isUppercase || $0.isLowercase }
        guard !cased.isEmpty else { return words.count >= 5 }
        return words.count >= 4 && cased.filter(\.isLowercase).count * 2 >= cased.count
    }

    private static func isRightToLeft(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return false }
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK ideographs
             0x3000...0x303F, 0xFF00...0xFFEF, // CJK punctuation, full-width forms
             0x0E00...0x0E7F, 0x0E80...0x0EFF, // Thai, Lao
             0x1000...0x109F, 0x1780...0x17FF: // Myanmar, Khmer
            return true
        default:
            return false
        }
    }
}
