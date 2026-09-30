import XCTest
@testable import HoverLensKit

final class LanguageDetectorTests: XCTestCase {
    private func detect(_ text: String, preferring: [String] = ["en", "he"]) -> String? {
        LanguageDetector.language(of: text, preferring: preferring)?.languageCode?.identifier
    }

    /// These lines are full of words that are also English ("chat", "pain"); a whole
    /// line is still unambiguous.
    func testLinesAreIdentifiedByTheirLanguage() {
        XCTAssertEqual(detect("Le fromage de chèvre est délicieux avec du pain frais"), "fr")
        XCTAssertEqual(detect("Le chat dort sur le canapé pendant la journée"), "fr")
        XCTAssertEqual(detect("Hello there, how are you doing this fine morning"), "en")
        XCTAssertEqual(detect("שלום עולם\nהאוכל טעים מאוד היום"), "he")
    }

    /// Table cells, buttons and menu items: too short to detect on their own, and the
    /// text translation is most often pointed at.
    func testShortTextInAPreferredLanguageResolves() {
        for text in ["Feature", "Settings", "Menu", "OK", "Target Audience", "Lemon Squeezy"] {
            XCTAssertEqual(detect(text), "en", text)
        }
    }

    /// Preferring English mustn't swallow words that are clearly something else.
    func testConfidentForeignWordsStayForeign() {
        XCTAssertEqual(detect("Bonjour"), "fr")
        XCTAssertEqual(detect("Hola"), "es")
        XCTAssertEqual(detect("Danke"), "de")
        XCTAssertEqual(detect("Freundschaft"), "de")
        XCTAssertEqual(detect("こんにちは"), "ja")
    }

    /// Regional preferences ("en-IL") match their language.
    func testRegionalPreferenceMatchesLanguage() {
        XCTAssertEqual(detect("Feature", preferring: ["en-IL", "he-IL"]), "en")
    }

    /// With no preferred language in play and only a weak reading, there's no answer
    /// rather than a coin toss.
    func testWeakReadingWithoutPreferenceIsLeftUndecided() {
        XCTAssertNil(detect("Settings", preferring: ["he"]))
    }

    func testEmptyInputYieldsNoLanguage() {
        XCTAssertNil(detect(""))
    }
}
