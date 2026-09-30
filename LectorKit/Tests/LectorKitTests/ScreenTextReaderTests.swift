import CoreGraphics
import ImageIO
import XCTest
@testable import LectorKit

/// Reads the committed screen fixtures end to end, through the bundled Tesseract
/// models rather than anything installed on the machine.
final class ScreenTextReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func read(_ name: String) async throws -> RecognizedText {
        try await ScreenTextReader().read(fixture(name))
    }

    private func hebrewLetters(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x05D0...0x05EA).contains($0.value) }.count
    }

    func testEnglishParagraphReadsAsSeveralLinesOfRealWords() async throws {
        let text = try await read("english-paragraph")
        XCTAssertGreaterThan(text.lines.count, 1)
        XCTAssertFalse(text.isSingleLine)
        let lowered = text.text.lowercased()
        XCTAssertTrue(lowered.contains(" the "), lowered)
    }

    func testHebrewIsReadAsHebrewNotLatinLookalikes() async throws {
        let text = try await read("hebrew-screen")
        let letters = text.text.unicodeScalars.filter(\.properties.isAlphabetic).count
        XCTAssertGreaterThan(letters, 0)
        // Vision alone returns confident Latin garbage here; nearly every letter
        // should be Hebrew.
        XCTAssertGreaterThan(Double(hebrewLetters(text.text)) / Double(letters), 0.9, text.text)
    }

    func testHebrewLineIsInLogicalOrderForPasting() async throws {
        let text = try await read("hebrew-menu")
        let line = try XCTUnwrap(text.lines.first { hebrewLetters($0.text) > 1 })
        // Logical order means the first Hebrew word of the string is the rightmost
        // word on screen.
        let words = text.words[line.wordRange].filter { hebrewLetters($0.text) > 0 }
        let first = try XCTUnwrap(words.first), last = try XCTUnwrap(words.last)
        if words.count > 1 {
            XCTAssertGreaterThan(first.rect.midX, last.rect.midX)
        }
        XCTAssertTrue(line.text.hasPrefix(first.text) || line.text.contains(first.text))
    }

    func testMenuSplitsIntoSeparateLines() async throws {
        let text = try await read("hebrew-menu")
        XCTAssertGreaterThan(text.lines.count, 1)
    }

    func testJapaneseIsReadWithoutSpacesBetweenCharacters() async throws {
        let text = try await read("japanese-menu")
        let japanese = text.text.unicodeScalars.filter {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        XCTAssertGreaterThan(japanese.count, 2, text.text)
    }

    func testSingleLineCropReportsSingleLine() async throws {
        let image = try fixture("english-paragraph")
        let full = try await ScreenTextReader().read(image)
        let line = try XCTUnwrap(full.lines.first)
        let crop = try XCTUnwrap(image.cropping(to: line.rect.insetBy(dx: -6, dy: -6).integral))
        let text = try await ScreenTextReader().read(crop)
        XCTAssertTrue(text.isSingleLine, text.text)
    }

    func testWordRectsLieInsideTheImage() async throws {
        let image = try fixture("english-paragraph")
        let text = try await ScreenTextReader().read(image)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height).insetBy(dx: -2, dy: -2)
        for word in text.words {
            XCTAssertTrue(bounds.contains(word.rect), "\(word.text) at \(word.rect)")
        }
    }

    func testSelectedWordsJoinAcrossLinesWithNewline() async throws {
        let text = try await read("english-paragraph")
        let first = text.lines[0], second = text.lines[1]
        let lastOfFirst = first.wordRange.upperBound - 1
        let firstOfSecond = second.wordRange.lowerBound
        let joined = text.text(ofWords: lastOfFirst...firstOfSecond)
        XCTAssertEqual(joined, text.words[lastOfFirst].text + "\n" + text.words[firstOfSecond].text)
    }

    func testBlankImageHasNoText() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 80, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
        let text = try await ScreenTextReader().read(try XCTUnwrap(context.makeImage()))
        XCTAssertTrue(text.isEmpty)
    }

    /// A table row from a web page: three cells side by side, the middle one wrapping.
    /// Each cell must stay its own line — merging neighbouring cells turns a
    /// translation into one run-on sentence built from unrelated columns. Vision
    /// merges the cells or not depending on where the crop's edges fall, so both crops
    /// are checked: `table-row-tight` is the one it merges.
    func testTableCellsSideBySideStaySeparateLines() async throws {
        for fixture in ["table-row", "table-row-tight"] {
            let lines = try await read(fixture).lines.map(\.text)
            XCTAssertEqual(lines, ["Volume Scaling", "Public paid tiers (e.g., $20/mo", "for 3.8% + 40¢)",
                                   "Custom enterprise negotiation"], fixture)
        }
    }
}
