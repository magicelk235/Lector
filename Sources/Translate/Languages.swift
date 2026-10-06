import Foundation
import LectorKit

/// Languages offered as translation targets. Apple's on-device set plus what the
/// offline Opus-MT models reach, named in the user's own language. Lector translates
/// from every one of them too, so they're also what an app's text can be set to be in.
enum Languages {
    /// Language codes, except Chinese, which is two targets: a reader of one script
    /// wants the other converted, not left as it is.
    static let targets: [String] = [
        "af", "am", "ar", "az", "be", "bg", "bn", "ca", "cs", "cy", "da", "de", "el", "en",
        "eo", "es", "et", "eu", "fa", "fi", "fr", "ga", "gl", "gu", "he", "hi", "hr", "ht",
        "hu", "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky", "lo", "lt",
        "lv", "mg", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "no", "pa", "pl",
        "ps", "pt", "ro", "ru", "si", "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "tg",
        "th", "tl", "tr", "uk", "ur", "uz", "vi", "xh", "yi", "yo", "zh-Hans", "zh-Hant", "zu",
    ]

    /// "Hebrew"; "Chinese, Traditional" — the system's own name, as Language & Region
    /// shows it.
    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }

    /// Chinese is named with its script when it has one, so a pill can say which of
    /// the two it's translating into.
    static func name(_ language: Locale.Language?) -> String {
        guard let language, let code = language.languageCode?.identifier else { return "Choose language" }
        if code == "zh", let script = language.script?.identifier { return name("zh-\(script)") }
        return name(code)
    }

    /// Sorted by display name, so the menu reads alphabetically in any UI language.
    static var sortedTargets: [String] {
        targets.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The entry in `targets` that `identifier` means, or nil when Lector can't
    /// translate into it: "he-IL" → "he", "zh-TW" → "zh-Hant". A bare "zh" (what the
    /// setting held before the two scripts were separate targets, and what the system
    /// language comes to without its script) takes the script of a Chinese the user
    /// reads, Simplified when they read none.
    static func target(for identifier: String, preferred: [String] = Locale.preferredLanguages) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard let spoken = language.languageCode?.identifier else { return nil }
        let code = LanguageDetector.aliases[spoken] ?? spoken
        guard code == "zh" else { return targets.contains(code) ? code : nil }
        // As written: `Locale.Language` itself fills in a likely script for a bare "zh".
        let written = Locale.Language.Components(identifier: identifier)
        if written.script == nil, written.region == nil,
           let read = preferred.lazy.map({ Locale.Language(identifier: $0) })
               .first(where: { $0.languageCode?.identifier == "zh" }) {
            return chinese(read)
        }
        return chinese(language)
    }

    private static func chinese(_ language: Locale.Language) -> String {
        Locale.Language(identifier: language.maximalIdentifier).script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
    }

    /// How many languages go at the top of a picker, ahead of the full list.
    static let suggestionCount = 6

    /// The languages someone is likeliest to translate into, for the top of a menu, ahead
    /// of eighty-odd others: the one chosen now; those translated into lately, the latest
    /// first; those the Mac is set to read, in the user's order — the short list a
    /// bilingual user switches between; then those of the Mac's region (Hebrew and Arabic
    /// in Israel). Each once, and only those Lector can translate into.
    static func likelyTargets(current: String, recent: [String] = [],
                              preferred: [String] = Locale.preferredLanguages,
                              regional: [String] = Languages.spoken(in: Locale.current.region)) -> [String] {
        Array(listed([current] + recent + preferred + regional, preferred: preferred).prefix(suggestionCount))
    }

    /// The languages an app's text is likeliest to be in, for the top of its picker: the
    /// one picked for it now, as it is, even one Lector can't translate from; those
    /// translated from lately; then those the Mac reads and those of its region. Never
    /// `target`, the language translated into, unless it's the one picked.
    static func likelySources(current: String?, recent: [String], target: String,
                              preferred: [String] = Locale.preferredLanguages,
                              regional: [String] = Languages.spoken(in: Locale.current.region)) -> [String] {
        var codes = current.map { [$0] } ?? []
        // As detected: a bare "zh" is Simplified, not whichever Chinese the user reads.
        for code in listed(recent + preferred + regional, preferred: []) where code != target && !codes.contains(code) {
            codes.append(code)
        }
        return Array(codes.prefix(suggestionCount))
    }

    /// The languages of `region` that Lector translates into, its main one first: for
    /// Israel, Hebrew, then Arabic and English. Foundation keeps no list of a region's
    /// languages, but it has a locale for each one commonly written there ("ar_IL",
    /// "he_IL"), and knows the likeliest.
    static func spoken(in region: Locale.Region?) -> [String] {
        guard let region = region?.identifier else { return [] }
        let main = Locale.Language(identifier: "und-\(region)").maximalIdentifier
        return listed([main] + (localesByRegion[region] ?? []), preferred: [])
    }

    /// Every locale the system has, by region, alphabetically. Grouped once: there are
    /// over a thousand.
    private static let localesByRegion: [String: [String]] = Dictionary(
        grouping: Locale.availableIdentifiers.sorted(), by: { Locale(identifier: $0).region?.identifier ?? "" })

    /// The entries in `targets` that `identifiers` mean, in order and each once; those
    /// Lector can't translate into are left out.
    private static func listed(_ identifiers: [String], preferred: [String]) -> [String] {
        var codes: [String] = []
        for identifier in identifiers {
            guard let code = target(for: identifier, preferred: preferred), !codes.contains(code) else { continue }
            codes.append(code)
        }
        return codes
    }
}
