import XCTest
@testable import LectorKit

/// Where paragraphs are cut into sentences for the offline models, which drop a sentence
/// when handed several at once.
final class SentencesTests: XCTestCase {
    private func split(_ text: String, _ language: String) -> [String] {
        let pieces = Sentences.split(text, in: Locale.Language(identifier: language))
        XCTAssertEqual(pieces.joined(), text, "the pieces join back into the paragraph")
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Greek asks with `;`. The question between two sentences was the one that vanished.
    func testGreekQuestionMarkEndsASentence() {
        XCTAssertEqual(split("Καλημέρα! Πού είναι ο σταθμός του μετρό; Θέλω να πάω στο κέντρο.", "el"),
                       ["Καλημέρα!", "Πού είναι ο σταθμός του μετρό;", "Θέλω να πάω στο κέντρο."])
    }

    func testAbbreviationsDoNotEndASentence() {
        XCTAssertEqual(split("Dr. Smith arrived at noon. He left at five.", "en"),
                       ["Dr. Smith arrived at noon.", "He left at five."])
    }

    /// Full-width marks take no space after them.
    func testChineseAndJapaneseEndWithoutSpaces() {
        XCTAssertEqual(split("今日は晴れです。明日は雨ですか？そうですね！", "ja"),
                       ["今日は晴れです。", "明日は雨ですか？", "そうですね！"])
        XCTAssertEqual(split("我们明天见。你好吗？", "zh-Hans"), ["我们明天见。", "你好吗？"])
    }

    func testDevanagariDandaEndsASentence() {
        XCTAssertEqual(split("मैं ठीक हूँ। आप कैसे हैं? धन्यवाद।", "hi"),
                       ["मैं ठीक हूँ।", "आप कैसे हैं?", "धन्यवाद।"])
    }

    func testArabicAndUrduMarksEndASentence() {
        XCTAssertEqual(split("كيف حالك؟ أنا بخير، شكرا.", "ar"), ["كيف حالك؟", "أنا بخير، شكرا."])
        XCTAssertEqual(split("یہ کتاب ہے۔ وہ قلم ہے۔", "ur"), ["یہ کتاب ہے۔", "وہ قلم ہے۔"])
    }

    /// The closing quote belongs to the sentence it closes.
    func testClosingQuoteStaysWithItsSentence() {
        XCTAssertEqual(split("«Où est la gare?» Personne ne savait.", "fr"),
                       ["«Où est la gare?»", "Personne ne savait."])
    }

    func testSingleSentenceStaysWhole() {
        XCTAssertEqual(split("Save", "en"), ["Save"])
        XCTAssertEqual(split("Wait?!", "en"), ["Wait?!"])
    }
}
