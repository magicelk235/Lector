import CoreServices
import Foundation

/// What Lector can say about one word on its own, without a network: the word itself as
/// a dictionary would want it, how it's read, and what the Mac's dictionaries say of it.
enum WordLookup {
    /// The term a right-click on an OCR word means: the word without punctuation, quotes
    /// or brackets around it ("«Bonjour!»" → "Bonjour", "「設定」" → "設定"). Inner
    /// punctuation stays (l'homme, e-mail). A word that is nothing but punctuation is
    /// kept as it is, so there is still something to show.
    static func term(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = trimmed.trimmingCharacters(in: Self.surrounding)
        return term.isEmpty ? trimmed : term
    }

    /// How `term` is read, when that tells the reader something its letters don't:
    /// hiragana for Japanese with kanji (and nil for kana-only words), pinyin with tone
    /// marks for Chinese, a romanisation for Korean and other non-Latin scripts (Cyrillic,
    /// Greek, Thai, Devanagari…), but none for Hebrew and Arabic, whose romanisations
    /// lack the vowels. Nil for Latin-script text or when the
    /// reading equals the term. `language` is the language the term is in when known
    /// (decides kanji = Japanese vs Chinese); nil → guess from the text (kana present →
    /// Japanese).
    static func reading(of term: String, language: Locale.Language?) -> String? {
        let scalars = term.unicodeScalars
        let hasHan = scalars.contains(where: isHan)
        let hasKana = scalars.contains(where: isKana)
        let reading: String?
        if hasHan || hasKana {
            let japanese = switch language?.languageCode {
            case .japanese: true
            case .chinese: false
            default: hasKana
            }
            if japanese {
                // Kana already say how they're read.
                reading = hasHan ? hiragana(term) : nil
            } else {
                reading = term.applyingTransform(.mandarinToLatin, reverse: false)
            }
        } else if scalars.contains(where: isAbjad) {
            // Hebrew and Arabic are written without most of their vowels, and so are
            // their romanisations ("slwm" for שלום, "mrhba" for مرحبا): no help in saying them.
            reading = nil
        } else {
            // Pinyin needs its tone marks, but here the marks are a transliteration
            // scheme's (Thai "s̄wạs̄dī", Greek "Athḗna"), which say little to someone who
            // can't read the script and get in the way of those who'd sound it out.
            reading = term.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripCombiningMarks, reverse: false)
        }
        guard let reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines), !reading.isEmpty,
              reading.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        else { return nil }
        return reading
    }

    /// The definition the Mac's dictionaries give, as plain text (DictionaryServices
    /// `DCSCopyTextDefinition`), or nil.
    static func definition(of term: String) -> String? {
        let length = (term as NSString).length
        guard length > 0,
              let found = DCSCopyTextDefinition(nil, term as CFString, CFRange(location: 0, length: length))
        else { return nil }
        let text = (found.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What can be around a word without being part of it. Symbols stay: "C++", "$5".
    private static let surrounding = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)

    /// A Japanese term in hiragana, one of the tokenizer's words at a time. The tokenizer
    /// reads in romaji, which turns straight into hiragana; a word with no kanji in it is
    /// kept as written, so katakana stays katakana ("ゼルダ城" → "ゼルダじょう").
    private static func hiragana(_ term: String) -> String? {
        let text = term as NSString
        let tokenizer = CFStringTokenizerCreate(nil, term as CFString, CFRange(location: 0, length: text.length),
                                                kCFStringTokenizerUnitWordBoundary,
                                                Locale(identifier: "ja") as CFLocale)
        var reading = ""
        var covered = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            // Whatever the tokenizer skipped between words, as written.
            if range.location > covered {
                reading += text.substring(with: NSRange(location: covered, length: range.location - covered))
            }
            let word = text.substring(with: NSRange(location: range.location, length: range.length))
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription)
                as? String
            if word.unicodeScalars.contains(where: isHan),
               let kana = latin?.applyingTransform(.latinToHiragana, reverse: false) {
                reading += kana
            } else {
                reading += word
            }
            covered = range.location + range.length
        }
        if covered < text.length {
            reading += text.substring(from: covered)
        }
        // Kanji the tokenizer had no reading for come through unread: half a reading
        // is a wrong one.
        return reading.unicodeScalars.contains(where: isHan) ? nil : reading
    }

    /// Hebrew, Arabic, Persian and Urdu letters.
    private static func isAbjad(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
            true
        default:
            false
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005, 0x3007,           // 々 and 〇, which stand in for kanji
             0x3400...0x4DBF,          // Extension A
             0x4E00...0x9FFF,          // Unified Ideographs
             0xF900...0xFAFF,          // Compatibility Ideographs
             0x20000...0x3134F:        // Extensions B onwards
            true
        default:
            false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x309F,          // Hiragana
             0x30A1...0x30FA, 0x30FD...0x30FF, // Katakana, without the middle dot and ー
             0x31F0...0x31FF,          // Katakana phonetic extensions
             0xFF66...0xFF9D:          // Half-width katakana
            true
        default:
            false
        }
    }
}
