import CoreGraphics
import Foundation

/// Reads all the text in an image, in whatever script it is written.
///
/// Vision reads every image first and, for Latin and CJK text, alone. When it leaves
/// text unread it takes a second look at those parts, and what it still cannot settle
/// — text it cannot read or reads in doubt — goes, area by area, to bundled Tesseract
/// script models that compete to identify the script and read it. See
/// `RecognitionBackend`.
public struct ScreenTextReader: Sendable {
    private let tesseract: TesseractRecognizer

    public init() {
        tesseract = TesseractRecognizer()
    }

    init(tesseract: TesseractRecognizer) {
        self.tesseract = tesseract
    }

    /// Recognise all text in `image` (a crop of a screenshot at native pixel scale).
    /// Word and line rects are in `image` pixels with a top-left origin.
    public func read(_ image: CGImage) async throws -> RecognizedText {
        let tesseract = tesseract
        let work = Task.detached(priority: .userInitiated) {
            try Self.recognize(image, tesseract: tesseract)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func recognize(_ image: CGImage, tesseract: TesseractRecognizer) throws -> RecognizedText {
        let vision = try TextRecognizer().read(image)
        // At the image's own scale, for finding unread text and column gaps inside lines.
        let pixels = GrayImage(image)
        // Every line is read in full confidence here.
        if RecognitionBackend.visionSuffices(vision) {
            return ReadingOrder.assemble(vision.lines, image: pixels)
        }
        try Task.checkCancellation()
        let lines = try RecognitionBackend.read(image, vision: vision, pixels: pixels, tesseract: tesseract)
        return ReadingOrder.assemble(lines, image: pixels)
    }
}
