import CoreGraphics
import Foundation

/// OCR for the scripts Apple's Vision cannot read.
///
/// Vision reads Latin, CJK and a handful of other scripts; on macOS 15 Hebrew, Greek
/// and most Indic scripts are not among them, and pointed at them it returns confident
/// nonsense rather than nothing. Tesseract, with one bundled model per script, fills
/// the gap. Script models rather than language models: the language on screen is
/// unknown, and a script model reads every language written in its script.
struct TesseractRecognizer: Sendable {
    /// Directory holding the `.traineddata` files.
    var dataPath: String

    init(dataPath: String = TesseractRecognizer.defaultDataPath) {
        self.dataPath = dataPath
    }

    /// The models bundled with the Kit, inside its resource bundle (under
    /// Contents/Resources in a macOS-style bundle). There is no fallback to a system
    /// install: what ships is what runs.
    static var defaultDataPath: String {
        (Bundle.module.url(forResource: "tessdata", withExtension: nil)
            ?? Bundle.module.bundleURL.appending(path: "tessdata")).path
    }

    func hasModel(for script: Script) -> Bool {
        guard let model = script.tesseractModel else { return false }
        return FileManager.default.fileExists(atPath: "\(dataPath)/\(model).traineddata")
    }

    func engine(for script: Script) throws -> TesseractEngine {
        guard let model = script.tesseractModel else { throw TesseractError.initialisationFailed(script.rawValue) }
        return try TesseractEngine(model: model, dataPath: dataPath)
    }

    /// `page`'s lines with words in logical order and boxes in source pixels, for a
    /// page read from the source scaled by `scale` with its top-left corner at `origin`.
    ///
    /// - Parameter rightToLeft: whether the text is in a right-to-left script. A
    ///   mixed line's direction is its text's: "Apple Watch הוא מכשיר" in Hebrew text is
    ///   a Hebrew sentence that starts with an English name.
    static func lines(from page: TesseractPage, scale: CGFloat, origin: CGPoint, rightToLeft: Bool) -> [OCRLine] {
        let lines = page.lines.map { words in
            words.compactMap { word -> (text: String, rect: CGRect, confidence: Float)? in
                let text = String(String.UnicodeScalarView(word.text.unicodeScalars.filter { !$0.isBidiControl }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let rect = CGRect(x: origin.x + word.rect.minX / scale, y: origin.y + word.rect.minY / scale,
                                  width: word.rect.width / scale, height: word.rect.height / scale)
                return (text, rect, word.confidence)
            }
        }.filter { !$0.isEmpty }

        return lines.map { words in
            let scripts = Script.histogram(of: words.map(\.text).joined())
            let lineIsRightToLeft = rightToLeftLetters(scripts) > 0
                && (rightToLeft || rightToLeftLetters(scripts) > leftToRightLetters(scripts))
            let lineRect = words.dropFirst().reduce(words[0].rect) { $0.union($1.rect) }
            let read = words.map { OCRWord(text: $0.text, rect: $0.rect, separator: " ") }
            // Left-to-right text is already in reading order, which positions can only
            // spoil: read as a block, the Bengali "আছেন?" got a box twice its width
            // and would have changed places with the next word.
            var ordered = rightToLeftLetters(scripts) == 0 ? read
                : ReadingOrder.logicalOrder(read, rightToLeft: lineIsRightToLeft)
            for index in ordered.indices {
                ordered[index].separator = index == 0 ? ""
                    : separator(between: ordered[index - 1], and: ordered[index], lineHeight: lineRect.height)
            }
            let confidence = words.map(\.confidence).reduce(0, +) / Float(words.count)
            return OCRLine(words: ordered, rect: lineRect, confidence: confidence)
        }
    }

    /// Tesseract's words are separated by spaces, except in scripts written without
    /// them, where it splits into syllables or single characters. There a space is
    /// only real if it shows as a gap.
    private static func separator(between earlier: OCRWord, and later: OCRWord, lineHeight: CGFloat) -> String {
        guard RecognizedText.separator(between: earlier.text, and: later.text).isEmpty else { return " " }
        let gap = max(later.rect.minX - earlier.rect.maxX, earlier.rect.minX - later.rect.maxX)
        return gap > lineHeight * 0.4 ? " " : ""
    }

    private static func rightToLeftLetters(_ scripts: [Script: Int]) -> Int {
        scripts.filter { $0.key.isRightToLeft }.values.reduce(0, +)
    }

    private static func leftToRightLetters(_ scripts: [Script: Int]) -> Int {
        scripts.filter { !$0.key.isRightToLeft }.values.reduce(0, +)
    }
}
