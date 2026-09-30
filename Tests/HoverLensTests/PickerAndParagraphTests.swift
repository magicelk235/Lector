import CoreGraphics
import HoverLensKit
import XCTest
@testable import HoverLens

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

    func testSentenceEndingAtFullWidthStillEnds() {
        let text = capture([
            (y: 0, x: 0, words: ["First", "sentence", "ends", "here."]),
            (y: 24, x: 0, words: ["Second", "sentence", "keeps", "going"]),
        ])
        XCTAssertEqual(Paragraphs.split(text).count, 2)
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
        XCTAssertEqual(Paragraphs.join("well-", "Known"), "well- Known")
        XCTAssertEqual(Paragraphs.join("日本語の", "文章です"), "日本語の文章です")
        XCTAssertEqual(Paragraphs.join("hello", "world"), "hello world")
    }
}
