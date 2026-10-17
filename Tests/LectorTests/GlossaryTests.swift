import XCTest
@testable import Lector

final class GlossaryTests: XCTestCase {
    private let castle = GlossaryTerm(original: "Hyrule Castle", translation: "טירת הייראל", target: "he")

    func testTermsAreMarkedAndPutBackWithTheirTranslations() {
        let text = GlossaryText("Talk to Zelda before you leave Hyrule Castle.",
                                terms: [.keep("Zelda"), castle], target: "he")
        XCTAssertEqual(text.text, "Talk to ZX1Q before you leave ZX2Q.")
        XCTAssertEqual(text.restore("דבר עם ZX1Q לפני שאתה עוזב את ZX2Q."), "דבר עם Zelda לפני שאתה עוזב את טירת הייראל.")
    }

    /// The longer term is one name; "Hyrule" alone mustn't split it.
    func testLongerTermWinsOverOneInsideIt() {
        let text = GlossaryText("Hyrule Castle is in Hyrule.", terms: [.keep("Hyrule"), castle], target: "he")
        XCTAssertEqual(text.text, "ZX1Q is in ZX2Q.")
        XCTAssertEqual(text.replacements, ["טירת הייראל", "Hyrule"])
    }

    func testOnlyWholeWordsMatchInSpacedScripts() {
        let text = GlossaryText("Link's sword is linked to Linkoln.", terms: [.keep("Link")], target: "he")
        XCTAssertEqual(text.text, "ZX1Q's sword is linked to Linkoln.")
    }

    /// Scripts without spaces have no word edges: the name is found inside the run.
    func testTermsAreFoundInsideTextWithoutSpaces() {
        let text = GlossaryText("ゼルダはハイラル城の扉を開けた。", terms: [.keep("ゼルダ"), .keep("ハイラル城")], target: "en")
        XCTAssertEqual(text.text, "ZX1QはZX2Qの扉を開けた。")
    }

    /// Matched whatever the case, and a kept term comes back as this text writes it.
    func testKeptTermComesBackAsWrittenHere() {
        let text = GlossaryText("THE ZELDA SAGA", terms: [.keep("Zelda")], target: "he")
        XCTAssertEqual(text.restore("ZX1Q"), "ZELDA")
    }

    /// A translation is into one language; translating into another leaves the term to
    /// the translator.
    func testTranslationAppliesOnlyIntoItsOwnLanguage() {
        let text = GlossaryText("Welcome to Hyrule Castle", terms: [castle], target: "en")
        XCTAssertEqual(text.text, "Welcome to Hyrule Castle")
        XCTAssertTrue(text.replacements.isEmpty)
    }

    func testMarksSpacedOutOrLowercasedByATranslatorAreStillFound() {
        let text = GlossaryText("Zelda and Link", terms: [.keep("Zelda"), .keep("Link")], target: "he")
        XCTAssertEqual(text.restore("zx1q ו-ZX 2Q"), "Zelda ו-Link")
    }

    func testTextThatAlreadyHasMarkLikeLettersIsLeftAlone() {
        let text = GlossaryText("Zelda ZX81", terms: [.keep("Zelda")], target: "he")
        XCTAssertEqual(text.text, "Zelda ZX81")
        XCTAssertEqual(text.restore("Zelda ZX81"), "Zelda ZX81")
    }

    func testALabelThatIsOnlyTermsIsTheirTranslation() {
        let label = GlossaryText("Hyrule Castle", terms: [castle], target: "he")
        XCTAssertTrue(label.isOnlyTerms)
        XCTAssertEqual(label.restore(label.text), "טירת הייראל")
        XCTAssertFalse(GlossaryText("Enter Hyrule Castle", terms: [castle], target: "he").isOnlyTerms)
    }

    // MARK: - Names seen often

    func testCapitalisedWordsInsideSentencesAreNames() {
        let names = NameSuggestions.candidates(in: "Then Tifa said goodbye to Cloud and left for Midgar Station.")
        XCTAssertTrue(names.contains("Tifa"))
        XCTAssertTrue(names.contains("Cloud"))
        XCTAssertTrue(names.contains("Midgar Station"))
        XCTAssertFalse(names.contains("Then"))
    }

    /// Every sentence and every menu item starts with a capital.
    func testWordsStartingSentencesOrInCapitalsAreNot() {
        XCTAssertEqual(NameSuggestions.candidates(in: "Save. Load! Quit the GAME now"), [])
    }

    @MainActor
    func testANameIsOfferedOnceSeenTwiceAndOnlyOnce() {
        let suggestions = NameSuggestions()
        suggestions.note(["Talk to Tifa first."], app: "game")
        XCTAssertNil(suggestions.offer(for: "game", in: ["Talk to Tifa first."], excluding: []))
        suggestions.note(["Ask Tifa about it."], app: "game")
        XCTAssertEqual(suggestions.offer(for: "game", in: ["Ask Tifa about it."], excluding: []), "Tifa")
        XCTAssertNil(suggestions.offer(for: "game", in: ["Ask Tifa about it."], excluding: []))
        // Seen in another app's text, it's that app's to suggest, not this one's.
        XCTAssertEqual(suggestions.suggestions(for: "other", excluding: []), [])
    }

    @MainActor
    func testANameAlreadyInTheGlossaryIsNotSuggested() {
        let suggestions = NameSuggestions()
        suggestions.note(["Talk to Tifa first.", "Ask Tifa about it."], app: "game")
        XCTAssertEqual(suggestions.suggestions(for: "game", excluding: [.keep("tifa")]), [])
    }
}
