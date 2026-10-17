import XCTest
@testable import Lector

final class WordLookupTermTests: XCTestCase {
    func testPunctuationAroundAWordIsDropped() {
        XCTAssertEqual(WordLookup.term("«Bonjour!»"), "Bonjour")
        XCTAssertEqual(WordLookup.term("「設定」"), "設定")
        XCTAssertEqual(WordLookup.term("(castle),"), "castle")
        XCTAssertEqual(WordLookup.term("\"quoted\""), "quoted")
        XCTAssertEqual(WordLookup.term("“curly”"), "curly")
        XCTAssertEqual(WordLookup.term("終わり。"), "終わり")
        XCTAssertEqual(WordLookup.term("¿Qué?"), "Qué")
        XCTAssertEqual(WordLookup.term(" spaced \n"), "spaced")
    }

    func testPunctuationInsideAWordStays() {
        XCTAssertEqual(WordLookup.term("l'homme"), "l'homme")
        XCTAssertEqual(WordLookup.term("e-mail."), "e-mail")
        XCTAssertEqual(WordLookup.term("(U.S.A.)"), "U.S.A")
    }

    func testSymbolsAreNotPunctuation() {
        XCTAssertEqual(WordLookup.term("C++"), "C++")
        XCTAssertEqual(WordLookup.term("$5,"), "$5")
    }

    func testAWordOfOnlyPunctuationIsKept() {
        XCTAssertEqual(WordLookup.term("—"), "—")
    }
}

final class WordLookupReadingTests: XCTestCase {
    private let japanese = Locale.Language(identifier: "ja")
    private let chinese = Locale.Language(identifier: "zh-Hans")

    func testJapaneseWithKanjiIsReadInHiragana() {
        XCTAssertEqual(WordLookup.reading(of: "設定", language: japanese), "せってい")
        XCTAssertEqual(WordLookup.reading(of: "東京駅", language: japanese), "とうきょうえき")
        XCTAssertEqual(WordLookup.reading(of: "食べる", language: japanese), "たべる")
    }

    func testKanaOnlyJapaneseHasNoReading() {
        XCTAssertNil(WordLookup.reading(of: "ゼルダ", language: japanese))
        XCTAssertNil(WordLookup.reading(of: "ひらがな", language: nil))
    }

    func testKanaMakesUnlabelledTextJapanese() {
        XCTAssertEqual(WordLookup.reading(of: "食べる", language: nil), "たべる")
    }

    func testKanjiIsJapaneseOrChineseByLanguage() {
        XCTAssertEqual(WordLookup.reading(of: "設定", language: japanese), "せってい")
        XCTAssertEqual(WordLookup.reading(of: "設定", language: chinese), "shè dìng")
    }

    func testChineseIsReadInPinyinWithTones() {
        XCTAssertEqual(WordLookup.reading(of: "学习", language: chinese), "xué xí")
        // Kanji alone, with no language, is taken for Chinese.
        XCTAssertEqual(WordLookup.reading(of: "中国人", language: nil), "zhōng guó rén")
    }

    func testOtherScriptsAreRomanised() {
        XCTAssertEqual(WordLookup.reading(of: "안녕하세요", language: nil), "annyeonghaseyo")
        XCTAssertEqual(WordLookup.reading(of: "Привет", language: nil), "Privet")
        XCTAssertEqual(WordLookup.reading(of: "Αθήνα", language: nil), "Athena")
        XCTAssertEqual(WordLookup.reading(of: "สวัสดี", language: nil), "swasdi")
    }

    func testLatinScriptHasNoReading() {
        XCTAssertNil(WordLookup.reading(of: "Hello", language: nil))
        XCTAssertNil(WordLookup.reading(of: "café", language: Locale.Language(identifier: "fr")))
        XCTAssertNil(WordLookup.reading(of: "Straße", language: nil))
        XCTAssertNil(WordLookup.reading(of: "Hello", language: japanese))
    }
}
