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
        let rendering = try XCTUnwrap(TranslationRenderer.render(over: capture, original: .empty, blocks: [block],
                                                                 translations: [translation], rightToLeft: true))
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

        let rendering = try XCTUnwrap(TranslationRenderer.render(over: capture, original: .empty, blocks: blocks,
                                                                 translations: translations, rightToLeft: false))
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
        let rendering = try XCTUnwrap(TranslationRenderer.render(over: capture, original: original, blocks: blocks,
                                                                 translations: ["Hello", nil], rightToLeft: false))
        XCTAssertEqual(rendering.text.lines.map(\.text), ["Hello", "Merci beaucoup"])
        XCTAssertEqual(rendering.text.text(ofWords: rendering.text.lines[1].wordRange), "Merci beaucoup")
        XCTAssertEqual(rendering.text.words.last?.rect, original.words.last?.rect)
    }
}
