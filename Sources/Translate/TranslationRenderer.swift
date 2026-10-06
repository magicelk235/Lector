import AppKit
import LectorKit

/// Paints translated paragraphs over a capture and records where every word landed,
/// so the result can be picked from exactly like recognised text.
///
/// Each paragraph covers its original in the page's background colour and is written in
/// its text colour and weight, at the size its type was on the capture (`Page`) — one
/// size for every paragraph whose type was one size, so a menu stays one menu and a
/// heading stays above its body. A translation longer than its original first runs on
/// into the empty page beside it, out from its column's edge, and below it — never over
/// another paragraph's text; then it is set smaller, but never below `smallest` of its
/// size; only then does it leave its column's edge or cover what else is drawn on the
/// page, and past that it is cut short with an ellipsis, every word still there to copy.
///
/// It keeps its column's edge: left-aligned text starts where its column did, centred
/// text stays centred, and a column turned into a language written the other way —
/// English into Hebrew — reads from one shared edge, as that language's own pages do.
/// Labels side by side in a row — a toolbar, a menu bar — flow along it: each starts
/// where its original did, or past the translation before it, so a longer one takes the
/// empty row beyond rather than shrinking past its neighbours or being cut short.
///
/// One renderer serves one capture and keeps what doesn't change from one paint to the
/// next: the measured page, and each paragraph's layout for the translation it was last
/// given. The overlay repaints as each paragraph arrives, so on a page of sixty
/// paragraphs a paint lays out the one that changed rather than all sixty again.
final class TranslationRenderer {
    struct Rendering {
        /// Same pixel size as the capture.
        let image: CGImage
        /// Word and paragraph rects in `image`'s pixels, top-left origin. One line per
        /// paragraph, so a copy across a wrap doesn't break the sentence.
        let text: RecognizedText
    }

    /// The smallest share of its original size a translation is set at. Smaller, type
    /// stops being easy to read, so a translation with no more room is cut short instead.
    static let smallest: CGFloat = 0.8

    private let capture: CGImage
    private let original: RecognizedText
    private let blocks: [Paragraphs.Block]
    private let rightToLeft: Bool
    /// False for live translation: only the translated paragraphs are painted, on
    /// transparency, over the screen itself rather than a copy of it.
    private let paintsCapture: Bool
    private lazy var page = Page(capture: capture, original: original, blocks: blocks)
    /// Each paragraph's latest translation, painted or not: sizes come from all of them,
    /// so a paragraph taken off and put back doesn't resize the rest.
    private var latest: [String?]
    /// Per paragraph, the largest share of its role's size its latest translation fits.
    private var scales: [CGFloat?]
    /// Per paragraph, its latest translation as set.
    private var fitted: [Setting?]
    /// Per row of the page, the largest share of its members' roles' sizes at which their
    /// latest translations flow along it, nil if at none; dropped when one of them changes.
    private var rowScales: [Int: CGFloat?] = [:]
    /// Each paragraph's role's size.
    private lazy var roleSizes = page.roles.reduce(into: [CGFloat](repeating: 0, count: blocks.count)) { sizes, role in
        for index in role.members { sizes[index] = role.size }
    }
    /// The row each paragraph in one is in.
    private lazy var rowOf = page.rows.enumerated().reduce(into: [Int: Int]()) { rows, row in
        for index in row.element { rows[index] = row.offset }
    }

    init(capture: CGImage, original: RecognizedText, blocks: [Paragraphs.Block], rightToLeft: Bool,
         paintsCapture: Bool = true) {
        self.capture = capture
        self.original = original
        self.blocks = blocks
        self.rightToLeft = rightToLeft
        self.paintsCapture = paintsCapture
        latest = Array(repeating: nil, count: blocks.count)
        scales = Array(repeating: nil, count: blocks.count)
        fitted = Array(repeating: nil, count: blocks.count)
    }

    /// `translations` has one entry per block; a nil one is left as it is on screen, its
    /// original words still pickable — Apple translates a paragraph at a time, and the
    /// ones it hasn't reached yet shouldn't be dead.
    func render(_ translations: [String?]) -> Rendering? {
        guard blocks.count == translations.count else { return nil }
        for (index, translation) in translations.enumerated() {
            guard let translation, translation != latest[index] else { continue }
            latest[index] = translation
            scales[index] = nil
            if let row = rowOf[index] { rowScales[row] = nil }
        }
        let settings = settle(translations)

        let width = capture.width, height = capture.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if paintsCapture { context.draw(capture, in: bounds) } else { context.clear(bounds) }
        // Top-left origin from here on, matching the recognised text's pixel rects.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        var words: [RecognizedWord] = []
        var lines: [RecognizedLine] = []

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Every background first, then every paragraph's text: the patches are a little
        // bigger than their paragraphs, and painted in turn the next one's would cover
        // this one's descenders.
        for (index, setting) in settings.enumerated() where translations[index] != nil {
            guard let setting else { continue }
            page.paragraphs[index].colors.background.setFill()
            patch(setting, at: index).intersection(bounds).fill()
        }
        for (index, block) in blocks.enumerated() {
            let start = words.count
            guard translations[index] != nil, let setting = settings[index] else {
                for line in block.lines where original.lines.indices.contains(line) {
                    for index in original.lines[line].wordRange {
                        let word = original.words[index]
                        words.append(RecognizedWord(text: word.text, rect: word.rect, lineIndex: lines.count))
                    }
                }
                lines.append(RecognizedLine(text: block.text, rect: block.rect, wordRange: start..<words.count))
                continue
            }
            let layout = setting.layout, origin = setting.origin
            layout.manager.drawGlyphs(forGlyphRange: layout.glyphs, at: origin)
            for word in layout.words {
                words.append(RecognizedWord(text: word.text, rect: word.rect.offsetBy(dx: origin.x, dy: origin.y),
                                            lineIndex: lines.count))
            }
            lines.append(RecognizedLine(text: layout.text, rect: layout.used.offsetBy(dx: origin.x, dy: origin.y),
                                        wordRange: start..<words.count))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return Rendering(image: image, text: RecognizedText(words: words, lines: lines))
    }

    // MARK: Setting each paragraph

    /// A translation set in a frame.
    private struct Setting {
        let layout: Layout
        /// Where the layout's top left goes in the capture.
        let origin: CGPoint
        let size: CGFloat
        /// Where across the capture its lines may go: as far as its fit was checked.
        let span: ClosedRange<CGFloat>

        /// Where its lines can end, moved along `span`: on their right, right to left, and
        /// on their left otherwise.
        func ends(rightToLeft: Bool) -> ClosedRange<CGFloat> {
            let used = layout.used.width
            return rightToLeft ? span.lowerBound + used...max(span.lowerBound + used, span.upperBound)
                : span.lowerBound...max(span.lowerBound, span.upperBound - used)
        }

        /// The same lines moved along `span` to end at `edge`, or as near it as they can.
        func sliding(to edge: CGFloat, rightToLeft: Bool) -> Setting {
            let reach = ends(rightToLeft: rightToLeft)
            let end = origin.x + (rightToLeft ? layout.used.maxX : layout.used.minX)
            let shift = min(max(edge, reach.lowerBound), reach.upperBound) - end
            return Setting(layout: layout, origin: CGPoint(x: origin.x + shift, y: origin.y), size: size, span: span)
        }
    }

    /// Every paragraph that has a translation, set at its role's size. A column turned
    /// into a language written the other way is fitted into all the room around it, then
    /// set against one edge: its other one, where its longest lines ended, or past it as
    /// far as its widest translation needs — as near that as every one of them can go. A
    /// row's labels flow along it, where they fit so; nothing reaches an original that
    /// `translations` leaves showing.
    private func settle(_ translations: [String?]) -> [Setting?] {
        let sizes = typeSizes()
        var settings = blocks.indices.map { index in latest[index].map { setting($0, at: index, size: sizes[index]) } }
        for column in page.columns {
            let turned = column.compactMap { index in
                settings[index].flatMap { alignment(of: index).turned ? (index: index, setting: $0) : nil }
            }
            guard let first = turned.first else { continue }
            let paragraph = page.paragraphs[first.index]
            let widest = turned.map(\.setting.layout.used.width).max() ?? 0
            let wanted = rightToLeft ? max(paragraph.columnSpan.upperBound, paragraph.anchor + widest)
                : min(paragraph.columnSpan.lowerBound, paragraph.anchor - widest)
            let ends = turned.map { $0.setting.ends(rightToLeft: rightToLeft) }
            let low = ends.map(\.lowerBound).max() ?? wanted, high = ends.map(\.upperBound).min() ?? wanted
            let edge = low <= high ? min(max(wanted, low), high) : wanted
            for (index, setting) in turned {
                settings[index] = setting.sliding(to: edge, rightToLeft: rightToLeft)
            }
        }
        for (number, row) in page.rows.enumerated() where rowScale(number) != nil {
            guard let flowed = flow(row, sizes: { sizes[$0] }, showing: { translations[$0] != nil }) else { continue }
            for (index, setting) in flowed { settings[index] = setting }
        }
        return settings
    }

    /// Each paragraph's type size: its role's — the size its type was, one for every
    /// paragraph of that size — as far down as the role's longest translation needs, and
    /// no smaller than a smaller role's, so a heading never ends up below its body. A
    /// row's labels need what the whole row needs to flow along it.
    private func typeSizes() -> [CGFloat] {
        var sizes = [CGFloat](repeating: 0, count: blocks.count)
        var smaller: CGFloat = 0
        for role in page.roles {
            let scale = role.members.compactMap { index in
                latest[index].map { text in
                    rowOf[index].flatMap { rowScale($0) } ?? scale(of: text, at: index, size: role.size)
                }
            }.min() ?? 1
            let size = max(role.size * scale, smaller)
            for index in role.members { sizes[index] = size }
            smaller = size
        }
        return sizes
    }

    /// The largest share of `size` down to `smallest` at which `text` fits paragraph
    /// `index`'s room out from its column's edge, or `smallest` if it fits at none.
    private func scale(of text: String, at index: Int, size: CGFloat) -> CGFloat {
        if let known = scales[index] { return known }
        var scale: CGFloat = 1
        if frame(text, at: index, size: size, reaching: .outward) == nil {
            var low = Self.smallest, high: CGFloat = 1
            if frame(text, at: index, size: size * low, reaching: .outward) != nil {
                for _ in 0..<5 {
                    let middle = (low + high) / 2
                    if frame(text, at: index, size: size * middle, reaching: .outward) != nil {
                        low = middle
                    } else {
                        high = middle
                    }
                }
            }
            scale = low
        }
        scales[index] = scale
        return scale
    }

    /// The largest share of its members' roles' sizes, down to `smallest`, at which row
    /// `number`'s latest translations flow along it; nil if at none.
    private func rowScale(_ number: Int) -> CGFloat? {
        if let known = rowScales[number] { return known }
        let row = page.rows[number]
        func flows(_ scale: CGFloat) -> Bool {
            flow(row, sizes: { roleSizes[$0] * scale }, showing: { latest[$0] != nil }) != nil
        }
        var scale: CGFloat?
        if flows(1) {
            scale = 1
        } else if flows(Self.smallest) {
            var low = Self.smallest, high: CGFloat = 1
            for _ in 0..<5 {
                let middle = (low + high) / 2
                if flows(middle) {
                    low = middle
                } else {
                    high = middle
                }
            }
            scale = low
        }
        rowScales[number] = .some(scale)
        return scale
    }

    /// A row's translations, each on one line at its size in `sizes`, flowed along the
    /// row: each starts where it would on its own, or past the one before it with as much
    /// room between them as their originals had, and the last ends inside the row's room.
    /// A member not `showing` its translation keeps its original, which nothing may reach.
    /// Nil where the row doesn't take them so.
    private func flow(_ row: [Int], sizes: (Int) -> CGFloat, showing: (Int) -> Bool) -> [Int: Setting]? {
        let bounds = page.paragraphs[row[0]].room.lowerBound...page.paragraphs[row[row.count - 1]].room.upperBound
        var flowed: [Int: Setting] = [:], reached = bounds.lowerBound
        for (position, index) in row.enumerated() {
            let paragraph = page.paragraphs[index]
            // The originals' room before the next, never less than text's spacing.
            let next = position + 1 < row.count ? page.paragraphs[row[position + 1]].ink.minX : paragraph.ink.maxX
            let gap = max(paragraph.size * Page.spacing, next - paragraph.ink.maxX)
            guard showing(index), let text = latest[index] else {
                guard paragraph.ink.minX >= reached else { return nil }
                reached = paragraph.ink.maxX + gap
                continue
            }
            let size = sizes(index)
            let layout = self.layout(text, at: index, size: size, width: bounds.upperBound - bounds.lowerBound)
            guard layout.lineCount == 1 else { return nil }
            let width = layout.used.width, anchor = paragraph.anchor, column = paragraph.columnSpan
            // Where its line starts on its own: out from its edge, or a turned column's other one.
            let own: CGFloat = switch (paragraph.edge, alignment(of: index).turned) {
            case (.left, false): anchor
            case (.left, true): max(anchor, column.upperBound - width)
            case (.right, false): anchor - width
            case (.right, true): min(column.lowerBound, anchor - width)
            case (.centre, _): anchor - width / 2
            }
            let x = max(own, reached)
            guard x + width <= bounds.upperBound else { return nil }
            flowed[index] = Setting(layout: layout, origin: CGPoint(x: x - layout.used.minX,
                                                                    y: paragraph.baseline - layout.firstBaseline),
                                    size: size, span: x...(x + width))
            reached = x + width + gap
        }
        return flowed
    }

    /// Where a translation may go, widest last.
    private enum Reach {
        /// The empty page out from its column's edge: the way its lines run on — either
        /// way, for a column turned into a language written the other way.
        case outward
        /// All the empty page beside it, the column's edge given up.
        case across
        /// The page up to other text, past anything else drawn on it.
        case pastDrawings
    }

    private func setting(_ text: String, at index: Int, size: CGFloat) -> Setting {
        if let known = fitted[index], known.layout.text == text, known.size == size { return known }
        let setting = frame(text, at: index, size: size, reaching: .outward)
            ?? frame(text, at: index, size: size, reaching: .across)
            ?? frame(text, at: index, size: size, reaching: .pastDrawings)
            ?? cutShort(text, at: index, size: size)
        fitted[index] = setting
        return setting
    }

    /// `text` at `size` in the first frame within `reach` it fits, nil if none: in its
    /// own lines, then on to the page below them. A paragraph wraps at its column's
    /// width before it takes more.
    private func frame(_ text: String, at index: Int, size: CGFloat, reaching reach: Reach) -> Setting? {
        let paragraph = page.paragraphs[index]
        let limits = reach == .pastDrawings ? paragraph.reach : paragraph.room
        let widths = self.widths(at: index, within: limits)
        let candidates: [(width: CGFloat, grows: Bool)] = switch reach {
        case .outward:
            if let measured = widths.measured {
                [(measured, false), (measured, true), (widths.anchored, true)]
            } else {
                [(widths.anchored, false), (widths.anchored, true)]
            }
        case .across: [(widths.full, false), (widths.full, true)]
        case .pastDrawings: [(widths.anchored, false), (widths.anchored, true), (widths.full, false), (widths.full, true)]
        }
        var layouts: [CGFloat: Layout] = [:]
        for (number, candidate) in candidates.enumerated()
            where !candidates[..<number].contains(where: { $0 == candidate }) {
            let layout = layouts[candidate.width] ?? self.layout(text, at: index, size: size, width: candidate.width)
            layouts[candidate.width] = layout
            guard !layout.breaksWords else { continue }
            let span = self.span(candidate.width, at: index, within: limits)
            let fits = if candidate.grows {
                paragraph.baseline + layout.depth <= max(paragraph.bottom, reach == .pastDrawings
                    ? page.reachFloor(of: index, across: span) : page.floor(of: index, across: span))
            } else {
                layout.lineCount <= paragraph.lineCount
            }
            if fits {
                return Setting(layout: layout, origin: CGPoint(x: span.lowerBound, y: paragraph.baseline - layout.firstBaseline),
                               size: size, span: span)
            }
        }
        return nil
    }

    /// `text` cut short with an ellipsis, in as much of the page up to other text as it
    /// can have, in as many lines as fit — fewer, where more would break a word too wide
    /// for even that.
    private func cutShort(_ text: String, at index: Int, size: CGFloat) -> Setting {
        let paragraph = page.paragraphs[index]
        let limits = paragraph.reach
        let width = self.widths(at: index, within: limits).full
        let span = self.span(width, at: index, within: limits)
        let floor = max(paragraph.bottom, page.reachFloor(of: index, across: span))
        let one = layout(text, at: index, size: size, width: width, lines: 1)
        let pitch = lineHeight(of: index, size: size) ?? one.used.height
        var lines = max(1, 1 + Int(((floor - paragraph.baseline - one.depth) / pitch).rounded(.down)))
        var layout = lines == 1 ? one : self.layout(text, at: index, size: size, width: width, lines: lines)
        while layout.breaksWords, lines > 1 {
            lines -= 1
            layout = lines == 1 ? one : self.layout(text, at: index, size: size, width: width, lines: lines)
        }
        return Setting(layout: layout, origin: CGPoint(x: span.lowerBound, y: paragraph.baseline - layout.firstBaseline),
                       size: size, span: span)
    }

    /// The widths a paragraph's translation can be set in within `limits`: its column's,
    /// if its column has paragraphs — all of its column's, read from its other edge; out
    /// from its column's edge as far as it can go, or across all of `limits` for a column
    /// turned the other way; and all of `limits`.
    private func widths(at index: Int,
                        within limits: ClosedRange<CGFloat>) -> (measured: CGFloat?, anchored: CGFloat, full: CGFloat) {
        let paragraph = page.paragraphs[index], turned = alignment(of: index).turned
        let full = limits.upperBound - limits.lowerBound
        let outward: CGFloat = switch paragraph.edge {
        case .left: limits.upperBound - paragraph.anchor
        case .right: paragraph.anchor - limits.lowerBound
        case .centre: 2 * min(paragraph.anchor - limits.lowerBound, limits.upperBound - paragraph.anchor)
        }
        // Never narrower than its own lines.
        let reaching = min(full, max(turned ? full : outward, paragraph.ink.width))
        let column = paragraph.columnSpan.upperBound - paragraph.columnSpan.lowerBound
        let measure = turned ? paragraph.measure.map { max($0, column) } : paragraph.measure
        return (measure.map { min($0, reaching) }, reaching, full)
    }

    /// Where a frame `width` wide goes: out from its column's edge, or around its centre,
    /// moved in from past `limits` if it must be — anywhere across `limits` for a column
    /// turned the other way, until it is set against that column's other edge.
    private func span(_ width: CGFloat, at index: Int, within limits: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        guard !alignment(of: index).turned else { return limits }
        let paragraph = page.paragraphs[index]
        let start: CGFloat = switch paragraph.edge {
        case .left: paragraph.anchor
        case .right: paragraph.anchor - width
        case .centre: paragraph.anchor - width / 2
        }
        let x = max(limits.lowerBound, min(start, limits.upperBound - width))
        return x...(x + width)
    }

    /// How a paragraph's translation is aligned, and whether that turns it to the other
    /// edge of its column: text that started from its language's own edge starts from
    /// the translation's — Hebrew from the right — while centred text stays centred and
    /// text set against its language's edge stays against it.
    private func alignment(of index: Int) -> (alignment: NSTextAlignment, turned: Bool) {
        let paragraph = page.paragraphs[index]
        let start: NSTextAlignment = rightToLeft ? .right : .left
        switch paragraph.edge {
        case .centre: return (.center, false)
        case .left: return paragraph.rightToLeft ? (.left, false) : (start, rightToLeft)
        case .right: return paragraph.rightToLeft ? (start, !rightToLeft) : (.right, false)
        }
    }

    /// Baseline to baseline: the original's where it had more than one line, or its
    /// role's; nil for the font's own. Smaller type keeps the original's proportions.
    private func lineHeight(of index: Int, size: CGFloat) -> CGFloat? {
        let paragraph = page.paragraphs[index]
        let ratio: CGFloat? = if let pitch = paragraph.pitch {
            pitch / max(size, paragraph.size)
        } else {
            page.roles.first { $0.members.contains(index) }?.pitch
        }
        return ratio.map { min(2.5, max(1, $0)) * size }
    }

    private func layout(_ text: String, at index: Int, size: CGFloat, width: CGFloat, lines: Int = 0) -> Layout {
        let paragraph = page.paragraphs[index]
        return Layout(text, font: NSFont.systemFont(ofSize: size, weight: paragraph.weight),
                      color: paragraph.colors.ink, alignment: alignment(of: index).alignment,
                      rightToLeft: rightToLeft, width: width, lineHeight: lineHeight(of: index, size: size),
                      lines: lines)
    }

    /// What a paragraph's patch covers: its original, a little past its ink, and its
    /// translation — never past the edge of its own background, onto a page of another
    /// colour, unless the text is on a picture.
    private func patch(_ setting: Setting, at index: Int) -> CGRect {
        let paragraph = page.paragraphs[index]
        let margin = max(1.5, min(paragraph.size * 0.12, paragraph.clearance / 2))
        let translation = setting.layout.glyphBounds.offsetBy(dx: setting.origin.x, dy: setting.origin.y)
            .insetBy(dx: -setting.size * 0.12, dy: -setting.size * 0.06)
        let patch = paragraph.ink.insetBy(dx: -margin, dy: -margin).union(translation)
        return paragraph.pictured ? patch : patch.intersection(paragraph.panel)
    }

    /// One paragraph's translation laid out in a width, with every word's rect. Rects are
    /// relative to the layout's top left.
    private struct Layout {
        let text: String
        let manager: NSLayoutManager
        let glyphs: NSRange
        let words: [(text: String, rect: CGRect)]
        let used: CGRect
        /// The first line's baseline, from the top.
        let firstBaseline: CGFloat
        let lineCount: Int
        /// Roughly where its glyphs are: from the tops of the first line's capitals to
        /// the last line's descenders.
        let glyphBounds: CGRect
        /// A word too wide for the width was broken across lines.
        let breaksWords: Bool
        /// Owned here: the layout manager only holds the text weakly.
        private let storage: NSTextStorage

        /// From the first baseline to the bottom of the last line.
        var depth: CGFloat { used.maxY - firstBaseline }

        /// `lines` above 0 cuts the text short with an ellipsis after that many.
        init(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment, rightToLeft: Bool,
             width: CGFloat, lineHeight: CGFloat?, lines: Int) {
            self.text = text
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            self.storage = storage
            self.manager = manager
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            if lines > 0 {
                container.maximumNumberOfLines = lines
                container.lineBreakMode = .byTruncatingTail
            }
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            paragraph.lineBreakMode = .byWordWrapping
            if let lineHeight {
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
            }
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
            manager.ensureLayout(for: container)
            glyphs = manager.glyphRange(for: container)
            used = manager.usedRect(for: container)

            let string = text as NSString
            var count = 0, broken = false, first: CGFloat = 0, last: CGFloat = 0
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
                let baseline = rect.minY + manager.location(forGlyphAt: range.location).y
                if count == 0 {
                    first = baseline
                } else if Self.splitsWord(string, at: manager.characterIndexForGlyph(at: range.location)) {
                    broken = true
                }
                last = baseline
                count += 1
            }
            firstBaseline = first
            lineCount = count
            breaksWords = broken
            glyphBounds = CGRect(x: used.minX, y: first - font.pointSize * 0.8, width: used.width,
                                 height: last - first + font.pointSize * 1.05)

            // A line set taller than the font's own height has the extra above its
            // letters; a word's box leaves it out, so it hugs the word as OCR's do.
            let leading = lineHeight.map { max(0, $0 - manager.defaultLineHeight(for: font)) } ?? 0
            words = TranslationRenderer.tokens(in: text).compactMap { range in
                let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                // The rects a selection of just these characters would light up — for words
                // cut off by an ellipsis, the ellipsis. `boundingRect(forGlyphRange:)` is
                // wrong here: where right-to-left and left-to-right text meet a line break
                // it takes in the line's spare width, and the highlight lands off the word.
                var rect = CGRect.null
                manager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container) { piece, _ in
                    rect = rect.union(CGRect(x: piece.minX, y: piece.minY + leading, width: piece.width,
                                             height: max(0, piece.height - leading)))
                }
                return rect.isNull ? nil : (string.substring(with: range), rect)
            }
        }

        /// Whether a line starting at `index` cut a word in two: letters on both sides,
        /// in a script written with spaces between words.
        private static func splitsWord(_ string: NSString, at index: Int) -> Bool {
            guard index > 0, index < string.length,
                  let before = UnicodeScalar(string.character(at: index - 1)),
                  let after = UnicodeScalar(string.character(at: index))
            else { return false }
            let letters = CharacterSet.alphanumerics
            return letters.contains(before) && letters.contains(after)
                && !Paragraphs.isSpaceless(Character(before)) && !Paragraphs.isSpaceless(Character(after))
        }
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
