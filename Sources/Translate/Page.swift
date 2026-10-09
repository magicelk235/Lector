import AppKit
import LectorKit

/// The page under a translation, measured on the capture: how large and how heavy each
/// paragraph's type is and where its lines sit, which edge its column keeps, and how much
/// empty page around it a longer translation can take.
///
/// OCR's line boxes don't give the size of the type. Vision's box for "View" is a third
/// shorter than its box for "Help" at one size, and its bottom sits anywhere from a sixth
/// of the size above the baseline to below the descenders. So each line is measured on
/// the capture — the rows its ink spans, against how tall the same text stands in the
/// system font. For San Francisco, Helvetica, Arial, Times and Georgia that comes within
/// 0.9–1.14 of the true size; the boxes ranged from 0.6 to 1.07.
struct Page {
    enum Edge {
        case left, right, centre
    }

    struct Paragraph {
        let colors: ColorSampler.Colors
        /// Type size, in the capture's pixels.
        fileprivate(set) var size: CGFloat
        fileprivate(set) var weight: NSFont.Weight
        /// The first line's baseline, from the top.
        let baseline: CGFloat
        /// Baseline to baseline, for a paragraph of more than one line.
        let pitch: CGFloat?
        let lineCount: Int
        /// The original's ink: what its patch must cover.
        let ink: CGRect
        let rightToLeft: Bool
        /// The stretch of its own background around it: a button, a card, the page. A
        /// translation and its patch stay inside it, unless the text is on a picture.
        let panel: CGRect
        /// Set on a picture — a video frame, a photo — with no plain background around it.
        fileprivate(set) var pictured = false
        /// How far a patch over the original can spread before it reaches other text.
        fileprivate(set) var clearance: CGFloat = .greatestFiniteMagnitude
        /// The edge its column keeps, and where that edge is.
        fileprivate(set) var edge = Edge.left
        fileprivate(set) var anchor: CGFloat = 0
        /// From its column's left edge to its right: where the column's text is.
        fileprivate(set) var columnSpan: ClosedRange<CGFloat> = 0...0
        /// The width its column's paragraphs wrap at, when one of them has more than a line.
        fileprivate(set) var measure: CGFloat?
        /// Across its lines, the empty page either side of them: up to other text, to
        /// anything else drawn on the page, or to the edge of the capture.
        fileprivate(set) var room: ClosedRange<CGFloat> = 0...0
        /// The same past drawings, up to text alone: taken only to stay legible.
        fileprivate(set) var reach: ClosedRange<CGFloat> = 0...0
        /// For each whole pixel column of `room`, where the empty page below it ends.
        fileprivate var depths: [CGFloat] = []

        /// Where its last line ends: the space that's its own whatever else is on the page.
        var bottom: CGFloat {
            max(ink.maxY, baseline + CGFloat(lineCount - 1) * (pitch ?? size * 1.2) + size * 0.3)
        }
    }

    /// Paragraphs whose type is one size, smallest first.
    struct Role {
        let size: CGFloat
        /// Baseline to baseline over size, where one of them shows it.
        let pitch: CGFloat?
        let members: [Int]
    }

    let size: CGSize
    private(set) var paragraphs: [Paragraph]
    private(set) var roles: [Role] = []
    /// Paragraphs that keep one edge — or centre — one above the other.
    private(set) var columns: [[Int]] = []
    /// Single lines side by side on one panel — a toolbar, a menu bar, tabs — each row
    /// left to right.
    private(set) var rows: [[Int]] = []

    /// Text is kept this far apart, over its size.
    static let spacing: CGFloat = 0.35
    /// A pixel this far from the page's colour, summed over its channels, is something
    /// drawn on the page.
    private static let drawn = 48

    init(capture: CGImage, original: RecognizedText, blocks: [Paragraphs.Block]) {
        size = CGSize(width: capture.width, height: capture.height)
        let whole = CGRect(origin: .zero, size: size)
        let bitmap = Bitmap(capture, rect: whole)
        let colors = blocks.map { block in
            bitmap.map { ColorSampler.colors(in: $0, rect: block.rect, lineHeight: block.lineHeight) }
                ?? ColorSampler.Colors(backgroundRGB: RGB(red: 255, green: 255, blue: 255),
                                       inkRGB: RGB(red: 0, green: 0, blue: 0))
        }
        // Where the page is blank, once for each page colour there is.
        var blanks: [RGB: Plane] = [:]
        for page in Set(colors.map(\.backgroundRGB)) {
            blanks[page] = bitmap?.matching(page, within: Self.drawn, in: whole)?.turned()
        }
        var lineInks: [[CGRect]] = [], strokes: [CGFloat?] = []
        paragraphs = blocks.indices.map { index in
            let page = colors[index].backgroundRGB
            // Other paragraphs' lines on the same page colour, which its panel runs on past.
            let others = blocks.indices.filter { $0 != index && colors[$0].backgroundRGB == page }.flatMap { other in
                blocks[other].lines.filter(original.lines.indices.contains).map { original.lines[$0].rect }
            }
            let (paragraph, lines, stroke) = Self.measure(blocks[index], in: original, colors: colors[index],
                                                          bitmap: bitmap, blank: blanks[page], others: others)
            lineInks.append(lines)
            strokes.append(stroke)
            return paragraph
        }
        weighDenseScripts(strokes, texts: blocks.map(\.text))
        keepBodiesUnderHeadings()
        findClearances()
        findColumns(lineInks)
        findRoles()
        for index in paragraphs.indices {
            findRoom(of: index, on: blanks[paragraphs[index].colors.backgroundRGB], in: bitmap)
        }
        findRows()
    }

    /// How far down the empty page goes below paragraph `index`, across `span`.
    func floor(of index: Int, across span: ClosedRange<CGFloat>) -> CGFloat {
        let paragraph = paragraphs[index]
        let first = Int(paragraph.room.lowerBound.rounded(.up))
        let from = max(0, Int(span.lowerBound.rounded(.down)) - first)
        let to = min(paragraph.depths.count - 1, Int(span.upperBound.rounded(.up)) - first)
        guard from <= to else { return paragraph.bottom }
        return min(paragraph.depths[from...to].min() ?? paragraph.bottom, reachFloor(of: index, across: span))
    }

    /// How far down paragraph `index` can reach across `span` before other text, the
    /// edge of the capture or the end of its background, past anything else drawn there.
    func reachFloor(of index: Int, across span: ClosedRange<CGFloat>) -> CGFloat {
        let paragraph = paragraphs[index]
        var floor = (paragraph.pictured ? size.height : paragraph.panel.maxY) - paragraph.size * 0.25
        for (other, below) in paragraphs.enumerated() where other != index {
            guard below.ink.midY > paragraph.ink.maxY, below.ink.minX < span.upperBound,
                  span.lowerBound < below.ink.maxX
            else { continue }
            floor = min(floor, below.ink.minY - paragraph.size * Self.spacing)
        }
        return floor
    }

    // MARK: Measuring type

    /// What one recognised line's ink says.
    private struct LineInk {
        let ink: CGRect
        let text: String
        /// Stroke width over size, from a first estimate of the size.
        let stroke: CGFloat?

        /// Size and baseline, for type of `weight`. Ideographs, kana and Hangul each stand
        /// in a square as wide as the type's size, so along a line of them the width says
        /// the size too, and nothing above or below the line can stretch it past that.
        func type(_ weight: NSFont.Weight) -> (size: CGFloat, baseline: CGFloat)? {
            let standing = Page.standing(text, weight: weight)
            guard standing.height > 0.3 else { return nil }
            var size = ink.height / standing.height
            if Page.isDense(text), standing.width > 0 {
                size = min(size, ink.width / standing.width * 1.1)
            }
            return (size, ink.maxY - standing.descent * size)
        }
    }

    /// A paragraph as measured on the capture, its lines' ink, and the stroke width of its
    /// letters over their size where its ink could be told from its page. Its panel runs
    /// on past `others`, other paragraphs' lines on its page colour.
    private static func measure(_ block: Paragraphs.Block, in original: RecognizedText, colors: ColorSampler.Colors,
                                bitmap: Bitmap?, blank: Plane?, others: [CGRect]) -> (Paragraph, [CGRect], CGFloat?) {
        let rightToLeft = isRightToLeft(block.text)
        let indices = block.lines.filter(original.lines.indices.contains)
        let panel = blank.map { panel(around: block.rect, on: $0, size: block.lineHeight, passing: others) } ?? block.rect
        // The paragraph and the page around it as ink, as far out as its lines are looked
        // for and no further than its own background: white text on a blue button is the
        // colour of the white page around the button.
        let around = block.rect.insetBy(dx: -block.lineHeight * 0.6, dy: -block.lineHeight * 0.7).intersection(panel)
        let plane = bitmap?.inkness(in: around, from: colors.backgroundRGB, to: colors.inkRGB)
        let inks: [LineInk?] = indices.map { index in
            plane.flatMap { measure(original.lines[index], limits: limits(of: index, in: original), in: $0) }
        }
        let found = inks.compactMap { $0 }
        let boxes = indices.map { original.lines[$0].rect }
        guard !found.isEmpty else {
            return (estimate(block, boxes: boxes, colors: colors, rightToLeft: rightToLeft, panel: panel), boxes, nil)
        }

        // The stroke a full line's letters show says more than a short last line's few.
        let stroke = median(found.compactMap { line in line.stroke.map { (value: $0, weight: line.ink.width) } })
        // Ideographs, kana and Hangul are weighed against each other, once every paragraph is.
        let weight: NSFont.Weight = isDense(block.text) ? .regular : Self.weight(stroke: stroke)
        let types = inks.map { $0?.type(weight) }
        // Baseline to baseline between neighbouring lines that were both measured.
        let pitches = zip(types, types.dropFirst()).compactMap { upper, lower -> CGFloat? in
            guard let upper, let lower else { return nil }
            return lower.baseline - upper.baseline
        }
        // Type is never much larger than the lines it's set in are apart: lines that size
        // would run into each other. How far apart they are is measured on the ink where it
        // can be: Vision's boxes only roughly say, one of them at times taking in part of
        // the line above.
        let boxPitch = median(zip(boxes, boxes.dropFirst()).map { $1.midY - $0.midY })
        guard let size = median(types.compactMap { $0?.size }),
              size <= (median(pitches) ?? boxPitch).map({ $0 * 1.25 }) ?? .greatestFiniteMagnitude
        else {
            return (estimate(block, boxes: boxes, colors: colors, rightToLeft: rightToLeft, panel: panel), boxes, nil)
        }
        let lineRects = zip(indices, inks).map { index, ink in ink?.ink ?? original.lines[index].rect }
        let first = types.first.flatMap { $0 }?.baseline
            ?? (original.lines[indices[0]].rect.maxY - size * 0.15)
        let paragraph = Paragraph(colors: colors, size: size, weight: weight, baseline: first,
                                  pitch: indices.count > 1 ? median(pitches) ?? boxPitch ?? size * 1.2 : nil,
                                  lineCount: indices.count,
                                  ink: lineRects.dropFirst().reduce(lineRects[0]) { $0.union($1) },
                                  rightToLeft: rightToLeft, panel: panel)
        return (paragraph, lineRects, stroke)
    }

    /// A paragraph whose ink couldn't be told from its page: what its boxes say, taking
    /// each for a line's height — ascender to descender, about 1.2 of the type's size.
    private static func estimate(_ block: Paragraphs.Block, boxes: [CGRect], colors: ColorSampler.Colors,
                                 rightToLeft: Bool, panel: CGRect) -> Paragraph {
        let lineCount = boxes.isEmpty ? max(1, Int((block.rect.height / (block.lineHeight * 1.15)).rounded()))
            : boxes.count
        let pitches = zip(boxes, boxes.dropFirst()).map { $1.midY - $0.midY }
        let pitch = lineCount > 1
            ? median(pitches) ?? (block.rect.height - block.lineHeight) / CGFloat(lineCount - 1) : nil
        let firstBox = boxes.first ?? CGRect(x: block.rect.minX, y: block.rect.minY, width: block.rect.width,
                                             height: block.lineHeight)
        return Paragraph(colors: colors, size: block.lineHeight * 0.85, weight: .regular,
                         baseline: firstBox.minY + firstBox.height * 0.8, pitch: pitch, lineCount: lineCount,
                         ink: block.rect, rightToLeft: rightToLeft, panel: panel.union(block.rect))
    }

    /// Where a line's ink may be looked for: no further than halfway to the lines above
    /// and below it.
    private static func limits(of index: Int, in text: RecognizedText) -> ClosedRange<CGFloat> {
        let box = text.lines[index].rect
        var top = box.minY - box.height * 0.6, bottom = box.maxY + box.height * 0.6
        for (other, line) in text.lines.enumerated() where other != index {
            guard line.rect.minX < box.maxX, box.minX < line.rect.maxX else { continue }
            let halfway = (line.rect.midY + box.midY) / 2
            if line.rect.midY < box.midY {
                top = max(top, halfway)
            } else {
                bottom = min(bottom, halfway)
            }
        }
        return top...max(top, bottom)
    }

    /// One line's ink, found from its box outwards: Vision's boxes cut off descenders and
    /// stand clear of the baseline, so the box only says where to start looking. `plane`
    /// is the paragraph's ink, 128 or more where a pixel is at least half ink.
    ///
    /// Not everything ink-coloured near a line is its letters: a box's border running
    /// through the line, the corner of a box of the ink's colour beside it. Those are
    /// left out, and a measurement that still doesn't fit the box — ink more than a third
    /// taller than it, or less than half — isn't trusted.
    private static func measure(_ line: RecognizedLine, limits: ClosedRange<CGFloat>, in plane: Plane) -> LineInk? {
        let box = line.rect, frame = plane.frame
        // Letters can stand a little past the box: their tails, the box cutting the last one short.
        let overhang = box.height * 0.2
        let left = Int(max(frame.minX, box.minX - overhang)), right = Int(min(frame.maxX, box.maxX + overhang)) - 1
        let top = Int(max(frame.minY, limits.lowerBound).rounded(.up))
        let bottom = Int(min(frame.maxY, limits.upperBound).rounded(.down)) - 1
        guard right > left, bottom > top,
              var mask = plane.mask(columns: left...right, rows: top...bottom, atLeast: 128)
        else { return nil }
        // A border crossing the line runs through most of the rows looked at; no letter does.
        for (column, count) in mask.columnSums().enumerated() where count * 10 > mask.height * 7 {
            mask.clear(column: column)
        }
        // Down the line's own columns, a little in from its ends, where the edge of
        // something beside it can't reach.
        let inset = min(box.height * 0.1, box.width * 0.25)
        let own = Int(box.minX + inset) - mask.left...max(Int(box.minX + inset), Int(box.maxX - inset) - 1) - mask.left
        let counts = mask.rowSums(columns: own)
        let bridge = max(1, Int(box.height * 0.08))
        // The farthest row from `start`, stepping by `step` no further than `last`, with at
        // least `least` of `counts`: across gaps as narrow as the one under an i's dot.
        func edge(from start: Int, stepping step: Int, least: Int, through last: Int, in counts: [Int]) -> Int {
            var edge = start, gap = 0, y = start + step
            while (y - last) * step <= 0 {
                if counts[y] >= least {
                    edge = y
                    gap = 0
                } else {
                    gap += 1
                    if gap > bridge { break }
                }
                y += step
            }
            return edge
        }
        // The body of the letters: from the fullest row inside the box out while rows have
        // ink, but not on a stray pixel or two, too little to be part of these letters —
        // where lines are set close, the rows between them hold no more.
        let upper = max(0, Int(box.minY) - mask.top), lower = min(mask.height - 1, Int(box.maxY) - mask.top)
        guard upper <= lower, let seed = (upper...lower).max(by: { counts[$0] < counts[$1] }), counts[seed] > 0
        else { return nil }
        let least = max(1, counts[seed] / 50)
        let bodyTop = edge(from: seed, stepping: -1, least: least, through: 0, in: counts)
        let bodyBottom = edge(from: seed, stepping: 1, least: least, through: mask.height - 1, in: counts)
        // Where the letters are: the columns inked through the middle half of them, which
        // the corner of something above or below the line doesn't reach.
        let quarter = (bodyBottom - bodyTop) / 4
        let middle = mask.columnSums(rows: bodyTop + quarter...bodyBottom - quarter)
        guard let first = middle.firstIndex(where: { $0 > 0 }), let last = middle.lastIndex(where: { $0 > 0 })
        else { return nil }
        // Then their ends, a stroke's worth of ink over or under them — a long line's lone
        // descender, the accent on a capital — a little further.
        let ends = mask.rowSums(columns: first...last), tail = Int(box.height * 0.3)
        let inkTop = edge(from: bodyTop, stepping: -1, least: 1, through: max(0, bodyTop - tail), in: ends)
        let inkBottom = edge(from: bodyBottom, stepping: 1, least: 1, through: min(mask.height - 1, bodyBottom + tail),
                             in: ends)
        // Across: every column inked among the letters' rows inside the box — a full stop
        // on the baseline too — and past it, where the box cut the last letter short, those
        // inked through the middle of the letters.
        let letters = mask.columnSums(rows: inkTop...inkBottom)
        let inside = Int(box.minX) - mask.left...max(Int(box.minX), Int(box.maxX.rounded(.up)) - 1) - mask.left
        let inked = letters.indices.filter { inside.contains($0) ? letters[$0] > 0 : middle[$0] > 0 }
        guard let start = inked.first, let end = inked.last else { return nil }
        let ink = CGRect(x: CGFloat(mask.left + start), y: CGFloat(mask.top + inkTop),
                         width: CGFloat(end - start + 1), height: CGFloat(inkBottom - inkTop + 1))
        guard ink.height <= box.height * 1.35, ink.height >= box.height * 0.5,
              let type = LineInk(ink: ink, text: line.text, stroke: nil).type(.regular)
        else { return nil }
        // The median run of ink across the body of the letters is the width of their
        // stems; anti-aliased edges count for what they cover. Every third row has runs
        // enough for a median.
        let from = max(Int(ink.minY), Int((type.baseline - type.size * 0.45).rounded()))
        let to = min(Int(ink.maxY) - 1, Int((type.baseline - type.size * 0.1).rounded()))
        let columns = Int(ink.minX)...Int(ink.maxX) - 1
        let runs = stride(from: from, through: to, by: 3).flatMap { plane.runs(row: $0, columns: columns, above: 25) }
        return LineInk(ink: ink, text: line.text, stroke: median(runs).map { $0 / type.size })
    }

    /// The weight of a face whose stems are `stroke` of its size.
    private static func weight(stroke: CGFloat?) -> NSFont.Weight {
        switch stroke ?? 0 {
        // Measured stems over size: regular faces 0.09–0.115, semibold 0.12–0.15, bold 0.14–0.19.
        case 0.145...: .bold
        case 0.122...: .semibold
        default: .regular
        }
    }

    /// How far `text` reaches above and below its baseline in the system font at one
    /// pixel, and so how tall it stands, and how wide.
    fileprivate static func standing(_ text: String,
                                     weight: NSFont.Weight) -> (height: CGFloat, descent: CGFloat, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 100, weight: weight)]))
        let bounds = CTLineGetImageBounds(line, nil)
        guard !bounds.isNull else { return (0, 0, 0) }
        return (bounds.height / 100, -bounds.minY / 100, bounds.width / 100)
    }

    /// The weight of text in ideographs, kana or Hangul. Their strokes are many and close:
    /// at small sizes they run into each other, and a regular face measures as heavy as a
    /// bold Latin one, so stems alone don't say such text is bold. It is set bold only
    /// where it is clearly heavier than other such text on the capture, and larger too —
    /// a heading over its paragraph — and regular otherwise.
    private mutating func weighDenseScripts(_ strokes: [CGFloat?], texts: [String]) {
        let dense = paragraphs.indices.filter { Self.isDense(texts[$0]) && strokes[$0] != nil }
        for index in dense {
            let stroke = strokes[index] ?? 0, size = paragraphs[index].size
            let heading = dense.contains { other in
                guard let lighter = strokes[other] else { return false }
                return stroke >= max(0.14, lighter * 1.4) && size >= paragraphs[other].size * 1.1
            }
            paragraphs[index].weight = heading ? .bold : .regular
        }
    }

    /// A paragraph under a heading — a single line on the same page colour, no lighter —
    /// is never larger than the heading: body text isn't, and one measured so was measured
    /// wrong.
    private mutating func keepBodiesUnderHeadings() {
        for index in paragraphs.indices where paragraphs[index].lineCount > 1 {
            let body = paragraphs[index]
            let heading = paragraphs.indices.filter { other in
                let above = paragraphs[other]
                return above.lineCount == 1 && above.ink.maxY <= body.ink.minY
                    && body.ink.minY - above.ink.maxY < max(above.size, body.size) * 3
                    && above.ink.minX < body.ink.maxX && body.ink.minX < above.ink.maxX
                    && above.colors.backgroundRGB == body.colors.backgroundRGB
            }.max { paragraphs[$0].ink.maxY < paragraphs[$1].ink.maxY }
            guard let heading, paragraphs[heading].weight.rawValue >= body.weight.rawValue else { continue }
            paragraphs[index].size = min(body.size, paragraphs[heading].size)
        }
    }

    // MARK: The page around each paragraph

    /// How far each paragraph's ink is from the nearest other paragraph's.
    private mutating func findClearances() {
        for index in paragraphs.indices {
            let ink = paragraphs[index].ink
            for (other, paragraph) in paragraphs.enumerated() where other != index {
                let across = max(paragraph.ink.minX - ink.maxX, ink.minX - paragraph.ink.maxX)
                let down = max(paragraph.ink.minY - ink.maxY, ink.minY - paragraph.ink.maxY)
                paragraphs[index].clearance = min(paragraphs[index].clearance, max(across, down, 0))
            }
        }
    }

    /// Which edge each paragraph keeps, and the columns of paragraphs that keep one
    /// together. A paragraph's own lines say, when it has several. Otherwise the stack it
    /// is in — paragraphs one under another — decides by the edges they share. Two items
    /// about as wide share every edge, which says nothing, so a link counts for less the
    /// more edges it shares: a menu of short items and a few long ones keeps its left edge.
    private mutating func findColumns(_ lineInks: [[CGRect]]) {
        let count = paragraphs.count
        // Each paragraph and the nearest one beneath it, across which it reaches.
        var links: [(upper: Int, lower: Int, shared: Set<Edge>)] = []
        for upper in 0..<count {
            let above = paragraphs[upper]
            let lower = (0..<count).filter { candidate in
                let below = paragraphs[candidate]
                return candidate != upper && below.ink.midY > above.ink.maxY
                    && below.ink.minY - above.ink.maxY < max(above.size, below.size) * 3
                    && below.ink.minX < above.ink.maxX && above.ink.minX < below.ink.maxX
            }.min { paragraphs[$0].ink.minY < paragraphs[$1].ink.minY }
            guard let lower else { continue }
            let below = paragraphs[lower]
            let tolerance = max(above.size, below.size) * 0.5
            var shared = Set<Edge>()
            if abs(above.ink.minX - below.ink.minX) <= tolerance { shared.insert(.left) }
            if abs(above.ink.maxX - below.ink.maxX) <= tolerance { shared.insert(.right) }
            if abs(above.ink.midX - below.ink.midX) <= tolerance { shared.insert(.centre) }
            if !shared.isEmpty { links.append((upper, lower, shared)) }
        }

        let own = (0..<count).map { Self.edge(of: lineInks[$0], size: paragraphs[$0].size) }
        func votes(_ links: [(upper: Int, lower: Int, shared: Set<Edge>)]) -> [Edge: Double] {
            var votes: [Edge: Double] = [:]
            for link in links {
                for edge in link.shared { votes[edge, default: 0] += 1 / Double(link.shared.count) }
            }
            return votes
        }
        // The edge with most votes; on a tie, the one the language starts lines from, then the centre.
        func strongest(_ votes: [Edge: Double], rightToLeft: Bool) -> Edge? {
            guard let most = votes.values.max() else { return nil }
            let start: Edge = rightToLeft ? .right : .left
            return [start, .centre, start == .left ? .right : .left].first { abs((votes[$0] ?? 0) - most) < 0.001 }
        }
        for stack in Self.groups(count, joining: links.map { ($0.upper, $0.lower) }) {
            let inStack = links.filter { stack.contains($0.upper) }
            var tally = votes(inStack)
            for member in stack {
                if let edge = own[member] { tally[edge, default: 0] += 2 }
            }
            let edge = strongest(tally, rightToLeft: stack.filter { paragraphs[$0].rightToLeft }.count * 2 > stack.count)
            for member in stack {
                let paragraph = paragraphs[member]
                let mine = inStack.filter { $0.upper == member || $0.lower == member }
                paragraphs[member].edge = own[member]
                    ?? edge.flatMap { edge in mine.contains { $0.shared.contains(edge) } ? edge : nil }
                    ?? strongest(votes(mine), rightToLeft: paragraph.rightToLeft)
                    ?? (isCentredAlone(paragraph) ? .centre : paragraph.rightToLeft ? .right : .left)
            }
        }

        // Columns: paragraphs linked by the edge both keep.
        columns = Self.groups(count, joining: links.compactMap { link in
            let edge = paragraphs[link.upper].edge
            return edge == paragraphs[link.lower].edge && link.shared.contains(edge) ? (link.upper, link.lower) : nil
        })
        for members in columns {
            let inks = members.map { paragraphs[$0].ink }
            let anchor = switch paragraphs[members[0]].edge {
            case .left: Self.median(inks.map(\.minX)) ?? 0
            case .right: Self.median(inks.map(\.maxX)) ?? 0
            case .centre: Self.median(inks.map(\.midX)) ?? 0
            }
            let measure = members.filter { paragraphs[$0].lineCount > 1 }.map { paragraphs[$0].ink.width }.max()
            let span = (inks.map(\.minX).min() ?? 0)...(inks.map(\.maxX).max() ?? 0)
            for member in members {
                paragraphs[member].anchor = anchor
                paragraphs[member].measure = measure
                paragraphs[member].columnSpan = span
            }
        }
    }

    /// The edge a paragraph's own lines keep, when it has lines enough to show one.
    /// The last line of a paragraph is as long as it happens to be, so a left-aligned
    /// one is ragged on the right and a justified one too, on its last line.
    private static func edge(of lines: [CGRect], size: CGFloat) -> Edge? {
        guard lines.count > 1 else { return nil }
        func aligned(_ values: [CGFloat]) -> Bool {
            (values.max() ?? 0) - (values.min() ?? 0) <= size * 0.5
        }
        switch (aligned(lines.map(\.minX)), aligned(lines.map(\.maxX)), aligned(lines.map(\.midX))) {
        case (true, false, _): return .left
        case (false, true, _): return .right
        case (false, false, true): return .centre
        default: return nil
        }
    }

    /// A lone line in the middle of the capture, with room either side: a title, a
    /// subtitle, a button's label.
    private func isCentredAlone(_ paragraph: Paragraph) -> Bool {
        guard paragraph.lineCount == 1 else { return false }
        let margin = min(paragraph.ink.minX, size.width - paragraph.ink.maxX)
        return abs(paragraph.ink.midX - size.width / 2) <= max(size.width * 0.04, paragraph.size)
            && margin >= paragraph.size * 2
    }

    /// Groups paragraphs whose type is within an eighth of a size of each other.
    private mutating func findRoles() {
        let order = paragraphs.indices.sorted { paragraphs[$0].size < paragraphs[$1].size }
        var groups: [[Int]] = []
        for index in order {
            if let smallest = groups.last?.first, paragraphs[index].size <= paragraphs[smallest].size * 1.12 {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        roles = groups.map { members in
            Role(size: Self.median(members.map { paragraphs[$0].size }) ?? 0,
                 pitch: Self.median(members.compactMap { index in
                     paragraphs[index].pitch.map { $0 / paragraphs[index].size }
                 }),
                 members: members)
        }
    }

    /// As far as a translation could want to run on past its original: twice the
    /// original's width or twenty letters beside it, and its height and six lines more
    /// below it.
    private static func farthest(_ paragraph: Paragraph) -> (across: CGFloat, down: CGFloat) {
        (max(paragraph.ink.width * 2, paragraph.size * 20), paragraph.ink.height + paragraph.size * 6)
    }

    /// The stretch of a paragraph's own background around `rect`: out from it while at
    /// least half of each column across its rows, and of each row across its columns, is
    /// that colour. A button's edge, a card's border, a box of another colour stop it;
    /// text doesn't — its own letters standing past `rect`, other lines (`others`) whose
    /// stems fill a column of the line beside them. `blank` is 1 where the page is that colour.
    private static func panel(around rect: CGRect, on blank: Plane, size: CGFloat, passing others: [CGRect]) -> CGRect {
        let frame = blank.frame
        let overhang = size * 0.2
        let band = Int(rect.minY)...max(Int(rect.minY), Int(rect.maxY) - 1)
        let across = Int(max(frame.minX, rect.minX - size * 30))...Int(min(frame.maxX, rect.maxX + size * 30)) - 1
        guard let row = blank.mask(columns: across, rows: band, atLeast: 1) else { return rect }
        let columns = row.columnSums()
        let words = (others + [rect]).filter { $0.minY < rect.maxY && rect.minY < $0.maxY }.map { box in
            Int(box.minX - overhang) - row.left...max(Int(box.minX - overhang), Int(box.maxX + overhang)) - row.left
        }
        func open(_ column: Int) -> Bool {
            columns[column] * 2 >= row.height || words.contains { $0.contains(column) }
        }
        var left = max(0, min(columns.count - 1, Int(rect.minX) - row.left))
        var right = max(left, min(columns.count - 1, Int(rect.maxX) - 1 - row.left))
        while left > 0, open(left - 1) { left -= 1 }
        while right < columns.count - 1, open(right + 1) { right += 1 }
        let down = Int(max(frame.minY, rect.minY - size * 15))...Int(min(frame.maxY, rect.maxY + size * 15)) - 1
        guard let column = blank.mask(columns: Int(rect.minX)...max(Int(rect.minX), Int(rect.maxX) - 1), rows: down,
                                      atLeast: 1)
        else { return rect }
        let rows = column.rowSums()
        let lines = others.filter { $0.minX < rect.maxX && rect.minX < $0.maxX }.map { box in
            Int(box.minY) - column.top...max(Int(box.minY), Int(box.maxY.rounded(.up)) - 1) - column.top
        }
        func clear(_ row: Int) -> Bool {
            rows[row] * 2 >= column.width || lines.contains { $0.contains(row) }
        }
        var top = max(0, min(rows.count - 1, Int(rect.minY) - column.top))
        var bottom = max(top, min(rows.count - 1, Int(rect.maxY) - 1 - column.top))
        while top > 0, clear(top - 1) { top -= 1 }
        while bottom < rows.count - 1, clear(bottom + 1) { bottom += 1 }
        return CGRect(x: CGFloat(row.left + left), y: CGFloat(column.top + top), width: CGFloat(right - left + 1),
                      height: CGFloat(bottom - top + 1)).union(rect)
    }

    /// The empty page around paragraph `index`, within its panel: as far as a translation
    /// could want to run on, and at least its column's width. Side by side, two
    /// paragraphs split the space between them, each first taking its column's width
    /// where that doesn't already run into the other. The page is only empty where it is
    /// the paragraph's own background colour: a border or an icon stops it. Text set on a
    /// picture — a subtitle on video, a caption on a photo — has no plain background
    /// around it at all, and there the picture is no reason to hold back: it may take up
    /// to other text. A button's label stays in the middle of its button. `blank` is 1
    /// where the page is its background colour.
    private mutating func findRoom(of index: Int, on blank: Plane?, in bitmap: Bitmap?) {
        let paragraph = paragraphs[index]
        let ink = paragraph.ink, gap = paragraph.size * Self.spacing, panel = paragraph.panel
        let (most, down) = Self.farthest(paragraph)
        let rim = paragraph.size * 0.15, strip = paragraph.size * 3
        // A panel no wider than the text, between strips of many colours.
        let sides = [CGRect(x: ink.maxX + rim, y: ink.minY, width: strip, height: ink.height),
                     CGRect(x: ink.minX - rim - strip, y: ink.minY, width: strip, height: ink.height)]
            .map { $0.intersection(CGRect(origin: .zero, size: size)) }.filter { !$0.isNull && $0.width >= 1 }
        let pictured = panel.width < ink.width + paragraph.size && !sides.isEmpty
            && bitmap.map { bitmap in sides.allSatisfy { !ColorSampler.isPlain(bitmap, rect: $0) } } ?? false
        paragraphs[index].pictured = pictured

        let column = paragraph.columnSpan
        var left = max(paragraph.size * 0.25, min(ink.minX - most, column.lowerBound))
        var right = min(size.width - paragraph.size * 0.25, max(ink.maxX + most, column.upperBound))
        if !pictured {
            left = max(left, panel.minX + rim)
            right = min(right, panel.maxX - rim)
        }
        for (other, beside) in paragraphs.enumerated() where other != index {
            guard beside.ink.minY < ink.maxY, ink.minY < beside.ink.maxY else { continue }
            if beside.ink.minX >= ink.maxX {
                let own = column.upperBound + gap < beside.ink.minX ? max(ink.maxX, column.upperBound) : ink.maxX
                right = min(right, (own + beside.ink.minX - gap) / 2)
            } else if beside.ink.maxX <= ink.minX {
                let own = beside.ink.maxX + gap < column.lowerBound ? min(ink.minX, column.lowerBound) : ink.minX
                left = max(left, (beside.ink.maxX + own + gap) / 2)
            }
        }
        left = min(left, ink.minX)
        right = max(right, ink.maxX)
        paragraphs[index].reach = left...right

        // A button: a small panel of its own colour, the label in the middle of it.
        if !pictured, paragraph.lineCount == 1, panel.width <= ink.width + paragraph.size * 6,
           panel.height <= ink.height + paragraph.size * 2, abs(ink.midX - panel.midX) <= panel.width * 0.15 {
            paragraphs[index].edge = .centre
            paragraphs[index].anchor = panel.midX
        }

        let firstRow = Int(ink.minY), lastRow = max(Int(ink.minY), Int(ink.maxY) - 1)
        let start = Int(ink.maxY + rim)
        let deepest = min(Int(size.height) - 1, Int(ink.maxY + down), pictured ? .max : Int(panel.maxY - rim))
        let open = start > deepest ? CGFloat(start) : min(size.height - paragraph.size * 0.25, CGFloat(deepest))
        guard let blank, !pictured else {
            paragraphs[index].room = left...right
            paragraphs[index].depths = Array(repeating: open, count: max(0, Int(right) - Int(left.rounded(.up)) + 1))
            return
        }
        // Out to the first thing drawn in its rows, past the anti-aliased rim of its own ink.
        let margin = paragraph.size * 0.15
        var cleanRight = right
        if let x = blank.first(0, columns: Int(ink.maxX + rim)...max(Int(ink.maxX + rim), Int(right)),
                               rows: firstRow...lastRow) {
            cleanRight = max(ink.maxX, CGFloat(x) - margin)
        }
        var cleanLeft = left
        if let x = blank.last(0, columns: min(Int(left.rounded(.up)), Int(ink.minX - rim))...Int(ink.minX - rim),
                              rows: firstRow...lastRow) {
            cleanLeft = min(ink.minX, CGFloat(x + 1) + margin)
        }
        paragraphs[index].room = cleanLeft...cleanRight

        // Below, column by column, as far as a translation could want.
        let first = Int(cleanLeft.rounded(.up)), last = Int(cleanRight.rounded(.down))
        paragraphs[index].depths = first <= last ? (first...last).map { x in
            guard start <= deepest else { return ink.maxY }
            guard let y = blank.first(0, column: x, rows: start...deepest) else { return open }
            return max(ink.maxY, CGFloat(y) - gap)
        } : []
    }

    /// Rows of single lines side by side on one panel, close together and with nothing
    /// drawn between them — a toolbar, a menu bar, tabs — each left to right.
    private mutating func findRows() {
        let lines = paragraphs.indices.filter { paragraphs[$0].lineCount == 1 && !paragraphs[$0].pictured }
        var pairs: [(Int, Int)] = []
        for left in lines {
            for right in lines {
                let a = paragraphs[left], b = paragraphs[right], size = max(a.size, b.size)
                guard b.ink.minX >= a.ink.maxX, b.ink.minX - a.ink.maxX <= size * 3,
                      min(a.ink.maxY, b.ink.maxY) - max(a.ink.minY, b.ink.minY) >= min(a.ink.height, b.ink.height) / 2,
                      a.panel.contains(CGPoint(x: b.ink.midX, y: b.ink.midY)),
                      b.panel.contains(CGPoint(x: a.ink.midX, y: a.ink.midY)),
                      b.room.lowerBound - a.room.upperBound <= size * Self.spacing + 2
                else { continue }
                pairs.append((left, right))
            }
        }
        rows = Self.groups(paragraphs.count, joining: pairs).filter { $0.count > 1 }
            .map { $0.sorted { paragraphs[$0].ink.minX < paragraphs[$1].ink.minX } }
    }

    // MARK: Helpers

    private static func isRightToLeft(_ text: String) -> Bool {
        var rightToLeft = 0, leftToRight = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rightToLeft += 1
            default: leftToRight += 1
            }
        }
        return rightToLeft > leftToRight
    }

    /// Whether `text` is mostly ideographs, kana or Hangul.
    private static func isDense(_ text: String) -> Bool {
        var dense = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0x20000...0x2FFFF: dense += 1
            default: other += 1
            }
        }
        return dense > other
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// The value with as much weight below it as above.
    private static func median(_ values: [(value: CGFloat, weight: CGFloat)]) -> CGFloat? {
        var remaining = values.reduce(0) { $0 + $1.weight } / 2
        for item in values.sorted(by: { $0.value < $1.value }) {
            remaining -= item.weight
            if remaining <= 0 { return item.value }
        }
        return values.last?.value
    }

    /// `0..<count` split into the groups `pairs` join, each in order, by their first.
    private static func groups(_ count: Int, joining pairs: [(Int, Int)]) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for (a, b) in pairs {
            parent[root(b)] = root(a)
        }
        return Dictionary(grouping: 0..<count, by: root).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}
