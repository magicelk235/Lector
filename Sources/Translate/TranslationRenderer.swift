import AppKit
import HoverLensKit

/// Paints translated paragraphs over a capture and records where every word landed,
/// so the result can be picked from exactly like recognised text.
///
/// Each paragraph covers its original in the page's background colour and is written
/// in its text colour, starting at about the original size and shrinking until it fits
/// the space the original took.
enum TranslationRenderer {
    struct Rendering {
        /// Same pixel size as the capture.
        let image: CGImage
        /// Word and paragraph rects in `image`'s pixels, top-left origin. One line per
        /// paragraph, so a copy across a wrap doesn't break the sentence.
        let text: RecognizedText
    }

    /// `translations` has one entry per block; a nil one is left as it is on screen, its
    /// original words still pickable — Apple translates a paragraph at a time, and the
    /// ones it hasn't reached yet shouldn't be dead.
    static func render(over capture: CGImage, original: RecognizedText, blocks: [Paragraphs.Block],
                       translations: [String?], rightToLeft: Bool) -> Rendering? {
        guard blocks.count == translations.count else { return nil }
        let width = capture.width, height = capture.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(capture, in: bounds)
        // Top-left origin from here on, matching the recognised text's pixel rects.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        var words: [RecognizedWord] = []
        var lines: [RecognizedLine] = []

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (block, maybeTranslation) in zip(blocks, translations) {
            guard let translation = maybeTranslation else {
                let start = words.count
                for line in block.lines where original.lines.indices.contains(line) {
                    for index in original.lines[line].wordRange {
                        let word = original.words[index]
                        words.append(RecognizedWord(text: word.text, rect: word.rect, lineIndex: lines.count))
                    }
                }
                lines.append(RecognizedLine(text: block.text, rect: block.rect, wordRange: start..<words.count))
                continue
            }
            let colors = ColorSampler.colors(in: capture, rect: block.rect)
            colors.background.setFill()
            // A little bigger than the original, so no edge of it shows through.
            block.rect.insetBy(dx: -block.lineHeight * 0.15, dy: -block.lineHeight * 0.1)
                .intersection(bounds).fill()

            let layout = fit(translation, in: block, ink: colors.ink, rightToLeft: rightToLeft)
            let origin = block.rect.origin
            let glyphs = layout.manager.glyphRange(for: layout.container)
            layout.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)

            let start = words.count
            for range in tokens(in: translation) {
                let glyphRange = layout.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                // The rects a selection of just these characters would light up.
                // `boundingRect(forGlyphRange:)` is wrong here: where right-to-left and
                // left-to-right text meet a line break it takes in the line's spare
                // width, and the highlight lands off the word.
                var rect = CGRect.null
                layout.manager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: layout.container) { piece, _ in rect = rect.union(piece) }
                guard !rect.isNull else { continue }
                rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                words.append(RecognizedWord(text: (translation as NSString).substring(with: range),
                                            rect: rect, lineIndex: lines.count))
            }
            let used = layout.manager.usedRect(for: layout.container).offsetBy(dx: origin.x, dy: origin.y)
            lines.append(RecognizedLine(text: translation, rect: used, wordRange: start..<words.count))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return Rendering(image: image, text: RecognizedText(words: words, lines: lines))
    }

    private struct Layout {
        let manager: NSLayoutManager
        let container: NSTextContainer
        let storage: NSTextStorage
    }

    /// Lays `text` out in the block's width, from about the original's size down to 30%
    /// of it, stopping at the first size that fits the block's height.
    private static func fit(_ text: String, in block: Paragraphs.Block, ink: NSColor, rightToLeft: Bool) -> Layout {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: block.rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = rightToLeft ? .right : .left
        paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
        paragraph.lineBreakMode = .byWordWrapping

        // A recognised line's box runs from ascender to descender, a little taller
        // than the font's point size.
        let original = max(8, block.lineHeight * 0.8)
        var size = original
        while true {
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ]))
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            if used.height <= block.rect.height * 1.05 || size <= original * 0.3 { break }
            size *= 0.92
        }
        return Layout(manager: manager, container: container, storage: storage)
    }

    /// Word ranges that between them cover every character but the spaces, so each
    /// word carries its punctuation ("dog.", "(e.g.,", "dit-il.") and copying all of
    /// them gives back the whole sentence. Words are what spaces separate; only in
    /// scripts written without spaces (Chinese, Japanese, Thai…) are they found by
    /// word breaking, with trailing punctuation kept on the word before it.
    static func tokens(in text: String) -> [NSRange] {
        let string = text as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool {
            UnicodeScalar(string.character(at: index)).map(whitespace.contains) ?? false
        }

        var ranges: [NSRange] = []
        var index = 0
        while index < string.length {
            while index < string.length, isSpace(index) { index += 1 }
            let start = index
            while index < string.length, !isSpace(index) { index += 1 }
            guard index > start else { continue }
            let chunk = NSRange(location: start, length: index - start)
            if string.substring(with: chunk).contains(where: Paragraphs.isSpaceless) {
                ranges += wordBreaks(in: chunk, of: string)
            } else {
                ranges.append(chunk)
            }
        }
        return ranges
    }

    private static func wordBreaks(in chunk: NSRange, of string: NSString) -> [NSRange] {
        var starts: [Int] = []
        string.enumerateSubstrings(in: chunk, options: .byWords) { _, range, _, _ in
            starts.append(range.location)
        }
        guard !starts.isEmpty else { return [chunk] }
        starts[0] = chunk.location
        let end = chunk.location + chunk.length
        return starts.enumerated().map { index, start in
            let upper = index + 1 < starts.count ? starts[index + 1] : end
            return NSRange(location: start, length: upper - start)
        }
    }
}
