import Foundation

/// Languages offered as translation targets. Apple's on-device set plus what the
/// offline Opus-MT models reach, named in the user's own language.
enum Languages {
    static let targets: [String] = [
        "af", "am", "ar", "az", "be", "bg", "bn", "ca", "cs", "cy", "da", "de", "el", "en",
        "eo", "es", "et", "eu", "fa", "fi", "fr", "ga", "gl", "gu", "he", "hi", "hr", "ht",
        "hu", "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky", "lo", "lt",
        "lv", "mg", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "no", "pa", "pl",
        "ps", "pt", "ro", "ru", "si", "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "tg",
        "th", "tl", "tr", "uk", "ur", "uz", "vi", "xh", "yi", "yo", "zh", "zu",
    ]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    static func name(_ language: Locale.Language?) -> String {
        guard let code = language?.languageCode?.identifier else { return "Choose language" }
        return name(code)
    }

    /// Sorted by display name, so the menu reads alphabetically in any UI language.
    static var sortedTargets: [String] {
        targets.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}
