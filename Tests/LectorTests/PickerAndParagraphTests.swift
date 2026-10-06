import CoreGraphics
import LectorKit
import XCTest
@testable import Lector

/// Builds a capture from lines of words laid out left to right, one rect per word.
private func capture(_ lines: [(y: CGFloat, x: CGFloat, words: [String])],
                     wordWidth: CGFloat = 40, height: CGFloat = 20) -> RecognizedText {
    var words: [RecognizedWord] = []
    var built: [RecognizedLine] = []
    for (index, line) in lines.enumerated() {
        let start = words.count
        for (offset, word) in line.words.enumerated() {
            words.append(RecognizedWord(
                text: word,
                rect: CGRect(x: line.x + CGFloat(offset) * (wordWidth + 8), y: line.y,
                             width: wordWidth, height: height),
                lineIndex: index))
        }
        let rects = words[start...].map(\.rect)
        let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        built.append(RecognizedLine(text: line.words.joined(separator: " "), rect: union,
                                    wordRange: start..<words.count))
    }
    return RecognizedText(words: words, lines: built)
}

final class WordHitTestTests: XCTestCase {
    private let page = capture([
        (y: 0, x: 0, words: ["one", "two", "three"]),
        (y: 40, x: 0, words: ["four", "five", "six"]),
    ])

    func testPointBetweenLinesSnapsToNearerLine() {
        // Gap runs 20…40; 33 is nearer the second line.
        XCTAssertEqual(WordHitTest.word(at: CGPoint(x: 5, y: 33), in: page), 3)
        XCTAssertEqual(WordHitTest.word(at: CGPoint(x: 5, y: 24), in: page), 0)
    }

    func testDraggingPastLineEndExtendsToLastWord() {
        XCTAssertEqual(WordHitTest.word(at: CGPoint(x: 900, y: 10), in: page), 2)
    }

    func testColumnsAtSameHeightDoNotSteal() {
        // Two columns: left at x 0, right at x 400, both on y 0 and y 40.
        let columns = capture([
            (y: 0, x: 0, words: ["left1"]), (y: 0, x: 400, words: ["right1"]),
            (y: 40, x: 0, words: ["left2"]), (y: 40, x: 400, words: ["right2"]),
        ])
        // Just below the right column's first line: stays in the right column.
        XCTAssertEqual(WordHitTest.word(at: CGPoint(x: 410, y: 24), in: columns), 1)
    }

    func testEmptyCaptureHasNoWord() {
        XCTAssertNil(WordHitTest.word(at: .zero, in: .empty))
    }

    func testBackwardDragCoversSameWords() {
        XCTAssertEqual(WordSelection(anchor: 4, focus: 1).range, 1...4)
    }

    func testLineSelectionCoversWholeLine() {
        XCTAssertEqual(WordSelection.line(containing: 4, in: page).range, 3...5)
    }
}

final class ParagraphTests: XCTestCase {
    func testWrappedSentenceIsRejoinedAndShortLastLineEndsIt() {
        let text = capture([
            (y: 0, x: 0, words: ["The", "quick", "brown", "fox"]),
            (y: 24, x: 0, words: ["jumps", "over", "the", "lazy"]),
            (y: 48, x: 0, words: ["dog."]),
            (y: 72, x: 0, words: ["Next", "one", "starts", "here"]),
        ])
        XCTAssertEqual(Paragraphs.split(text), [
            "The quick brown fox jumps over the lazy dog.",
            "Next one starts here",
        ])
    }

    func testMenuItemsStaySeparate() {
        let menu = capture([
            (y: 0, x: 0, words: ["New", "Window", "Tab", "Group"]),
            (y: 24, x: 0, words: ["Open"]),
            (y: 48, x: 0, words: ["Close"]),
        ])
        XCTAssertEqual(Paragraphs.split(menu), ["New Window Tab Group", "Open", "Close"])
    }

    /// A full stop at the end of a line ends the paragraph where the next line is set
    /// apart from it or indented, or where the line is a short item rather than running
    /// text.
    func testSentenceEndingAtFullWidthEndsBeforeALineSetApart() {
        let spaced = capture([
            (y: 0, x: 0, words: ["First", "sentence", "ends", "here."]),
            (y: 34, x: 0, words: ["Second", "sentence", "keeps", "going"]),
        ])
        XCTAssertEqual(Paragraphs.split(spaced).count, 2)
        let indented = capture([
            (y: 0, x: 0, words: ["First", "sentence", "ends", "here."]),
            (y: 24, x: 30, words: ["Second", "sentence", "keeps"]),
        ])
        XCTAssertEqual(Paragraphs.split(indented).count, 2)
        let menu = capture([
            (y: 0, x: 0, words: ["Export", "As", "PDF…"]),
            (y: 24, x: 0, words: ["Print"]),
        ])
        XCTAssertEqual(Paragraphs.split(menu), ["Export As PDF…", "Print"])
    }

    /// A sentence can end at the very end of a line in the middle of a paragraph: the
    /// next line, set tight beneath from the same edge, carries the paragraph on.
    /// (Geometry from Lector's own OCR of 15pt text at 2x.)
    func testSentenceEndingAtTheEndOfAWrappedLineContinues() {
        let spanish = page([
            ("El año pasado viajamos por el norte de España durante tres semanas.",
             CGRect(x: 28, y: 36, width: 956, height: 41)),
            ("Visitamos pueblos pequeños, comimos en restaurantes familiares y",
             CGRect(x: 32, y: 76, width: 924, height: 35)),
            ("caminamos por la costa cantábrica cada mañana.", CGRect(x: 23, y: 108, width: 695, height: 41)),
        ])
        XCTAssertEqual(Paragraphs.split(spanish).count, 1)
        let portuguese = page([
            ("Não foi possível concluir a sua compra porque o cartão foi recusado.",
             CGRect(x: 34, y: 40, width: 936, height: 30)),
            ("Verifique os dados do cartão ou escolha outro método de pagamento.",
             CGRect(x: 28, y: 68, width: 966, height: 46)),
        ])
        XCTAssertEqual(Paragraphs.split(portuguese).count, 1)
    }

    /// Chat messages, a line each and spaced as list items are, stay apart though each
    /// ends a sentence and the first is the widest.
    func testChatMessagesStaySeparate() {
        let chat = page([
            ("Hey, are you coming tonight?", CGRect(x: 34, y: 40, width: 396, height: 34)),
            ("Oui, j'arrive vers huit heures.", CGRect(x: 34, y: 98, width: 390, height: 30)),
            ("¡Perfecto! Nos vemos allí.", CGRect(x: 30, y: 150, width: 352, height: 31)),
            ("Wunderbar, bis später!", CGRect(x: 34, y: 203, width: 314, height: 40)),
        ])
        XCTAssertEqual(Paragraphs.split(chat).count, 4)
    }

    /// Line boxes are as tall as what's in them: "инструкциями." has nothing above the
    /// x-height and gets half the height of the line before it, and a long line's box
    /// grows as it slants. The characters are as wide all the same. Type that really is
    /// smaller is narrower too.
    func testLinesOfOneSizeContinueWhateverTheirBoxHeight() {
        let russian = page([
            ("Пожалуйста, введите пароль, чтобы продолжить. Если вы забыли",
             CGRect(x: 23, y: 32, width: 962, height: 49)),
            ("пароль, нажмите «Восстановить доступ», и мы отправим вам письмо с",
             CGRect(x: 27, y: 71, width: 1045, height: 45)),
            ("инструкциями.", CGRect(x: 32, y: 121, width: 218, height: 24)),
        ])
        XCTAssertEqual(Paragraphs.split(russian).count, 1)
        let french = page([
            ("pouvez l'annuler à tout moment depuis la page de facturation, sans",
             CGRect(x: 34, y: 144, width: 972, height: 46)),
            ("frais supplémentaires.", CGRect(x: 32, y: 188, width: 324, height: 30)),
        ])
        XCTAssertEqual(Paragraphs.split(french).count, 1)
        let smallPrint = page([
            ("and this line of body text runs all the way across the column",
             CGRect(x: 0, y: 0, width: 800, height: 40)),
            ("small print about the offer sits under it", CGRect(x: 0, y: 44, width: 340, height: 24)),
        ])
        XCTAssertEqual(Paragraphs.split(smallPrint).count, 2)
    }

    func testSideBySideColumnsAreNotJoined() {
        let text = capture([
            (y: 0, x: 0, words: ["left", "column", "text"]),
            (y: 24, x: 400, words: ["right", "column", "text"]),
        ])
        XCTAssertEqual(Paragraphs.split(text).count, 2)
    }

    func testJoinRules() {
        XCTAssertEqual(Paragraphs.join("trans-", "lation"), "translation")
        XCTAssertEqual(Paragraphs.join("日本語の", "文章です"), "日本語の文章です")
        XCTAssertEqual(Paragraphs.join("hello", "world"), "hello world")
    }

    /// A hyphen before a capital or a digit belongs to the word: it isn't a break.
    func testHyphenKeptWhereTheWordHasOne() {
        XCTAssertEqual(Paragraphs.join("well-", "Known"), "well-Known")
        XCTAssertEqual(Paragraphs.join("Anti-", "Aging"), "Anti-Aging")
        XCTAssertEqual(Paragraphs.join("COVID-", "19"), "COVID-19")
        XCTAssertEqual(Paragraphs.join("infra\u{AD}", "structure"), "infrastructure")
    }

    /// "pre- and post-war": a hyphen left hanging for the next word, not a break.
    func testSuspendedHyphenKeepsItsSpace() {
        XCTAssertEqual(Paragraphs.join("pre-", "and post-war"), "pre- and post-war")
    }

    func testDashesJoinAsTyped() {
        XCTAssertEqual(Paragraphs.join("Monday -", "Friday"), "Monday - Friday")
        XCTAssertEqual(Paragraphs.join("the storm—", "and then"), "the storm—and then")
    }

    // MARK: Lines that start with a capital

    /// A line can't end on "at": the capital after it is a name, not a new paragraph.
    func testCapitalAfterAWordThatCantEndASentenceContinues() {
        let text = capture([
            (y: 0, x: 0, words: ["We", "can't", "stay", "here.", "Meet", "me", "at"]),
            (y: 24, x: 0, words: ["Old", "Lighthouse", "when", "the", "bells", "ring."]),
        ])
        XCTAssertEqual(Paragraphs.split(text), ["We can't stay here. Meet me at Old Lighthouse when the bells ring."])
    }

    /// German capitalises every noun, so a wrapped sentence often runs on with a
    /// capital. A line of running text that fills the column continues.
    func testCapitalContinuesAWrappedLineOfRunningText() {
        let text = capture([
            (y: 0, x: 0, words: ["Die", "Katze", "schläft", "auf", "dem", "warmen", "alten"]),
            (y: 24, x: 0, words: ["Sofa", "und", "träumt", "von", "Mäusen."]),
        ])
        XCTAssertEqual(Paragraphs.split(text), ["Die Katze schläft auf dem warmen alten Sofa und träumt von Mäusen."])
    }

    /// German capitalises its nouns and "Sie", so a line of a German paragraph can hold
    /// few lowercase words and the next can start with a capital: whether it's running
    /// text is told from the paragraph so far. (A 230pt column, from Lector's OCR.)
    func testGermanParagraphRunsOnAtCapitals() {
        let german = page([
            ("Wir freuen uns, Ihnen mitteilen zu", CGRect(x: 34, y: 40, width: 456, height: 34)),
            ("können, dass Ihre Bestellung", CGRect(x: 32, y: 80, width: 392, height: 32)),
            ("heute Morgen versandt wurde.", CGRect(x: 32, y: 118, width: 420, height: 28)),
            ("Die Sendungsverfolgung finden", CGRect(x: 34, y: 151, width: 432, height: 34)),
            ("Sie in Ihrem Kundenkonto.", CGRect(x: 32, y: 190, width: 358, height: 30)),
        ])
        XCTAssertEqual(Paragraphs.split(german), [
            "Wir freuen uns, Ihnen mitteilen zu können, dass Ihre Bestellung heute Morgen versandt wurde. "
                + "Die Sendungsverfolgung finden Sie in Ihrem Kundenkonto.",
        ])
    }

    /// A German menu has lowercase verbs too, but its items are no paragraph.
    func testGermanMenuStaysSeparate() {
        let menu = page([
            ("Neues Fenster öffnen", 0, 0, 220),
            ("Schließen", 0, 24, 100),
            ("Drucken", 0, 48, 90),
        ])
        XCTAssertEqual(Paragraphs.split(menu), ["Neues Fenster öffnen", "Schließen", "Drucken"])
    }

    /// A line that stops short of the column didn't wrap, whatever follows it.
    func testCapitalAfterALineThatStopsShortStartsAnew() {
        let text = capture([
            (y: 0, x: 0, words: ["The", "storm", "is", "coming", "and", "the", "ship"]),
            (y: 24, x: 0, words: ["needs", "repairs", "before", "we", "go"]),
            (y: 48, x: 0, words: ["Captain", "Mira", "waits", "by", "the", "old", "gate"]),
        ])
        XCTAssertEqual(Paragraphs.split(text).count, 2)
    }

    /// Title Case is how menus and headings are written, not running text.
    func testTitleCaseLineDoesNotRunIntoACapital() {
        let menu = capture([
            (y: 0, x: 0, words: ["Open", "Recent", "Files", "In", "Finder"]),
            (y: 24, x: 0, words: ["Close"]),
        ])
        XCTAssertEqual(Paragraphs.split(menu), ["Open Recent Files In Finder", "Close"])
    }

    /// A full stop inside closing quotes still ends the sentence, before a line set a
    /// little apart that would otherwise run on from a wrapped one.
    func testQuotedSentenceEndStillEnds() {
        let text = capture([
            (y: 0, x: 0, words: ["He", "said", "we", "would", "leave", "at", "dawn.\u{201D}"]),
            (y: 32, x: 0, words: ["They", "left", "at", "noon", "instead", "of", "dawn."]),
        ])
        XCTAssertEqual(Paragraphs.split(text).count, 2)
    }

    /// In Greek ";" is the question mark: the sentence ends there.
    func testGreekQuestionMarkEndsTheSentence() {
        let greek = page([
            ("Πού είναι ο σταθμός του μετρό;", 0, 0, 240),
            ("Θέλω να πάω στο κέντρο της Αθήνας.", 0, 24, 360),
        ])
        XCTAssertEqual(Paragraphs.split(greek).count, 2)
    }

    /// A preposition or conjunction no sentence ends on carries the line on, even into
    /// a capital after a line that stopped short. A pronoun can end one.
    func testLineEndingOnAConnectorContinues() {
        for (earlier, later) in [
            ("Мы отправим вам письмо с", "Ссылкой на страницу входа в приложение."),
            ("Szczegóły znajdziesz w", "Polityce prywatności naszego sklepu."),
            ("Siparişiniz kargoya verildi ve", "Yarın adresinize teslim edilecek."),
            ("Θα σας στείλουμε ένα μήνυμα με", "Οδηγίες για την επαναφορά."),
        ] {
            XCTAssertEqual(Paragraphs.split(page([(earlier, 0, 0, 200), (later, 0, 24, 400)])).count, 1, earlier)
        }
        let pronoun = page([("Кто это сделал? Это был я", 0, 0, 200), ("Никто не видел.", 0, 24, 400)])
        XCTAssertEqual(Paragraphs.split(pronoun).count, 2)
    }

    // MARK: Breaks

    /// A word broken across lines is one word, however short the line it ends.
    func testHyphenatedLineContinuesEvenWhenShort() {
        let text = capture([
            (y: 0, x: 0, words: ["Critics", "argue", "that", "the", "cost", "of", "the"]),
            (y: 24, x: 0, words: ["new", "infra-"]),
            (y: 48, x: 0, words: ["structure", "was", "too", "high."]),
        ])
        XCTAssertEqual(Paragraphs.split(text), ["Critics argue that the cost of the new infrastructure was too high."])
    }

    /// Dialogue turns and list items start a new paragraph even in lowercase.
    func testDialogueTurnsAndBulletsStaySeparate() {
        let dialogue = capture([
            (y: 0, x: 0, words: ["-", "Where", "are", "you", "going"]),
            (y: 24, x: 0, words: ["-", "home", "before", "it", "rains"]),
        ])
        XCTAssertEqual(Paragraphs.split(dialogue).count, 2)
        let list = capture([
            (y: 0, x: 0, words: ["•", "first", "item", "of", "the", "list"]),
            (y: 24, x: 0, words: ["•", "second", "item", "of", "the", "list"]),
        ])
        XCTAssertEqual(Paragraphs.split(list).count, 2)
    }

    /// The space between paragraphs is wider than the space between their lines, even
    /// where it is narrow.
    func testParagraphSpacingSeparatesParagraphs() {
        let text = capture([
            (y: 0, x: 0, words: ["the", "first", "paragraph", "runs", "over", "two"]),
            (y: 24, x: 0, words: ["lines", "and", "then", "it", "stops", "here"]),
            (y: 58, x: 0, words: ["another", "paragraph", "begins", "here", "below", "it"]),
        ])
        XCTAssertEqual(Paragraphs.split(text).count, 2)
    }

    // MARK: Scripts

    /// Lines in different scripts are different texts however close they sit: a Russian
    /// menu line over a Thai sentence. A Latin name in Japanese doesn't split it.
    func testLinesInDifferentScriptsStaySeparate() {
        let text = page([
            ("Файл • Правка • Вид • Окно", CGRect(x: 32, y: 37, width: 382, height: 36)),
            ("สวัสดีครับ วันนี้อากาศดีมาก", CGRect(x: 32, y: 82, width: 344, height: 41)),
            ("Bitte melden Sie sich an.", CGRect(x: 34, y: 151, width: 336, height: 28)),
        ])
        XCTAssertEqual(Paragraphs.split(text).count, 3)
        let japanese = page([
            ("新しいモデルの発表会は来週の", 0, 0, 300),
            ("iPhone 16 Proが中心です。", 0, 24, 200),
        ])
        XCTAssertEqual(Paragraphs.split(japanese).count, 1)
    }

    // MARK: Scripts without case

    /// A menu in Japanese: no capitals to go by, and lines of nearly the same length. Only
    /// a line that runs to the column's very end has wrapped.
    func testUnspacedMenuLinesStaySeparate() {
        let menu = page([
            ("本日のおすすめ料理", 0, 0, 180),
            ("焼き魚定食と味噌汁", 0, 24, 180),
            ("緑茶または冷たい水", 0, 48, 180),
            ("デザートは季節の果物です", 0, 72, 240),
        ])
        XCTAssertEqual(Paragraphs.split(menu).count, 4)
        let prose = page([
            ("日本語の文章はとても長くて", 0, 0, 260),
            ("読むのが大変です。", 0, 24, 180),
        ])
        XCTAssertEqual(Paragraphs.split(prose), ["日本語の文章はとても長くて読むのが大変です。"])
    }

    /// Menu items of two kanji each all reach the end of the column they make up; none of
    /// them is a line of prose that wrapped. (Lector's OCR of 15pt labels at 2x.)
    func testShortUnspacedItemsOfOneWidthStaySeparate() {
        let menu = page([
            ("設定", CGRect(x: 30, y: 38, width: 62, height: 30)),
            ("保存", CGRect(x: 30, y: 92, width: 62, height: 32)),
            ("削除", CGRect(x: 30, y: 148, width: 62, height: 32)),
            ("検索", CGRect(x: 30, y: 206, width: 62, height: 30)),
            ("終了", CGRect(x: 30, y: 262, width: 60, height: 30)),
        ])
        XCTAssertEqual(Paragraphs.split(menu), ["設定", "保存", "削除", "検索", "終了"])
    }

    /// A right-aligned Hebrew menu: short items, each its own line.
    func testRightToLeftMenuStaysSeparate() {
        let menu = page([
            ("תפריט המסעדה", 280, 0, 120),
            ("מרק עוף חם", 300, 24, 100),
            ("סלט ירקות טרי", 270, 48, 130),
            ("קינוח שוקולד", 280, 72, 120),
        ])
        XCTAssertEqual(Paragraphs.split(menu).count, 4)
    }
}

/// Lines at given positions and widths, each word as wide as its share of the letters.
private func page(_ lines: [(text: String, x: CGFloat, y: CGFloat, width: CGFloat)], height: CGFloat = 20) -> RecognizedText {
    page(lines.map { ($0.text, CGRect(x: $0.x, y: $0.y, width: $0.width, height: height)) })
}

/// Lines in the given boxes, each word as wide as its share of the letters.
private func page(_ lines: [(text: String, rect: CGRect)]) -> RecognizedText {
    var words: [RecognizedWord] = []
    var built: [RecognizedLine] = []
    for (index, line) in lines.enumerated() {
        let start = words.count
        let parts = line.text.split(separator: " ").map(String.init)
        let letters = CGFloat(parts.reduce(0) { $0 + $1.count })
        let room = line.rect.width - CGFloat(parts.count - 1) * 8
        var x = line.rect.minX
        for part in parts {
            let width = room * CGFloat(part.count) / max(letters, 1)
            words.append(RecognizedWord(text: part, rect: CGRect(x: x, y: line.rect.minY, width: width,
                                                                 height: line.rect.height),
                                        lineIndex: index))
            x += width + 8
        }
        built.append(RecognizedLine(text: line.text, rect: line.rect, wordRange: start..<words.count))
    }
    return RecognizedText(words: words, lines: built)
}
