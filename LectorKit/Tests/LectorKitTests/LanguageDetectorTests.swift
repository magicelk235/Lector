import XCTest
@testable import LectorKit

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

    // MARK: Paragraph by paragraph

    private func codes(_ paragraphs: [String], choosing chosen: String? = nil) -> [String?] {
        LanguageDetector.languages(of: paragraphs, preferring: ["en", "he"],
                                   choosing: chosen.map { Locale.Language(identifier: $0) })
            .languages.map { $0?.languageCode?.identifier }
    }

    /// Language codes, and for Chinese which of its scripts: "zh-Hant", "zh-Hans".
    private func variants(_ paragraphs: [String], choosing chosen: String? = nil) -> [String?] {
        LanguageDetector.languages(of: paragraphs, preferring: ["en", "he"],
                                   choosing: chosen.map { Locale.Language(identifier: $0) })
            .languages.map { language in
                guard let code = language?.languageCode?.identifier, code == "zh", let language else {
                    return language?.languageCode?.identifier
                }
                return Locale.Language(identifier: language.maximalIdentifier).script.map { "zh-\($0.identifier)" }
            }
    }

    /// A chat or a page in several languages: each paragraph is read for itself, not
    /// forced into whichever language most of the screen is in.
    func testEachParagraphGetsItsOwnLanguage() {
        XCTAssertEqual(codes([
            "Did you see the new update? The live mode is great.",
            "כן, ראיתי. זה עובד מעולה במחשב שלי.",
            "On se retrouve demain à la gare vers huit heures ?",
            "¿Puedes enviarme el enlace otra vez?",
        ]), ["en", "he", "fr", "es"])
    }

    /// A label too short to tell on its own is in the language of the rest of the
    /// capture, not the user's own just because it's a word there too.
    func testShortLabelsFollowTheRestOfTheCapture() {
        let paragraphs = ["Le fichier a été enregistré sur votre ordinateur.", "Annuler", "Options", "Menu", "Général"]
        let result = LanguageDetector.languages(of: paragraphs, preferring: ["en", "he"])
        XCTAssertEqual(result.dominant?.languageCode?.identifier, "fr")
        XCTAssertEqual(codes(paragraphs), ["fr", "fr", "fr", "fr", "fr"])
    }

    func testParagraphWithoutLettersHasNoLanguage() {
        XCTAssertEqual(codes(["18:45", "Bonjour tout le monde, comment allez-vous aujourd'hui ?"]), [nil, "fr"])
    }

    /// "注意事項" is written the same in Japanese and Chinese and reads as Chinese (0.89)
    /// on its own. Kana anywhere else in the capture settles it as Japanese.
    func testKanjiFollowsTheRestOfTheCapture() {
        XCTAssertEqual(codes(["注意事項", "Press Start"]), ["zh", "en"])
        XCTAssertEqual(codes(["注意事項", "季節の果物です。どうぞお楽しみください。"]), ["ja", "ja"])
    }

    /// The kanji labels of a page in eight languages, among them a Japanese paragraph:
    /// Japanese, every one — not Chinese, and not left out for being too short to read.
    func testKanjiLabelsOnAMixedPageFollowItsJapanese() {
        let page = [
            "Votre abonnement sera renouvelé automatiquement le 3 mars.", "Enregistrer",
            "שלום! זה טקסט שכבר כתוב בעברית, ולכן אין צורך לתרגם אותו.",
            "設定", "ご注文の商品は本日発送いたしました。お届けまで二、三日かかる場合がございます。",
            "設定", "保存", "削除", "検索", "파일", "편집", "보기",
            "Willkommen zurück", "Файл • Правка • Вид • Окно • Справка",
        ]
        XCTAssertEqual(codes(page), ["fr", "fr", "he", "ja", "ja", "ja", "ja", "ja", "ja", "ko", "ko", "ko", "de", "ru"])
    }

    /// With no Japanese on the page, kanji labels are Chinese, Traditional or Simplified
    /// by the forms of their characters — 設/设, 刪/删, 檢/检 — and a label both write
    /// alike ("保存") by the forms around it. With none to go by, Simplified.
    func testKanjiLabelsWithoutJapaneseAreChineseByTheirForms() {
        let french = "Votre abonnement sera renouvelé automatiquement le 3 mars."
        XCTAssertEqual(variants([french, "設定", "保存", "刪除", "檢索"]), ["fr", "zh-Hant", "zh-Hant", "zh-Hant", "zh-Hant"])
        XCTAssertEqual(variants([french, "设置", "保存", "删除", "检索"]), ["fr", "zh-Hans", "zh-Hans", "zh-Hans", "zh-Hans"])
        XCTAssertEqual(variants([french, "設定", "保存"]), ["fr", "zh-Hant", "zh-Hant"])
        XCTAssertEqual(variants([french, "保存"]), ["fr", "zh-Hans"])
    }

    /// A form only Japanese writes ("検索", "設定保存削除検索") is Japanese, and settles the
    /// labels beside it.
    func testJapaneseFormsSettleKanjiLabels() {
        XCTAssertEqual(codes(["設定", "保存", "削除", "検索", "終了"]), ["ja", "ja", "ja", "ja", "ja"])
    }

    /// A language remembered for the app settles kanji only where the page doesn't:
    /// beside Japanese, kanji labels are Japanese though the app was last read as Chinese,
    /// and beside a label only Chinese writes ("设置"), Chinese though it was read as
    /// Japanese.
    func testRememberedChoiceDoesNotOutweighThePage() {
        XCTAssertEqual(codes(["設定", "ご注文の商品は本日発送いたしました。"], choosing: "zh-Hant"), ["ja", "ja"])
        XCTAssertEqual(variants(["保存", "设置"], choosing: "ja"), ["zh-Hans", "zh-Hans"])
    }

    /// The user's choice of Japanese decides kanji, but not a line in another script.
    func testChosenLanguageAppliesWhereItsScriptIs() {
        XCTAssertEqual(codes(["注意事項", "Press Start"], choosing: "ja"), ["ja", "en"])
    }

    /// A choice settles what can't be told — "Service" reads as English or French — but
    /// not a whole sentence plainly in another language in the same script.
    func testChosenLanguageDoesNotOverruleAConfidentReading() {
        XCTAssertEqual(codes(["Hello there, how are you doing this fine morning", "Service"], choosing: "fr"),
                       ["en", "fr"])
    }

    /// A language remembered for the app from an earlier capture doesn't make a word that
    /// plainly reads otherwise its own: "Enregistrer" is French at 0.93 though Safari was
    /// last read as Dutch. "Annuleren", which the recogniser half takes for Danish, is
    /// what the remembered Dutch settles.
    func testRememberedChoiceSettlesOnlyWhatCantBeTold() {
        XCTAssertEqual(codes(["Enregistrer", "Annuleren"], choosing: "nl"), ["fr", "nl"])
    }

    /// Picked for this very capture, the choice decides the plain paragraphs too, so Tab
    /// in the overlay always changes something — but only in its own script.
    func testFirmChoiceDecidesEveryParagraphInItsScript() {
        let languages = LanguageDetector.languages(of: ["Hello there, how are you doing this fine morning", "注意事項"],
                                                   preferring: ["en"], choosing: Locale.Language(identifier: "fr"),
                                                   firmly: true)
        XCTAssertEqual(languages.languages.map { $0?.languageCode?.identifier }, ["fr", "zh"])
    }

    // MARK: Telling neighbours apart

    /// One misread word ("Настпойки") makes a Russian menu read as Kazakh, 0.62 against
    /// Russian's 0.38. Between two readings in one script the widely used language is
    /// the likelier.
    func testMisreadWordDoesNotTurnAMenuIntoALessUsedLanguage() {
        let menu = ["Файл", "Правка", "Вид", "Окно", "Справка", "Настпойки"]
        XCTAssertEqual(codes(menu), Array(repeating: "ru", count: menu.count))
        XCTAssertEqual(detect(menu.joined(separator: "\n")), "ru")
    }

    /// The recogniser has no Serbian or Macedonian and calls them Bulgarian or Kazakh
    /// with certainty. Their letters tell them: ђ ћ are Serbian, ѓ ќ ѕ Macedonian, and
    /// ј љ њ џ either — Serbian, read by four times as many, the likelier.
    func testSerbianAndMacedonianAreToldByTheirLetters() {
        XCTAssertEqual(detect("Добар дан! Можете ли ми рећи где се налази најближа апотека?"), "sr")
        XCTAssertEqual(detect("Тражим лек за главобољу."), "sr")
        XCTAssertEqual(detect("Добро утро, како сте? Ќе дојдам утре."), "mk")
        XCTAssertEqual(codes(["Добар дан! Можете ли ми рећи где се налази најближа апотека?",
                              "Тражим лек за главобољу."]), ["sr", "sr"])
    }

    /// A Serbian menu has few of Serbian's own letters, and the recogniser reads the rest
    /// as Bulgarian with certainty ("Уреди", 0.995): the letters elsewhere in the capture
    /// decide them, as Serbian remembered for the app does.
    func testSerbianLabelsWithoutSerbianLettersFollowTheCaptureOrTheChoice() {
        XCTAssertEqual(codes(["Датотека", "Уреди", "Приказ", "Прозор", "Помоћ"]), ["sr", "sr", "sr", "sr", "sr"])
        XCTAssertEqual(codes(["Уреди"], choosing: "sr"), ["sr"])
        XCTAssertEqual(codes(["Уреди"]), ["bg"])
    }

    /// A letter misread in a Russian line doesn't make it Serbian: Russian's own
    /// letters (я, й, ы, ь) far outnumber it.
    func testStrayLetterDoesNotOutweighTheRest() {
        XCTAssertEqual(detect("Привет, как дела? Я хочу купить билет на поезд ј"), "ru")
    }

    /// The recogniser reads Persian as Arabic (0.999) or Urdu. Letters Arabic doesn't
    /// have — پ چ ژ گ ی ک, and the non-joiner of می‌خواهم — tell Persian; Urdu has letters
    /// of its own besides (ٹ ڈ ڑ ں ے ہ).
    func testPersianAndUrduAreToldByTheirLetters() {
        XCTAssertEqual(detect("سلام، حال شما چطور است؟ من می‌خواهم یک بلیت قطار برای فردا صبح به تهران بخرم."), "fa")
        XCTAssertEqual(detect("لطفاً به من کمک کنید."), "fa")
        XCTAssertEqual(detect("تنظیمات"), "fa")
        XCTAssertEqual(detect("آپ کیسے ہیں؟ میں کل صبح لاہور جانے کے لیے ٹرین کا ٹکٹ خریدنا چاہتا ہوں۔"), "ur")
        XCTAssertEqual(detect("مرحباً بكم في تطبيقنا. يرجى إدخال اسم المستخدم وكلمة المرور للمتابعة."), "ar")
        // Iraqi Arabic writes چ and گ, among many more of Arabic's own letters.
        XCTAssertEqual(detect("شلونك؟ شكو ماكو؟ چا وين رحت؟"), "ar")
    }

    /// Lines with no script in common aren't one text; a Latin name in Japanese doesn't
    /// make two.
    func testScriptsInCommon() {
        XCTAssertFalse(LanguageDetector.sharesScript("Файл • Правка • Вид • Окно", with: "สวัสดีครับ วันนี้อากาศดีมาก"))
        XCTAssertTrue(LanguageDetector.sharesScript("新しいモデルの", with: "iPhone 16 Proを発表しました"))
        XCTAssertTrue(LanguageDetector.sharesScript("設定", with: "ファイル"))
        XCTAssertTrue(LanguageDetector.sharesScript("Total", with: "12:30"))
    }

    /// What Tab offers when the detection is wrong: for kanji, both Chinese and Japanese.
    func testCandidatesForKanjiIncludeChineseAndJapanese() {
        let candidates = LanguageDetector.candidates(for: "緑茶 冷水 季節 果物").map { $0.languageCode?.identifier }
        XCTAssertTrue(candidates.contains("ja"), "\(candidates)")
        XCTAssertTrue(candidates.contains("zh"), "\(candidates)")
    }

    func testCandidatesLeaveOutTheExcludedLanguage() {
        let candidates = LanguageDetector.candidates(for: "Bonjour tout le monde", excluding: Locale.Language(identifier: "fr"))
        XCTAssertFalse(candidates.contains { $0.languageCode?.identifier == "fr" })
        XCTAssertFalse(candidates.isEmpty)
    }

    /// Simplified and Traditional Chinese are two languages to translate between: with
    /// Traditional the target, Simplified is still on offer for Chinese text.
    func testCandidatesTellChineseScriptsApart() {
        let traditional = Locale.Language(identifier: "zh-Hant")
        let candidates = LanguageDetector.candidates(for: "我们的应用程序可以帮助您更好地管理时间。", excluding: traditional)
        XCTAssertTrue(candidates.contains { LanguageDetector.same($0, Locale.Language(identifier: "zh-Hans")) }, "\(candidates)")
        XCTAssertFalse(candidates.contains { LanguageDetector.same($0, traditional) }, "\(candidates)")
    }

    func testLanguagesAreWrittenInTheirOwnScripts() {
        let ja = Locale.Language(identifier: "ja")
        XCTAssertTrue(LanguageDetector.isWritten("本日のおすすめ料理", in: ja))
        XCTAssertTrue(LanguageDetector.isWritten("緑茶", in: ja))
        XCTAssertTrue(LanguageDetector.isWritten("緑茶", in: Locale.Language(identifier: "zh")))
        XCTAssertFalse(LanguageDetector.isWritten("Press Start", in: ja))
        XCTAssertTrue(LanguageDetector.isWritten("Привет", in: Locale.Language(identifier: "ru")))
        XCTAssertFalse(LanguageDetector.isWritten("Привет", in: Locale.Language(identifier: "fr")))
        XCTAssertTrue(LanguageDetector.isWritten("שלום", in: Locale.Language(identifier: "he")))
        XCTAssertFalse(LanguageDetector.isWritten("12:30", in: Locale.Language(identifier: "en")))
    }
}
