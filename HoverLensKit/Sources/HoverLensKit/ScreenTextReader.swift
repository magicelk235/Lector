import CoreGraphics
import Foundation

/// Reads all the text in an image, in whatever script it is written.
///
/// Vision reads every image first and, for Latin and CJK text, alone. When the text is
/// in anything else — or Vision's reading is in doubt — bundled Tesseract script
/// models compete over a sample to identify the script, the winner reads the whole
/// image, and the two readings are merged line by line. See `RecognitionBackend`.
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
        let visionOnly = vision.lines.filter { $0.confidence >= RecognitionBackend.minimumVisionConfidence }
        // At the image's own scale, for finding column gaps inside lines.
        let pixels = GrayImage(image)
        if RecognitionBackend.visionSuffices(vision) {
            return ReadingOrder.assemble(visionOnly, image: pixels)
        }
        try Task.checkCancellation()

        let scale = tesseractScale(for: vision)
        let regions = RecognitionBackend.sampleRegions(vision, imageSize: CGSize(width: image.width, height: image.height))
        // Nothing detected anywhere: sample the whole image if it is small enough to
        // be one line or two, which is where Vision's detector misses scripts.
        let sample = regions.isEmpty
            ? (image.width * image.height <= 1_000_000 ? GrayImage(image, scale: scale) : nil)
            : GrayImage(stacking: regions, of: image, scale: scale)
        let candidates = RecognitionBackend.candidates(visionText: vision.lines.map(\.text).joined(separator: "\n"),
                                                       available: tesseract.hasModel(for:))
        guard let sample,
              let (script, engine) = RecognitionBackend.identifyScript(in: sample, candidates: candidates,
                                                                      tesseract: tesseract)
        else { return ReadingOrder.assemble(visionOnly, image: pixels) }
        try Task.checkCancellation()

        guard let full = GrayImage(image, scale: scale) else { return ReadingOrder.assemble(visionOnly, image: pixels) }
        let lines = try tesseract.read(full, scale: scale, with: engine)
        return ReadingOrder.assemble(RecognitionBackend.merge(tesseract: lines, vision: vision.lines, script: script),
                                     image: pixels)
    }

    /// How much to enlarge the image for Tesseract, which misreads text under about
    /// 20px a line. Retina screen text is 26–40px and read as it is; text from a
    /// standard-resolution screen is half that.
    static func tesseractScale(for reading: VisionReading) -> CGFloat {
        let heights = (reading.textRegions + reading.lines.map(\.rect)).map(\.height).sorted()
        guard !heights.isEmpty else { return 1 }
        let median = heights[heights.count / 2]
        return median < 12 ? 3 : median < 20 ? 2 : 1
    }
}
