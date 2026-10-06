import AppKit
import CoreGraphics
import LectorKit
import XCTest
@testable import Lector

final class TranslationRendererTests: XCTestCase {
    private func tokens(_ text: String) -> [String] {
        TranslationRenderer.tokens(in: text).map { (text as NSString).substring(with: $0) }
    }

    /// Every character but spaces belongs to a word, so copying all the translated
    /// words gives back the sentence with its punctuation.
    func testWordsCarryTheirPunctuation() {
        XCTAssertEqual(tokens("Hello, world (again)."), ["Hello,", "world", "(again)."])
        XCTAssertEqual(tokens("«Bonjour» — dit-il."), ["«Bonjour»", "—", "dit-il."])
        XCTAssertEqual(tokens("שלום, עולם."), ["שלום,", "עולם."])
    }

    /// Without spaces, words come from word breaking, and joined back they are the
    /// original text.
    func testUnspacedScriptIsSplitIntoWords() {
        let words = tokens("日本語の文章です。")
        XCTAssertGreaterThan(words.count, 1)
        XCTAssertEqual(words.joined(), "日本語の文章です。")
    }

    func testBlankTextHasNoWords() {
        XCTAssertEqual(tokens("   "), [])
    }

    /// Hebrew with English names inside it: each word's box must sit inside its
    /// paragraph, or its highlight lands off the text.
    func testRightToLeftWordsWithEmbeddedEnglishStayInside() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = try XCTUnwrap(context.makeImage())
        let block = Paragraphs.Block(text: "x", rect: CGRect(x: 20, y: 20, width: 960, height: 280), lineHeight: 56,
                                     lines: 0..<1)
        let translation = "Polar ו-Lemon Squeezy פועלים כשווקים מוכרים, ולכן הם מטפלים במסים על מכירות גלובליים עבורכם."
        let rendering = try XCTUnwrap(TranslationRenderer(capture: capture, original: .empty, blocks: [block],
                                                          rightToLeft: true).render([translation]))
        let bounds = block.rect.insetBy(dx: -2, dy: -2)
        for word in rendering.text.words {
            XCTAssertTrue(bounds.contains(word.rect), "\(word.text) at \(word.rect)")
        }
    }

    /// The rendered translation is picked from like recognised text: selecting all of
    /// it copies each paragraph whole, one per line, punctuation included.
    func testRenderedTranslationCopiesBackWhole() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        let capture = try XCTUnwrap(context.makeImage())
        let blocks = [
            Paragraphs.Block(text: "One", rect: CGRect(x: 10, y: 10, width: 500, height: 60), lineHeight: 28, lines: 0..<1),
            Paragraphs.Block(text: "Two", rect: CGRect(x: 10, y: 100, width: 500, height: 30), lineHeight: 28, lines: 1..<2),
        ]
        let translations = ["The first paragraph, which is long enough to wrap onto a second line.", "Second!"]

        let rendering = try XCTUnwrap(TranslationRenderer(capture: capture, original: .empty, blocks: blocks,
                                                          rightToLeft: false).render(translations))
        XCTAssertEqual(rendering.image.width, capture.width)
        XCTAssertEqual(rendering.text.text(ofWords: rendering.text.words.indices), translations.joined(separator: "\n"))
        // Words sit where their paragraph was painted.
        for word in rendering.text.words {
            let block = blocks[word.lineIndex].rect.insetBy(dx: -2, dy: -2)
            XCTAssertTrue(block.contains(CGPoint(x: word.rect.midX, y: word.rect.midY)), "\(word.text) at \(word.rect)")
        }
    }

    /// Apple translates a paragraph at a time. One it hasn't reached yet stays as it
    /// was on screen, and its original words can still be picked.
    func testUntranslatedParagraphKeepsItsOriginalWords() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = try XCTUnwrap(context.makeImage())
        let original = RecognizedText(
            words: [
                RecognizedWord(text: "Bonjour", rect: CGRect(x: 10, y: 10, width: 80, height: 20), lineIndex: 0),
                RecognizedWord(text: "Merci", rect: CGRect(x: 10, y: 100, width: 60, height: 20), lineIndex: 1),
                RecognizedWord(text: "beaucoup", rect: CGRect(x: 80, y: 100, width: 90, height: 20), lineIndex: 1),
            ],
            lines: [
                RecognizedLine(text: "Bonjour", rect: CGRect(x: 10, y: 10, width: 80, height: 20), wordRange: 0..<1),
                RecognizedLine(text: "Merci beaucoup", rect: CGRect(x: 10, y: 100, width: 160, height: 20), wordRange: 1..<3),
            ])
        let blocks = Paragraphs.blocks(original)
        let rendering = try XCTUnwrap(TranslationRenderer(capture: capture, original: original, blocks: blocks,
                                                          rightToLeft: false).render(["Hello", nil]))
        XCTAssertEqual(rendering.text.lines.map(\.text), ["Hello", "Merci beaucoup"])
        XCTAssertEqual(rendering.text.text(ofWords: rendering.text.lines[1].wordRange), "Merci beaucoup")
        XCTAssertEqual(rendering.text.words.last?.rect, original.words.last?.rect)
    }

    /// The same renderer paints every update to a capture. When Apple's version of a
    /// paragraph replaces the offline draft, the paint and the words are Apple's, while
    /// a paragraph still to come stays original; then it arrives too.
    func testRepaintShowsReplacedAndNewlyArrivedParagraphs() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = try XCTUnwrap(context.makeImage())
        let blocks = [
            Paragraphs.Block(text: "Bonjour", rect: CGRect(x: 10, y: 10, width: 500, height: 40), lineHeight: 40, lines: 0..<1),
            Paragraphs.Block(text: "Merci", rect: CGRect(x: 10, y: 100, width: 500, height: 40), lineHeight: 40, lines: 1..<2),
        ]
        let renderer = TranslationRenderer(capture: capture, original: .empty, blocks: blocks, rightToLeft: false)

        let draft = try XCTUnwrap(renderer.render(["Hallo daar", nil]))
        let replaced = try XCTUnwrap(renderer.render(["Good morning", nil]))
        XCTAssertEqual(replaced.text.lines.map(\.text), ["Good morning", "Merci"])
        XCTAssertEqual(replaced.text.text(ofWords: replaced.text.lines[0].wordRange), "Good morning")
        XCTAssertNotEqual(try pixels(draft.image, in: blocks[0].rect), try pixels(replaced.image, in: blocks[0].rect))

        let complete = try XCTUnwrap(renderer.render(["Good morning", "Thank you"]))
        XCTAssertEqual(complete.text.lines.map(\.text), ["Good morning", "Thank you"])
        XCTAssertEqual(try pixels(replaced.image, in: blocks[0].rect), try pixels(complete.image, in: blocks[0].rect))
    }

    /// Paragraphs that sit directly on top of each other, as lines of a page do: the
    /// lower one's background must not be painted over the upper one's descenders.
    func testNextParagraphDoesNotCoverTheOneAbove() throws {
        let capture = try solid(width: 600, height: 120, gray: 0.12)
        let upper = Paragraphs.Block(text: "a", rect: CGRect(x: 10, y: 10, width: 560, height: 30), lineHeight: 30,
                                     lines: 0..<1)
        let lower = Paragraphs.Block(text: "b", rect: CGRect(x: 10, y: 40, width: 560, height: 30), lineHeight: 30,
                                     lines: 1..<2)
        let text = "gypsy jugs quietly gyp ping"

        let alone = try XCTUnwrap(TranslationRenderer(capture: capture, original: .empty, blocks: [upper],
                                                      rightToLeft: false).render([text]))
        let stacked = try XCTUnwrap(TranslationRenderer(capture: capture, original: .empty, blocks: [upper, lower],
                                                        rightToLeft: false).render([text, "x"]))
        let area = upper.rect.intersection(CGRect(x: 0, y: 0, width: 600, height: lower.rect.minY))
        XCTAssertEqual(try pixels(alone.image, in: area), try pixels(stacked.image, in: area))
    }

    /// A long line of thin light text on a dark page: its ink is the text's colour,
    /// not the grey its anti-aliased edges average out to when the crop is shrunk.
    func testLightInkOnDarkPageIsSampledAsLight() throws {
        let width = 1200, height = 40
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Bonjour tout le monde, comment allez-vous aujourd'hui? Le chat dort.",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                         .foregroundColor: NSColor.white]))
        context.textPosition = CGPoint(x: 4, y: 12)
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())

        let all = CGRect(x: 0, y: 0, width: width, height: height)
        let ink = try XCTUnwrap(ColorSampler.colors(in: XCTUnwrap(Bitmap(image, rect: all)), rect: all)
            .ink.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(ink.redComponent, 0.85, "ink \(ink)")
    }

    /// The patch over the original is the page's own colour to the level: the
    /// anti-aliased edges of the text on it don't tint it, so no box shows around a
    /// translation.
    func testBackgroundIsThePageColourExactly() throws {
        let dark = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
        for (page, ink) in [(NSColor.white, NSColor.black), (dark, NSColor(white: 0.93, alpha: 1))] {
            let (capture, original) = try typeset([Line(text: "The quick brown fox jumps over the lazy dog", x: 20,
                                                        baseline: 50)], width: 900, height: 80, page: page, ink: ink)
            let line = original.lines[0].rect
            let sampled = try XCTUnwrap(ColorSampler.colors(in: XCTUnwrap(Bitmap(capture, rect: line)), rect: line)
                .background.usingColorSpace(.sRGB))
            let expected = try XCTUnwrap(page.usingColorSpace(.sRGB))
            XCTAssertEqual(sampled.redComponent, expected.redComponent, accuracy: 0.5 / 255, "\(sampled)")
            XCTAssertEqual(sampled.greenComponent, expected.greenComponent, accuracy: 0.5 / 255, "\(sampled)")
            XCTAssertEqual(sampled.blueComponent, expected.blueComponent, accuracy: 0.5 / 255, "\(sampled)")
        }
    }

    /// Menu items OCR boxes at different heights — "View" has no descender, "Help"
    /// has — are one size of type, so their translations come out one size too, the
    /// size they were, however long each is.
    func testMenuItemsKeepTheirOneSize() throws {
        let lines = Self.menu.enumerated().map { Line(text: $1, x: 60, baseline: 60 + CGFloat($0) * 56) }
        let (capture, original) = try typeset(lines, width: 900, height: 520)
        // A made-up language in capitals of one height: each line's ink is its type's cap height.
        let translations = ["FILE", "LIFT THE LINE", "TEN", "THE NET", "HELL", "LET IT", "THE FILE THEN IN", "FINE LINE"]
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: false).render(translations))
        let heights = try lines.map { try inkBounds(rendering.image, in: row($0, width: 900)).height }
        // San Francisco's capitals are 0.7 of its size: 21 pixels at 30.
        for height in heights {
            XCTAssertEqual(height, 21, accuracy: 2, "\(heights)")
        }
        XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, 1, "\(heights)")
    }

    /// A heading whose translation is longer than the heading was still comes out
    /// larger than the body text under it.
    func testHeadingStaysLargerThanItsBody() throws {
        let lines = [
            Line(text: "Getting started", x: 40, baseline: 60, font: .boldSystemFont(ofSize: 42)),
            Line(text: "The quick setup takes about five minutes and walks you", x: 40, baseline: 120),
            Line(text: "through connecting your account and choosing folders.", x: 40, baseline: 158),
        ]
        let (capture, original) = try typeset(lines, width: 900, height: 200)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<3]),
            rightToLeft: false).render(["THE FILE THEN THE LINE IN THE FIELD", "THE FILE THE FILE THE FILE THE FILE"]))
        let heading = try firstLineHeight(rendering.image, in: CGRect(x: 0, y: 10, width: 900, height: 64))
        let body = try firstLineHeight(rendering.image, in: CGRect(x: 0, y: 90, width: 900, height: 40))
        XCTAssertGreaterThan(heading, body)
    }

    /// Bold type comes out bold: of two lines of one size, the bold one's translation
    /// is the heavier.
    func testBoldTypeStaysBold() throws {
        let lines = [Line(text: "Account settings", x: 40, baseline: 60, font: .boldSystemFont(ofSize: 30)),
                     Line(text: "Change your password", x: 40, baseline: 120)]
        let (capture, original) = try typeset(lines, width: 600, height: 160)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<2]),
            rightToLeft: false).render(["THE FILE", "THE FILE"]))
        let bold = try inkBounds(rendering.image, in: row(lines[0], width: 600))
        let regular = try inkBounds(rendering.image, in: row(lines[1], width: 600))
        XCTAssertGreaterThan(try coverage(rendering.image, in: bold), try coverage(rendering.image, in: regular) * 1.25)
    }

    /// A left-aligned menu translated into Hebrew reads from one right edge, not from
    /// wherever each English item happened to end.
    func testRightToLeftMenuSharesOneEdge() throws {
        let lines = Self.menu.enumerated().map { Line(text: $1, x: 60, baseline: 60 + CGFloat($0) * 56) }
        let (capture, original) = try typeset(lines, width: 900, height: 520)
        let translations = ["קובץ", "עריכה", "תצוגה", "חלון", "עזרה", "שמירה", "פתיחת קבצים אחרונים", "הגדרות…"]
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: true).render(translations))
        let edges = try lines.map { try inkBounds(rendering.image, in: row($0, width: 900)).maxX }
        XCTAssertLessThanOrEqual(edges.max()! - edges.min()!, 3, "\(edges)")
    }

    /// Japanese in a dark box, a lighter box's border crossing the line and running up
    /// past it, as boxes overlap on a real page: the border isn't taken for the letters,
    /// and the translation comes out the size the Japanese was, not several times it.
    func testBorderCrossingCJKLineDoesNotInflateItsSize() throws {
        let font = try XCTUnwrap(NSFont(name: "HiraginoSans-W3", size: 32))
        let line = Line(text: "ご注文の商品は本日発送いたしました。", x: 40, baseline: 100, font: font)
        let border = (rect: CGRect(x: 420, y: 10, width: 2, height: 100), color: NSColor(white: 0.87, alpha: 1))
        let dark = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
        let (capture, original) = try typeset([line], width: 900, height: 180, page: dark, shapes: [border],
                                              ink: NSColor(white: 0.93, alpha: 1))
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THE FILE"]))
        // Capitals 0.7 of the size: 22 pixels at 32.
        let rows = CGRect(x: 0, y: 40, width: 400, height: 80)
        XCTAssertEqual(try firstLineHeight(rendering.image, in: rows, on: dark), 22, accuracy: 3)
    }

    /// A button's label translated longer than the button: the button's colour is never
    /// painted onto the card around it, and the card stays as it was.
    func testButtonPatchStaysInsideTheButton() throws {
        let button = CGRect(x: 100, y: 60, width: 220, height: 56)
        let blue = NSColor(srgbRed: 11 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)
        let label = Line(text: "Enregistrer", x: button.midX, baseline: 98, centred: true, ink: .white)
        let (capture, original) = try typeset([label], width: 900, height: 200, shapes: [(button, blue)])
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THE LITTLE FELT HEN IN THE FIELD THEN LIFTED THE FINE LINEN"]))
        let card = CGRect(x: button.maxX + 2, y: 0, width: 900 - button.maxX - 2, height: 200)
        XCTAssertEqual(try pixels(rendering.image, in: card), try pixels(capture, in: card))
    }

    /// A button's label translated into Hebrew sits in the middle of its button.
    func testButtonLabelIsCentredInItsButton() throws {
        let button = CGRect(x: 100, y: 60, width: 220, height: 56)
        let blue = NSColor(srgbRed: 11 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)
        let label = Line(text: "Enregistrer", x: button.midX, baseline: 98, centred: true, ink: .white)
        let (capture, original) = try typeset([label], width: 900, height: 200, shapes: [(button, blue)])
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: true).render(["שמור"]))
        let ink = try inkBounds(rendering.image, in: button.insetBy(dx: 4, dy: 4), on: blue)
        XCTAssertEqual(ink.midX, button.midX, accuracy: 4)
    }

    /// English into Hebrew: a heading and its paragraph read from one right edge, the
    /// paragraph's own, though a box beside the heading leaves the heading little room.
    func testHeadingAndParagraphShareTheColumnsRightEdge() throws {
        let lines = [
            Line(text: "Account settings", x: 60, baseline: 70, font: .boldSystemFont(ofSize: 40)),
            Line(text: "Your subscription renews automatically on March 3. You", x: 60, baseline: 140),
            Line(text: "can cancel it at any time.", x: 60, baseline: 180),
            Line(text: "Hello there", x: 1050, baseline: 70),
        ]
        let (capture, original) = try typeset(lines, width: 1300, height: 220)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<3, 3..<4]),
            rightToLeft: true).render(["פרטי החשבון", "המנוי שלך מתחדש אוטומטית ב-3 במרץ. אפשר לבטל אותו בכל עת.", nil]))
        let edge = original.lines[1].rect.maxX
        let heading = try inkBounds(rendering.image, in: CGRect(x: 0, y: 20, width: 1000, height: 64))
        let paragraph = try inkBounds(rendering.image, in: CGRect(x: 0, y: 105, width: 1000, height: 50))
        XCTAssertEqual(heading.maxX, edge, accuracy: 6)
        XCTAssertEqual(paragraph.maxX, edge, accuracy: 6)
    }

    /// Text on a picture — a subtitle on video — has no plain page beside it: its longer
    /// translation runs on over the picture at full size rather than shrinking.
    func testTranslationOnAPictureRunsOnOverIt() throws {
        let line = Line(text: "Edit", x: 60, baseline: 60)
        let picture = [NSColor(srgbRed: 200 / 255, green: 225 / 255, blue: 250 / 255, alpha: 1),
                       NSColor(srgbRed: 250 / 255, green: 215 / 255, blue: 190 / 255, alpha: 1)]
        let (capture, original) = try typeset([line], width: 1200, height: 100, picture: picture)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THE LITTLE FELT HEN IN THE FIELD"]))
        XCTAssertEqual(try firstLineHeight(rendering.image, in: row(line, width: 1200)), 21, accuracy: 2)
    }

    /// A Hebrew menu set against the left edge, items short and long: in English it
    /// keeps that edge, though neighbouring items about as wide share every edge.
    func testLeftAlignedRightToLeftMenuKeepsItsEdge() throws {
        let items = ["קובץ", "עריכה", "תצוגה", "חלון", "עזרה", "שמירה", "פתיחת קבצים אחרונים", "הגדרות…"]
        let lines = items.enumerated().map { Line(text: $1, x: 60, baseline: 60 + CGFloat($0) * 56) }
        let (capture, original) = try typeset(lines, width: 900, height: 520)
        let translations = ["FILE", "EDIT", "VIEW", "WINDOW", "HELP", "SAVE", "OPEN RECENT FILES", "SETTINGS"]
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: false).render(translations))
        let edges = try lines.map { try inkBounds(rendering.image, in: row($0, width: 900)).minX }
        XCTAssertLessThanOrEqual(edges.max()! - edges.min()!, 3, "\(edges)")
    }

    /// Labels side by side in a row, the first translated far longer than it: rather than
    /// being cut short, it runs on along the row and the labels after it move on to make
    /// room — each on one line, in order, none over another, at a size easy to read.
    func testRowOfLabelsFlowsAlongTheRow() throws {
        let lines = ["Ab", "Cd", "Ef", "Gh"].enumerated().map { Line(text: $1, x: 40 + CGFloat($0) * 80, baseline: 50) }
        let (capture, original) = try typeset(lines, width: 1000, height: 100)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: false).render(["THE LITTLE FILE", "HEN", "LINE", "FELT"]))
        let words = rendering.text.words
        XCTAssertEqual(words.map(\.text), ["THE", "LITTLE", "FILE", "HEN", "LINE", "FELT"])
        for (word, next) in zip(words, words.dropFirst()) {
            XCTAssertLessThan(word.rect.maxX, next.rect.minX, "\(word.text) runs into \(next.text)")
            XCTAssertEqual(word.rect.midY, next.rect.midY, accuracy: 2, "\(word.text) and \(next.text)")
        }
        XCTAssertGreaterThanOrEqual(try firstLineHeight(rendering.image, in: CGRect(x: 0, y: 0, width: 1000, height: 70)),
                                    21 * TranslationRenderer.smallest - 1)
    }

    /// Kanji and kana are dense with strokes: at a menu's size they run together, and some
    /// items measure as heavy as bold Latin type. None of them is taken for bold.
    func testDenseScriptMenuIsNotTakenForBold() throws {
        let items = ["ファイル", "編集", "表示", "ウインドウ", "ヘルプ", "設定", "保存"]
        let lines = items.enumerated().map { Line(text: $1, x: 60, baseline: 60 + CGFloat($0) * 56) }
        let (capture, original) = try typeset(lines, width: 600, height: 440)
        let page = Page(capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }))
        XCTAssertEqual(page.paragraphs.map(\.weight), Array(repeating: NSFont.Weight.regular, count: items.count))
    }

    /// A paragraph measured larger than the bold heading over it is set no larger than the
    /// heading: body text never is.
    func testParagraphIsNeverLargerThanItsHeading() throws {
        let lines = [
            Line(text: "Account", x: 40, baseline: 60, font: .boldSystemFont(ofSize: 30)),
            Line(text: "Your subscription renews on March 3.", x: 40, baseline: 120, font: .systemFont(ofSize: 36)),
            Line(text: "You can cancel it at any time.", x: 40, baseline: 165, font: .systemFont(ofSize: 36)),
        ]
        let (capture, original) = try typeset(lines, width: 900, height: 200)
        let page = Page(capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<3]))
        XCTAssertLessThanOrEqual(page.paragraphs[1].size, page.paragraphs[0].size)
    }

    /// Labels side by side in a bordered bar — a toolbar, a menu bar — aren't buttons,
    /// though each sits between its neighbours: their translations start where they did.
    func testLabelsInABarKeepTheirEdge() throws {
        let border = NSColor(white: 0.87, alpha: 1)
        let bar = [CGRect(x: 20, y: 20, width: 760, height: 2), CGRect(x: 20, y: 98, width: 760, height: 2),
                   CGRect(x: 20, y: 20, width: 2, height: 80), CGRect(x: 778, y: 20, width: 2, height: 80)]
        let lines = ["Fichier", "Édition", "Affichage", "Réglages"].enumerated().map {
            Line(text: $1, x: 50 + CGFloat($0) * 170, baseline: 70)
        }
        let (capture, original) = try typeset(lines, width: 800, height: 120, shapes: bar.map { ($0, border) })
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: false).render(["File", "Edit", "View", "Settings"]))
        for (line, box) in zip(lines, original.lines.map(\.rect)) {
            let ink = try inkBounds(rendering.image, in: CGRect(x: line.x - 30, y: 30, width: 160, height: 60))
            XCTAssertEqual(ink.minX, box.minX, accuracy: 4, line.text)
        }
    }

    /// English into Hebrew, a short heading over a wide paragraph: the heading reaches
    /// the paragraph's right edge, however much further that is than the heading went.
    func testShortHeadingReachesItsParagraphsRightEdge() throws {
        let lines = [
            Line(text: "Settings", x: 60, baseline: 70, font: .boldSystemFont(ofSize: 40)),
            Line(text: "Your subscription renews automatically on March 3 and you can cancel it at any", x: 60,
                 baseline: 140),
            Line(text: "time from the billing page.", x: 60, baseline: 180),
        ]
        let (capture, original) = try typeset(lines, width: 1600, height: 220)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<3]),
            rightToLeft: true).render(["הגדרות", "המנוי שלך מתחדש אוטומטית ב-3 במרץ, ואפשר לבטל אותו בכל עת מדף החיוב."]))
        let heading = try inkBounds(rendering.image, in: CGRect(x: 0, y: 20, width: 1600, height: 64))
        XCTAssertEqual(heading.maxX, original.lines[1].rect.maxX, accuracy: 6)
    }

    /// A menu bar's items, side by side and close together, into Hebrew: each translation
    /// stays at its item, the longest too — none is sent off to the far end of the bar.
    func testMenuBarItemsStayInPlaceInHebrew() throws {
        let lines = ["File", "Edit", "View", "Help"].enumerated().map {
            Line(text: $1, x: 40 + CGFloat($0) * 90, baseline: 50)
        }
        let (capture, original) = try typeset(lines, width: 1200, height: 100)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: true).render(["קובץ", "עריכה", "תצוגה", "עזרה ותמיכה"]))
        let ink = try inkBounds(rendering.image, in: CGRect(x: 0, y: 0, width: 1200, height: 100))
        XCTAssertLessThan(ink.maxX, original.lines[3].rect.maxX + 160)
    }

    /// A Hebrew line at the left of the page, into longer English: it takes the empty page
    /// to its right too, staying one line at its size.
    func testRightToLeftLineIntoEnglishUsesTheRoomOnItsOtherSide() throws {
        let line = Line(text: "ברוכים הבאים לאפליקציה", x: 40, baseline: 60)
        let (capture, original) = try typeset([line], width: 1200, height: 160)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THE LITTLE FELT HEN IN THE FIELD THEN LIFTED"]))
        XCTAssertEqual(Set(rendering.text.words.map { Int($0.rect.minY) }).count, 1, "\(rendering.text.words)")
        XCTAssertEqual(try firstLineHeight(rendering.image, in: row(line, width: 1200)), 21, accuracy: 2)
    }

    /// Vision's box for a paragraph's last line at times takes in the bottom of the line
    /// above. The paragraph is still measured at the size its type is, and translated
    /// at that size, not the oversized box's.
    func testLineBoxReachingIntoTheLineAboveDoesNotInflateTheSize() throws {
        let lines = [Line(text: "The quick brown fox jumps over the lazy dog, quietly", x: 40, baseline: 60),
                     Line(text: "and goes home.", x: 40, baseline: 96)]
        let (capture, read) = try typeset(lines, width: 900, height: 160)
        let upper = read.lines[0], lower = read.lines[1]
        let top = upper.rect.maxY - upper.rect.height * 0.35
        let tall = RecognizedLine(text: lower.text, rect: CGRect(x: lower.rect.minX, y: top, width: lower.rect.width,
                                                                 height: lower.rect.maxY - top),
                                  wordRange: lower.wordRange)
        let original = RecognizedText(words: read.words, lines: [upper, tall])
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<2]),
            rightToLeft: false).render(["THE FILE THEN THE LINE IN THE FIELD"]))
        // Capitals 0.7 of the size: 21 pixels at 30.
        XCTAssertEqual(try firstLineHeight(rendering.image, in: CGRect(x: 0, y: 20, width: 900, height: 50)), 21,
                       accuracy: 2)
    }

    /// The one descender of a long line is the line's ink as much as its letters are: the
    /// patch covers it, and none of it shows under a shorter translation.
    func testLoneDescenderOfALongLineIsCovered() throws {
        let line = Line(text: "Il fait tres beau aujourd'hui dans la ville et le soleil brille", x: 40, baseline: 60)
        let (capture, original) = try typeset([line], width: 1000, height: 120)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THE FILE"]))
        let below = CGRect(x: 0, y: line.baseline + 1, width: 1000, height: 12)
        XCTAssertTrue(try pixels(rendering.image, in: below).allSatisfy { $0 == 255 })
    }

    /// A line's closing full stop is part of its ink, though it sits on the baseline below
    /// the middle of the letters: the patch covers it, and none of it shows past a shorter
    /// translation.
    func testClosingFullStopIsCovered() throws {
        let line = Line(text: "Merci a tous et a bientot.", x: 40, baseline: 60)
        let (capture, original) = try typeset([line], width: 900, height: 120)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THANKS"]))
        let box = original.lines[0].rect
        let end = CGRect(x: box.maxX - 12, y: box.minY, width: 16, height: box.height).integral
        XCTAssertTrue(try pixels(rendering.image, in: end).allSatisfy { $0 == 255 })
    }

    /// A word too long for all the room a label has is cut short with an ellipsis, not
    /// broken across lines — and copying it still gives the whole word.
    func testWordTooWideForItsRoomIsCutShortNotBroken() throws {
        let lines = [Line(text: "Cut", x: 40, baseline: 50), Line(text: "Copy", x: 120, baseline: 50)]
        let (capture, original) = try typeset(lines, width: 600, height: 200)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<2]),
            rightToLeft: false).render(["SETTINGS", nil]))
        XCTAssertEqual(rendering.text.text(ofWords: rendering.text.lines[0].wordRange), "SETTINGS")
        let under = CGRect(x: 0, y: lines[0].baseline + 10, width: 115, height: 100)
        XCTAssertTrue(try pixels(rendering.image, in: under).allSatisfy { $0 == 255 })
    }

    /// Centred lines stay centred, whichever way the translation runs.
    func testCentredLinesStayCentred() throws {
        let lines = [
            Line(text: "Welcome back", x: 450, baseline: 60, font: .boldSystemFont(ofSize: 40), centred: true),
            Line(text: "Sign in to continue to your workspace.", x: 450, baseline: 120, centred: true),
            Line(text: "Forgot password?", x: 450, baseline: 176, centred: true),
        ]
        let (capture, original) = try typeset(lines, width: 900, height: 220)
        let translations = ["ברוכים הבאים", "היכנסו כדי להמשיך לסביבת העבודה שלכם.", "שכחתם את הסיסמה?"]
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<2, 2..<3]),
            rightToLeft: true).render(translations))
        for line in lines {
            XCTAssertEqual(try inkBounds(rendering.image, in: row(line, width: 900)).midX, 450, accuracy: 3, line.text)
        }
    }

    /// A label whose translation is longer than it, with empty page beside it: the
    /// translation keeps the label's size and runs on from where the label started.
    func testLongerTranslationGrowsIntoFreeSpaceInsteadOfShrinking() throws {
        let line = Line(text: "Edit", x: 60, baseline: 60)
        let (capture, original) = try typeset([line], width: 1200, height: 100)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1]),
            rightToLeft: false).render(["THE LITTLE FELT HEN IN THE FIELD"]))
        let ink = try inkBounds(rendering.image, in: row(line, width: 1200))
        XCTAssertEqual(ink.height, 21, accuracy: 2)
        XCTAssertEqual(ink.minX, 60, accuracy: 4)
        XCTAssertGreaterThan(ink.maxX, original.lines[0].rect.maxX + 200)
    }

    /// A translation only grows into empty page: the label beside it, still
    /// untranslated, is left exactly as it was, and the translation stays legible.
    func testGrowingTranslationLeavesItsNeighbourAlone() throws {
        let lines = [Line(text: "Edit", x: 60, baseline: 60), Line(text: "Delete", x: 330, baseline: 60)]
        let (capture, original) = try typeset(lines, width: 900, height: 300)
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, [0..<1, 1..<2]),
            rightToLeft: false).render(["THE LITTLE FELT HEN IN THE FIELD", nil]))
        let beside = CGRect(x: 320, y: 0, width: 580, height: 300)
        XCTAssertEqual(try pixels(rendering.image, in: beside), try pixels(capture, in: beside))
        let first = try firstLineHeight(rendering.image, in: CGRect(x: 0, y: 22, width: 320, height: 50))
        XCTAssertGreaterThanOrEqual(first, 21 * 0.75)
    }

    /// Hemmed in on every side, a long translation is cut short with an ellipsis
    /// rather than shrunk past reading — and copying it still gives all of it.
    func testCrampedTranslationIsCutShortNotShrunkPastReading() throws {
        let grid = [["Cut", "Copy", "Paste"], ["Undo", "Edit", "Redo"], ["Find", "Replace", "Select"]]
        let lines = grid.enumerated().flatMap { row, labels in
            labels.enumerated().map { column, label in
                Line(text: label, x: 40 + CGFloat(column) * 170, baseline: 50 + CGFloat(row) * 42)
            }
        }
        let (capture, original) = try typeset(lines, width: 560, height: 160)
        let long = "THE LITTLE FELT HEN IN THE FIELD THEN LIFTED THE FINE LINEN"
        var translations = [String?](repeating: nil, count: lines.count)
        translations[4] = long
        let rendering = try XCTUnwrap(TranslationRenderer(
            capture: capture, original: original, blocks: blocks(original, lines.indices.map { $0..<$0 + 1 }),
            rightToLeft: false).render(translations))

        XCTAssertEqual(rendering.text.text(ofWords: rendering.text.lines[4].wordRange), long)
        let first = try firstLineHeight(rendering.image, in: CGRect(x: 150, y: 62, width: 180, height: 34))
        XCTAssertGreaterThanOrEqual(first, 21 * 0.75)
        for (index, line) in original.lines.enumerated() where index != 4 {
            let neighbour = line.rect.insetBy(dx: -2, dy: -2).integral
            XCTAssertEqual(try pixels(rendering.image, in: neighbour), try pixels(capture, in: neighbour), line.text)
        }
    }

    // MARK: Type on a page

    private static let menu = ["File", "Edit", "View", "Window", "Help", "Save", "Open Recent", "Settings…"]

    /// A line of type: where it starts — or its middle, `centred` — and its baseline,
    /// in pixels from the top left.
    private struct Line {
        let text: String
        let x: CGFloat
        let baseline: CGFloat
        var font = NSFont.systemFont(ofSize: 30)
        var centred = false
        /// Its own colour, where it isn't the page's ink: a button's label.
        var ink: NSColor?
    }

    /// `lines` set on a page — or on a picture, stripes of `picture`'s colours — over
    /// `shapes` (top-left rects: buttons, borders), and what OCR makes of them: each line's
    /// box hugs its glyphs, as Vision's do, so "View" gets a shorter box than "Help" and
    /// neither box is the size of the type.
    private func typeset(_ lines: [Line], width: Int, height: Int, page: NSColor = .white, picture: [NSColor] = [],
                         shapes: [(rect: CGRect, color: NSColor)] = [],
                         ink: NSColor = .black) throws -> (image: CGImage, text: RecognizedText) {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(page.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (stripe, x) in stride(from: 0, to: width, by: 4).enumerated() where !picture.isEmpty {
            context.setFillColor(picture[stripe % picture.count].cgColor)
            context.fill(CGRect(x: x, y: 0, width: 4, height: height))
        }
        for shape in shapes {
            context.setFillColor(shape.color.cgColor)
            context.fill(CGRect(x: shape.rect.minX, y: CGFloat(height) - shape.rect.maxY, width: shape.rect.width,
                                height: shape.rect.height))
        }
        var words: [RecognizedWord] = []
        var recognized: [RecognizedLine] = []
        for line in lines {
            let typeset = CTLineCreateWithAttributedString(NSAttributedString(
                string: line.text, attributes: [.font: line.font, .foregroundColor: line.ink ?? ink]))
            let glyphs = CTLineGetImageBounds(typeset, nil)
            let start = line.centred ? line.x - glyphs.midX : line.x
            context.textPosition = CGPoint(x: start, y: CGFloat(height) - line.baseline)
            CTLineDraw(typeset, context)
            let box = CGRect(x: start + glyphs.minX, y: line.baseline - glyphs.maxY,
                             width: glyphs.width, height: glyphs.height)
            let string = line.text as NSString
            let first = words.count
            var location = 0
            for word in line.text.split(separator: " ") {
                let range = string.range(of: String(word), range: NSRange(location: location,
                                                                          length: string.length - location))
                location = range.upperBound
                let from = CTLineGetOffsetForStringIndex(typeset, range.location, nil)
                let to = CTLineGetOffsetForStringIndex(typeset, range.upperBound, nil)
                words.append(RecognizedWord(text: String(word), rect: CGRect(x: start + min(from, to), y: box.minY,
                                                                             width: abs(to - from), height: box.height),
                                            lineIndex: recognized.count))
            }
            recognized.append(RecognizedLine(text: line.text, rect: box, wordRange: first..<words.count))
        }
        return (try XCTUnwrap(context.makeImage()), RecognizedText(words: words, lines: recognized))
    }

    /// Paragraphs of the lines in each of `groups`, as `Paragraphs.blocks` builds them.
    private func blocks(_ text: RecognizedText, _ groups: [Range<Int>]) -> [Paragraphs.Block] {
        groups.map { group in
            let lines = text.lines[group]
            return Paragraphs.Block(text: lines.map(\.text).joined(separator: " "),
                                    rect: lines.dropFirst().reduce(lines[group.lowerBound].rect) { $0.union($1.rect) },
                                    lineHeight: lines.map(\.rect.height).max() ?? 0, lines: group)
        }
    }

    /// The band a line of type sits in, across the page: from well above its capitals
    /// to below its descenders.
    private func row(_ line: Line, width: Int) -> CGRect {
        CGRect(x: 0, y: line.baseline - 38, width: CGFloat(width), height: 50)
    }

    /// The bounds of what is painted in `rect` that isn't the page.
    private func inkBounds(_ image: CGImage, in rect: CGRect, on page: NSColor = .white) throws -> CGRect {
        let bytes = try pixels(image, in: rect)
        let width = Int(rect.width)
        var bounds = CGRect.null
        for pixel in 0..<bytes.count / 4 where Self.distance(bytes, pixel, from: page) > 150 {
            bounds = bounds.union(CGRect(x: rect.minX + CGFloat(pixel % width), y: rect.minY + CGFloat(pixel / width),
                                         width: 1, height: 1))
        }
        return try XCTUnwrap(bounds.isNull ? nil : bounds, "nothing painted in \(rect)")
    }

    /// How tall the first line painted in `rect` stands: its run of inked rows from the
    /// top, which for capitals is the type's cap height.
    private func firstLineHeight(_ image: CGImage, in rect: CGRect, on page: NSColor = .white) throws -> CGFloat {
        let bytes = try pixels(image, in: rect)
        let width = Int(rect.width)
        let inked = (0..<Int(rect.height)).map { row in
            (0..<width).contains { Self.distance(bytes, row * width + $0, from: page) > 150 }
        }
        let top = try XCTUnwrap(inked.firstIndex(of: true), "nothing painted in \(rect)")
        return CGFloat((inked[top...].firstIndex(of: false) ?? inked.count) - top)
    }

    /// The share of `rect` that is solid ink: heavier type covers more of its bounds.
    private func coverage(_ image: CGImage, in rect: CGRect) throws -> Double {
        let bytes = try pixels(image, in: rect)
        let solid = (0..<bytes.count / 4).filter { Self.distance(bytes, $0, from: .white) > 382 }.count
        return Double(solid) / Double(bytes.count / 4)
    }

    /// How far a pixel of RGBA `bytes` is from `page`, summed over its channels.
    private static func distance(_ bytes: [UInt8], _ pixel: Int, from page: NSColor) -> Int {
        let page = page.usingColorSpace(.sRGB) ?? page
        return abs(Int(bytes[pixel * 4]) - Int((page.redComponent * 255).rounded()))
            + abs(Int(bytes[pixel * 4 + 1]) - Int((page.greenComponent * 255).rounded()))
            + abs(Int(bytes[pixel * 4 + 2]) - Int((page.blueComponent * 255).rounded()))
    }

    private func solid(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// RGBA bytes of `rect` (top-left origin) in `image`.
    private func pixels(_ image: CGImage, in rect: CGRect) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                                                  bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return bytes
    }
}
