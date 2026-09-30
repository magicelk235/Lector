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
/// unfamiliar language that merely scored higher.
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
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10).sorted { $0.value > $1.value }
        guard let top = hypotheses.first else { return nil }

        if top.value >= confident { return language(top.key) }

        let preferredCodes = preferred.map(code)
        for wanted in preferredCodes {
            if let match = hypotheses.first(where: { code($0.key.rawValue) == wanted }),
               match.value >= preferredFloor {
                return language(match.key)
            }
        }

        return top.value >= evenBet ? language(top.key) : nil
    }

    public static var defaultPreferred: [String] {
        var codes = Locale.preferredLanguages.map(code)
        if !codes.contains("en") { codes.append("en") }
        return codes
    }

    private static func language(_ language: NLLanguage) -> Locale.Language {
        Locale.Language(identifier: language.rawValue)
    }

    /// "en-IL" → "en", "zh-Hans" → "zh".
    private static func code(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    }
}
