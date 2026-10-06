import CoreGraphics
import Foundation
import Vision

/// What Vision found in one image.
struct VisionReading {
    /// Recognised lines, words in logical order.
    var lines: [OCRLine]
    /// Every area Vision's script-agnostic detector sees text in, read or not. Text in
    /// a script Vision cannot read shows up here and nowhere in `lines`.
    var textRegions: [CGRect]

    /// The same reading of a crop enlarged by `scale` with its top-left corner at
    /// `origin`, in the pixels of the image it was cut from.
    func placed(at origin: CGPoint, scale: CGFloat) -> VisionReading {
        func place(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX / scale, y: origin.y + rect.minY / scale,
                   width: rect.width / scale, height: rect.height / scale)
        }
        return VisionReading(
            lines: lines.map { line in
                OCRLine(words: line.words.map { OCRWord(text: $0.text, rect: place($0.rect), separator: $0.separator) },
                        rect: place(line.rect), confidence: line.confidence)
            },
            textRegions: textRegions.map(place))
    }
}

/// Apple's Vision OCR: the first engine, and the only one for Latin and CJK text.
///
/// `.accurate` with language correction and automatic language detection, because
/// the user's language is unknown and accuracy matters more than the ~100ms saved by
/// `.fast`, which also misses low-contrast text entirely.
struct TextRecognizer {
    func read(_ image: CGImage) throws -> VisionReading {
        let recognize = VNRecognizeTextRequest()
        recognize.recognitionLevel = .accurate
        recognize.usesLanguageCorrection = true
        recognize.automaticallyDetectsLanguage = true
        // Relative to the image: a full-screen crop would otherwise lose small text.
        recognize.minimumTextHeight = Float(min(1, 8 / Double(max(image.height, 1))))

        let detect = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognize, detect])

        let size = CGSize(width: image.width, height: image.height)
        let lines = (recognize.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let lineRect = Self.pixelRect(observation.boundingBox, in: size)
            let words = Self.tokens(in: candidate.string).map { token in
                OCRWord(text: String(candidate.string[token.range]),
                        rect: (try? candidate.boundingBox(for: token.range))
                            .map { Self.pixelRect($0.boundingBox, in: size) } ?? lineRect,
                        separator: token.separator)
            }
            guard !words.isEmpty else { return nil }
            return OCRLine(words: words, rect: lineRect, confidence: candidate.confidence)
        }
        let regions = (detect.results ?? []).map { Self.pixelRect($0.boundingBox, in: size) }
        return VisionReading(lines: lines, textRegions: regions)
    }

    /// Reads `region` of `image` on its own, enlarged by `scale`, with boxes in
    /// `image` pixels.
    ///
    /// Vision misses short isolated words that are small next to the whole image — four
    /// of five CJK menu labels in a 1104×361 capture — and reads them once shown little
    /// more than their surroundings. Cut out, small text needs enlarging: four kanji
    /// labels 15px tall it read none of, twice the size all four.
    func read(_ image: CGImage, in region: CGRect, scale: CGFloat = 1) throws -> VisionReading {
        let region = region.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !region.isEmpty, var crop = image.cropping(to: region) else { return VisionReading(lines: [], textRegions: []) }
        if scale > 1 {
            let width = Int(region.width * scale), height = Int(region.height * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return VisionReading(lines: [], textRegions: []) }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let enlarged = context.makeImage() else { return VisionReading(lines: [], textRegions: []) }
            crop = enlarged
        }
        return try read(crop).placed(at: region.origin, scale: scale)
    }

    /// Vision's normalised, bottom-left-origin box as pixels from the top left.
    static func pixelRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }

    /// Splits a recognised line into words that together cover every visible
    /// character, so copying words back loses no punctuation.
    ///
    /// Spaces separate words wherever the text has them. Runs written without spaces
    /// (Chinese, Japanese, Thai) are cut at ICU's word boundaries instead, with any
    /// punctuation kept on the word before it.
    static func tokens(in text: String) -> [(range: Range<String.Index>, separator: String)] {
        var tokens: [(range: Range<String.Index>, separator: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let chunkStart = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let chunk = chunkStart..<index
            let separator = tokens.isEmpty ? "" : " "

            let unspaced = text[chunk].unicodeScalars.contains {
                Script.of($0)?.joinsWithoutSpaces ?? $0.isUnspacedPunctuation
            }
            var starts: [String.Index] = []
            if unspaced {
                text.enumerateSubstrings(in: chunk, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
                    starts.append(range.lowerBound)
                }
            }
            // Punctuation before the first word stays with it.
            starts = [chunk.lowerBound] + starts.filter { $0 > chunk.lowerBound }
            for (position, start) in starts.enumerated() {
                let end = position + 1 < starts.count ? starts[position + 1] : chunk.upperBound
                tokens.append((start..<end, position == 0 ? separator : ""))
            }
        }
        return tokens
    }
}
