import CoreGraphics

/// A word as an engine reported it, before assembly into `RecognizedText`.
struct OCRWord: Equatable {
    var text: String
    /// Pixels in the source image, top-left origin.
    var rect: CGRect
    /// What stands between this word and the previous one in its line: " " or "".
    var separator: String
}

/// A line as an engine reported it. `words` are in logical (reading) order.
struct OCRLine: Equatable {
    var words: [OCRWord]
    var rect: CGRect
    /// 0…1. Vision's is coarse (0.3, 0.5 or 1); Tesseract's is the mean word score.
    var confidence: Float

    var text: String {
        words.map { $0.separator + $0.text }.joined()
    }
}

/// Puts lines from either engine into reading order and assembles the public result.
enum ReadingOrder {
    /// - Parameter image: the image the lines were read from, used to split lines that
    ///   run across a column gap. Nil skips that step.
    static func assemble(_ lines: [OCRLine], image: GrayImage? = nil) -> RecognizedText {
        var lines = lines.filter { !$0.words.isEmpty }
        if let image {
            lines = lines.flatMap { ColumnGaps.split($0, in: image) }
        }
        let pageScripts = Script.histogram(of: lines.map(\.text).joined())
        let rightToLeft = pageScripts.filter { $0.key.isRightToLeft }.values.reduce(0, +)
            > pageScripts.filter { !$0.key.isRightToLeft }.values.reduce(0, +)

        var words: [RecognizedWord] = []
        var recognizedLines: [RecognizedLine] = []
        for line in sort(lines, rightToLeft: rightToLeft) {
            let start = words.count
            for word in line.words {
                words.append(RecognizedWord(text: word.text, rect: word.rect, lineIndex: recognizedLines.count))
            }
            recognizedLines.append(RecognizedLine(text: line.text, rect: line.rect, wordRange: start..<words.count))
        }
        return RecognizedText(words: words, lines: recognizedLines)
    }

    /// Lines grouped into blocks — runs of lines that sit one under the other and
    /// overlap horizontally, i.e. paragraphs and columns — with blocks ordered top to
    /// bottom and, where they start level, left to right (right to left on a
    /// Hebrew or Arabic page). Lines within a block run top to bottom.
    static func sort(_ lines: [OCRLine], rightToLeft: Bool) -> [OCRLine] {
        var blocks: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            let candidates = blocks.indices.filter { continues(blocks[$0].last!, with: line) }
            if let best = candidates.max(by: {
                horizontalOverlap(blocks[$0].last!.rect, line.rect) < horizontalOverlap(blocks[$1].last!.rect, line.rect)
            }) {
                blocks[best].append(line)
            } else {
                blocks.append([line])
            }
        }

        // Blocks whose tops are level form a row, read across; rows run down the page.
        var rows: [[[OCRLine]]] = []
        for block in blocks.sorted(by: { $0[0].rect.minY < $1[0].rect.minY }) {
            if let first = rows.last?.first?.first,
               block[0].rect.minY - first.rect.minY < min(first.rect.height, block[0].rect.height) * 0.7 {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows.flatMap { row in
            row.sorted { rightToLeft ? $0[0].rect.maxX > $1[0].rect.maxX : $0[0].rect.minX < $1[0].rect.minX }
        }.flatMap { $0 }
    }

    /// Whether `next` continues the block ending in `last`: close below it, and
    /// overlapping it horizontally rather than sitting beside it.
    private static func continues(_ last: OCRLine, with next: OCRLine) -> Bool {
        let height = max(last.rect.height, next.rect.height)
        let gap = next.rect.minY - last.rect.maxY
        guard gap > -height * 0.5, gap < height * 1.2 else { return false }
        let narrower = min(last.rect.width, next.rect.width)
        return narrower > 0 && horizontalOverlap(last.rect, next.rect) > narrower * 0.3
    }

    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    // MARK: - Words within a line

    /// Orders words given only their positions — Tesseract's case — into logical order.
    ///
    /// A right-to-left line is read right to left, but a run of left-to-right words
    /// inside it (a product name and the number after it) keeps its own left-to-right
    /// order, as the Unicode bidi algorithm lays it out; and the reverse for a Hebrew
    /// name inside an English line. Anything between two words of such a run belongs
    /// to it; numbers next to it join it too, punctuation does not.
    ///
    /// Visual order does not always determine logical order — "2 iPhones" and
    /// "iPhones 2" in a Hebrew sentence render identically — so numbers beside a run
    /// are read as belonging to it, which is right for "iPhone 15".
    static func logicalOrder(_ words: [OCRWord], rightToLeft: Bool) -> [OCRWord] {
        let visual = words.sorted { rightToLeft ? $0.rect.midX > $1.rect.midX : $0.rect.midX < $1.rect.midX }
        var ordered: [OCRWord] = []
        var run: [OCRWord] = []
        var neutrals: [OCRWord] = []

        for word in visual {
            switch direction(of: word.text) {
            case .some(let wordIsRTL) where wordIsRTL == rightToLeft:
                ordered += run.reversed() + neutrals
                ordered.append(word)
                run = []
                neutrals = []
            case .some:
                if run.isEmpty {
                    let numbers = neutrals.reversed().prefix { $0.text.contains(where: \.isNumber) }.count
                    ordered += neutrals.dropLast(numbers)
                    run = Array(neutrals.suffix(numbers))
                } else {
                    run += neutrals
                }
                run.append(word)
                neutrals = []
            case .none:
                neutrals.append(word)
            }
        }
        return ordered + run.reversed() + neutrals
    }

    /// True for a word led by a right-to-left letter, false for left-to-right, nil
    /// when it has no letters (digits, punctuation).
    static func direction(of text: String) -> Bool? {
        for scalar in text.unicodeScalars {
            if let script = Script.of(scalar) { return script.isRightToLeft }
            if scalar.properties.isAlphabetic { return false }
        }
        return nil
    }
}

/// Splits a line that runs across a column gap.
///
/// Vision reads text sharing a baseline as one line even across a gap between table
/// cells, so a row comes back as "…$20/mo Custom enterprise…" and gets translated as
/// one run-on sentence. Whether it does depends on exactly where the capture's edges
/// fall. Its word boxes don't show the gap either — the box of the word before it
/// stretches across the empty space — so the gap is found in the pixels: a run of
/// plain background wider than an ordinary space by far.
enum ColumnGaps {
    /// Background this many line-heights wide is a column boundary. Word spacing
    /// measures about 0.3 of the line height; two web-page table cells, 2.3.
    static let minimumGap: CGFloat = 1.2
    /// How far from the background a pixel must be to count as ink.
    static let inkContrast = 48

    static func split(_ line: OCRLine, in image: GrayImage) -> [OCRLine] {
        guard line.words.count > 1 else { return [line] }
        let band = line.rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        let minX = Int(band.minX), maxX = Int(band.maxX), minY = Int(band.minY), maxY = Int(band.maxY)
        guard maxX - minX > 2, maxY - minY > 2 else { return [line] }

        // The band is mostly background, so its commonest value is the background.
        var histogram = [Int](repeating: 0, count: 256)
        for y in minY..<maxY {
            let row = image.pixels + y * image.width
            for x in minX..<maxX { histogram[Int(row[x])] += 1 }
        }
        let background = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0

        func hasInk(_ x: Int) -> Bool {
            for y in minY..<maxY where abs(Int(image.pixels[y * image.width + x]) - background) > inkContrast {
                return true
            }
            return false
        }

        // Interior runs of blank columns at least `minimumGap` line-heights wide.
        let needed = Int((CGFloat(maxY - minY) * minimumGap).rounded(.up))
        var gaps: [ClosedRange<CGFloat>] = []
        var seenInk = false
        var runStart: Int?
        for x in minX..<maxX {
            if hasInk(x) {
                if let start = runStart, seenInk, x - start >= needed {
                    gaps.append(CGFloat(start)...CGFloat(x))
                }
                runStart = nil
                seenInk = true
            } else if runStart == nil {
                runStart = x
            }
        }
        guard !gaps.isEmpty else { return [line] }

        // Each word goes to the side of every gap its centre is on; words keep their
        // reading order within a piece. A box stretched across a gap is trimmed back.
        var pieces: [Int: [OCRWord]] = [:]
        for word in line.words {
            let index = gaps.filter { word.rect.midX > $0.upperBound.midpoint(with: $0.lowerBound) }.count
            var word = word
            if index < gaps.count, word.rect.maxX > gaps[index].lowerBound {
                word.rect.size.width = max(1, gaps[index].lowerBound - word.rect.minX)
            }
            if index > 0, word.rect.minX < gaps[index - 1].upperBound {
                let right = word.rect.maxX
                word.rect.origin.x = gaps[index - 1].upperBound
                word.rect.size.width = max(1, right - word.rect.minX)
            }
            if pieces[index] == nil { word.separator = "" }
            pieces[index, default: []].append(word)
        }
        guard pieces.count > 1 else { return [line] }
        return pieces.keys.sorted().compactMap { key in
            guard let words = pieces[key], let first = words.first else { return nil }
            let rect = words.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            return OCRLine(words: words, rect: rect, confidence: line.confidence)
        }
    }
}

private extension CGFloat {
    func midpoint(with other: CGFloat) -> CGFloat { (self + other) / 2 }
}
