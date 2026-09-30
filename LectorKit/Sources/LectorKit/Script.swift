/// The writing systems the reader tells apart, by Unicode block.
///
/// Block ranges rather than ICU script properties, which Swift does not expose: the
/// reader only needs to know which engine and which model can read a piece of text,
/// what direction it runs in, and whether its words are separated by spaces.
enum Script: String, CaseIterable, Sendable {
    case latin, greek, cyrillic, armenian, hebrew, arabic, syriac, thaana
    case devanagari, bengali, gurmukhi, gujarati, oriya, tamil, telugu, kannada, malayalam, sinhala
    case thai, lao, tibetan, myanmar, khmer
    case georgian, ethiopic, cherokee, canadianAboriginal
    case han, kana, hangul

    static func of(_ scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F,
             0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F,
             0xFF21...0xFF3A, 0xFF41...0xFF5A: .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: .greek
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: .cyrillic
        case 0x531...0x58F, 0xFB13...0xFB17: .armenian
        case 0x591...0x5FF, 0xFB1D...0xFB4F: .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0x870...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: .arabic
        case 0x700...0x74F, 0x860...0x86F: .syriac
        case 0x780...0x7BF: .thaana
        case 0x900...0x97F, 0xA8E0...0xA8FF: .devanagari
        case 0x980...0x9FF: .bengali
        case 0xA00...0xA7F: .gurmukhi
        case 0xA80...0xAFF: .gujarati
        case 0xB00...0xB7F: .oriya
        case 0xB80...0xBFF: .tamil
        case 0xC00...0xC7F: .telugu
        case 0xC80...0xCFF: .kannada
        case 0xD00...0xD7F: .malayalam
        case 0xD80...0xDFF: .sinhala
        case 0xE00...0xE7F: .thai
        case 0xE80...0xEFF: .lao
        case 0xF00...0xFFF: .tibetan
        case 0x1000...0x109F, 0xA9E0...0xA9FF, 0xAA60...0xAA7F: .myanmar
        case 0x1780...0x17FF, 0x19E0...0x19FF: .khmer
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F: .georgian
        case 0x1200...0x139F, 0x2D80...0x2DDF, 0xAB00...0xAB2F: .ethiopic
        case 0x13A0...0x13FF, 0xAB70...0xABBF: .cherokee
        case 0x1400...0x167F, 0x18B0...0x18FF: .canadianAboriginal
        case 0x2E80...0x2FDF, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xFFA0...0xFFDC: .hangul
        default: nil
        }
    }

    /// Letters per script, ignoring digits, punctuation and marks shared across scripts.
    static func histogram(of text: some StringProtocol) -> [Script: Int] {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            if let script = of(scalar) { counts[script, default: 0] += 1 }
        }
        return counts
    }

    /// The script most of the letters belong to, or nil when there are no letters.
    static func dominant(in text: some StringProtocol) -> Script? {
        histogram(of: text).max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key
    }

    /// From an ISO 15924 code, as `Locale.Script` reports it ("Hebr", "Cyrl").
    init?(iso15924 code: String) {
        let scripts: [String: Script] = [
            "Latn": .latin, "Grek": .greek, "Cyrl": .cyrillic, "Armn": .armenian, "Hebr": .hebrew,
            "Arab": .arabic, "Syrc": .syriac, "Thaa": .thaana, "Deva": .devanagari, "Beng": .bengali,
            "Guru": .gurmukhi, "Gujr": .gujarati, "Orya": .oriya, "Taml": .tamil, "Telu": .telugu,
            "Knda": .kannada, "Mlym": .malayalam, "Sinh": .sinhala, "Thai": .thai, "Laoo": .lao,
            "Tibt": .tibetan, "Mymr": .myanmar, "Khmr": .khmer, "Geor": .georgian, "Ethi": .ethiopic,
            "Cher": .cherokee, "Cans": .canadianAboriginal, "Hani": .han, "Hans": .han, "Hant": .han,
            "Jpan": .kana, "Hira": .kana, "Kana": .kana, "Kore": .hangul, "Hang": .hangul,
        ]
        guard let script = scripts[code] else { return nil }
        self = script
    }

    var isRightToLeft: Bool {
        switch self {
        case .hebrew, .arabic, .syriac, .thaana: true
        default: false
        }
    }

    /// Scripts written without spaces between words, where joining recognised words
    /// with a space would insert spaces the text never had.
    var joinsWithoutSpaces: Bool {
        switch self {
        case .han, .kana, .thai, .lao, .khmer, .myanmar, .tibetan: true
        default: false
        }
    }

    /// The bundled tessdata_fast script model that reads this script, if one ships.
    /// Latin and the CJK scripts have none: Vision reads them better on every OS the
    /// app supports, and a Latin script model alone would be 89MB.
    var tesseractModel: String? {
        switch self {
        case .latin, .han, .kana, .hangul: nil
        case .canadianAboriginal: "Canadian_Aboriginal"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Language codes whose presence in Vision's supported list means Vision reads this
    /// script. Checked against the running OS: the list grows with each release
    /// (macOS 26 added Hindi and Marathi, hence Devanagari).
    var visionLanguages: [String] {
        switch self {
        case .latin: ["en"]
        case .cyrillic: ["ru", "uk"]
        case .arabic: ["ar"]
        case .thai: ["th"]
        case .devanagari: ["hi", "mr"]
        case .han: ["zh"]
        case .kana: ["ja"]
        case .hangul: ["ko"]
        case .greek: ["el"]
        case .hebrew: ["he"]
        default: []
        }
    }
}

extension Unicode.Scalar {
    /// Invisible bidi controls Tesseract wraps around words it reorders.
    var isBidiControl: Bool {
        switch value {
        case 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// Characters that belong to text written without spaces, beyond the letters
    /// themselves: CJK punctuation and full-width forms.
    var isUnspacedPunctuation: Bool {
        switch value {
        case 0x3000...0x303F, 0xFF01...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65: true
        default: false
        }
    }
}
