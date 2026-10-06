import XCTest
@testable import Lector

final class TranslationPlanTests: XCTestCase {
    private let hebrew = Locale.Language(identifier: "he")

    private func plan(_ texts: [String], choosing: String? = nil) -> TranslationPlan {
        TranslationPlan(texts, target: hebrew, choosing: choosing.map { Locale.Language(identifier: $0) },
                        preferring: ["en", "he"])
    }

    private func sources(_ plan: TranslationPlan) -> [String?] {
        plan.items.map { item in
            if case .translate(let source) = item { return source.languageCode?.identifier }
            return nil
        }
    }

    /// A chat in four languages into Hebrew: each message from its own language; the
    /// Hebrew one, the command and the time are left as they are.
    func testMixedScreenTranslatesEachParagraphFromItsOwnLanguage() {
        let plan = plan([
            "Did you see the new update? The live mode is great.",
            "כן, ראיתי. זה עובד מעולה במחשב שלי.",
            "On se retrouve demain à la gare vers huit heures ?",
            "git commit -m \"fix overlay\"",
            "¿Puedes enviarme el enlace otra vez?",
            "18:45",
        ])
        XCTAssertEqual(sources(plan), ["en", nil, "fr", nil, "es", nil])
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["en", "fr", "es"])
        XCTAssertEqual(plan.groups.map(\.paragraphs), [[0], [2], [4]])
    }

    func testCaptureAlreadyInTheTargetLanguageIsSaidSo() {
        let plan = plan(["שלום עולם", "האוכל טעים מאוד היום", "12:30"])
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.outcome, .alreadyInTarget)
    }

    func testCaptureOfOnlyNumbersAndCodeHasNothingToTranslate() {
        let plan = plan(["18:45", "⌘⇧2", "https://lector.app/help"])
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.outcome, .nothingToTranslate)
    }

    /// Paragraphs of one language form one group, in reading order, however far apart.
    func testGroupsCollectEachLanguageInReadingOrder() {
        let plan = plan([
            "The storm will reach the harbour before nightfall.",
            "Le navire a encore besoin de réparations importantes.",
            "Meet me at the old lighthouse when the bells ring.",
        ])
        XCTAssertEqual(plan.groups.map(\.paragraphs), [[0, 2], [1]])
    }

    /// Choosing Japanese for kanji Apple's detector calls Chinese.
    func testChosenSourceDecidesAmbiguousText() {
        XCTAssertEqual(sources(plan(["注意事項", "Press Start"])), ["zh", "en"])
        XCTAssertEqual(sources(plan(["注意事項", "Press Start"], choosing: "ja")), ["ja", "en"])
    }

    /// The multilingual test page as Lector reads it, a paragraph per entry.
    private let page = [
        "Paramètres du compte",
        "Votre abonnement sera renouvelé automatiquement le 3 mars. Vous pouvez l'annuler à tout moment depuis la "
            + "page de facturation, sans frais supplémentaires.",
        "Καλημέρα! Πού είναι ο σταθμός του μετρό; Θέλω να πάω στο κέντρο της Αθήνας.",
        "Enregistrer", "שלום! זה טקסט שכבר כתוב בעברית, ולכן אין צורך לתרגם אותו.", "Annuler",
        "設定", "ご注文の商品は本日発送いたしました。お届けまで二、三日かかる場合がございます。",
        "設定", "保存", "削除", "検索", "파일", "편집", "보기", "설정", "الإعدادات",
        "نود أن نعلمكم بأن طلبكم قد تم شحنه صباح اليوم. يمكنكم تتبع الشحنة من خلال حسابكم الشخصي.",
        "Willkommen zurück", "Bitte melden Sie sich an, um fortzufahren. Haben Sie Ihr Passwort vergessen?",
        "La segunda columna también tiene un texto largo que ocupa varias líneas en la pantalla.",
        "Файл • Правка • Вид • Окно • Справка", "Où est la gare, s'il vous plaît ?",
    ]

    /// The test page's kanji labels are translated from Japanese, like the Japanese
    /// paragraph beside them. None is left untranslated for being too short to tell.
    func testKanjiLabelsOnAMixedPageAreTranslatedFromJapanese() {
        XCTAssertEqual(sources(plan(page)), [
            "fr", "fr", "el", "fr", nil, "fr", "ja", "ja", "ja", "ja", "ja", "ja", "ko", "ko", "ko", "ko", "ar", "ar",
            "de", "de", "es", "ru", "fr",
        ])
    }

    /// Simplified and Traditional Chinese are translated between: Traditional text is
    /// already in a Traditional target, not in a Simplified one.
    func testChineseScriptsAreTranslatedBetween() {
        let traditional = ["我們的應用程式可以幫助您更好地管理時間。"]
        let intoTraditional = TranslationPlan(traditional, target: Locale.Language(identifier: "zh-Hant"), choosing: nil,
                                              preferring: ["en"])
        XCTAssertEqual(intoTraditional.outcome, .alreadyInTarget)
        let intoSimplified = TranslationPlan(traditional, target: Locale.Language(identifier: "zh-Hans"), choosing: nil,
                                             preferring: ["en"])
        XCTAssertEqual(intoSimplified.items, [.translate(Locale.Language(identifier: "zh-Hant"))])
    }

    /// A language remembered for the app from an earlier capture doesn't turn labels that
    /// plainly read as another language into its own.
    func testRememberedSourceDoesNotOverrulePlainLabels() {
        XCTAssertEqual(sources(plan(["Enregistrer", "Annuler"], choosing: "nl")), ["fr", "fr"])
    }

    /// Dutch remembered for Safari decides nothing on the test page, in eight languages
    /// and none of them Dutch.
    func testRememberedLanguageDecidesNothingOnAPageThatReadsOtherwise() {
        XCTAssertEqual(sources(plan(page, choosing: "nl")), sources(plan(page)))
    }

    /// A game's status bar is numbers: left as it is, beside the text that's translated.
    func testGameStatsAreLeftAsTheyAre() {
        let plan = plan(["HP 120/120  MP 45/60", "Quest complete! You received 300 gold and the Iron Sword."])
        XCTAssertEqual(sources(plan), [nil, "en"])
    }
}

final class ContextWindowTests: XCTestCase {
    /// Neighbours share a request in reading order, every paragraph exactly once, and a
    /// window never passes its limits unless it is a single paragraph.
    func testWindowsCoverEveryParagraphOnceWithinLimits() {
        let texts = ["General", "Appearance", "Notifications", String(repeating: "word ", count: 30),
                     "Privacy", "Save", "Cancel"]
        let windows = ContextWindows.windows(texts, maxCharacters: 60, maxCount: 3, alone: 100)
        XCTAssertEqual(windows.flatMap { Array($0) }, Array(texts.indices))
        for window in windows where window.count > 1 {
            XCTAssertLessThanOrEqual(window.count, 3)
            XCTAssertLessThanOrEqual(window.map { texts[$0].count }.reduce(0, +), 60)
        }
    }

    /// A paragraph long enough to be its own context is sent on its own.
    func testLongParagraphGoesAlone() {
        let long = String(repeating: "x", count: 300)
        let windows = ContextWindows.windows(["a", long, "b"], maxCharacters: 400, maxCount: 16, alone: 240)
        XCTAssertEqual(windows, [0..<1, 1..<2, 2..<3])
    }

    /// With no offline draft up meanwhile, the first window is small so something shows
    /// soon; the rest go in full windows. A character of Japanese weighs like a word.
    func testLeadingWindowIsSmall() {
        let menu = ["本日のおすすめ料理", "焼き魚定食と味噌汁", "緑茶または冷たい水", "デザートは季節の果物です"]
        XCTAssertEqual(ContextWindows.windows(menu), [0..<4])
        XCTAssertEqual(ContextWindows.windows(menu, lead: 60), [0..<2, 2..<4])
        XCTAssertEqual(ContextWindows.windows(menu, lead: 40), [0..<1, 1..<4])
        XCTAssertEqual(ContextWindows.windows(["General", "Appearance", "Notifications"], lead: 8), [0..<1, 1..<3])
    }

    func testSeparatorIsOneTheTextDoesNotUse() {
        XCTAssertEqual(ContextWindows.separator(for: ["Home", "About"]), " | ")
        XCTAssertEqual(ContextWindows.separator(for: ["Home | About", "Contact"]), " · ")
        XCTAssertNil(ContextWindows.separator(for: ["a | b · c ¶ d", "e"]))
    }

    /// Hebrew comes back in logical order, so the parts are in the paragraphs' order.
    func testTranslationSplitsBackOnePartPerParagraph() {
        XCTAssertEqual(ContextWindows.split("כללי | מראה | שמור", separator: " | ", count: 3), ["כללי", "מראה", "שמור"])
        XCTAssertEqual(ContextWindows.split("Général ·Apparence· Enregistrer", separator: " · ", count: 3),
                       ["Général", "Apparence", "Enregistrer"])
    }

    /// A translation that merged, dropped or invented a mark can't be matched up.
    func testMismatchedTranslationIsRejected() {
        XCTAssertNil(ContextWindows.split("כללי | מראה", separator: " | ", count: 3))
        XCTAssertNil(ContextWindows.split("כללי |  | שמור", separator: " | ", count: 3))
        XCTAssertNil(ContextWindows.split("a | b | c | d", separator: " | ", count: 3))
    }
}
