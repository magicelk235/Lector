import CoreGraphics
import CoreVideo
import Foundation

/// A frame of a watched region boiled down to the average brightness of a coarse grid
/// of cells: enough to tell that text appeared, went or changed, for a fraction of a
/// millisecond a frame. Comparing two of these is how live translation decides whether
/// there is anything to read, so a screen that isn't changing costs next to nothing.
struct FrameSignature: Equatable, Sendable {
    static let columns = 48
    /// A cell has changed when its brightness moved by more than this, out of 255:
    /// above what video compression and a cursor's shadow leave behind, far below what
    /// a word appearing in it does.
    static let threshold = 6

    let rows: Int
    let cells: [UInt8]

    init(cells: [UInt8], rows: Int) {
        self.cells = cells
        self.rows = rows
    }

    /// From a 32-bit BGRA frame, as ScreenCaptureKit delivers them. Every other pixel
    /// of every other row is enough: a glyph spans many.
    init?(_ pixels: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let columns = min(Self.columns, width)
        let rows = max(1, min(Self.columns, Int((Double(columns) * Double(height) / Double(width)).rounded())))
        var sums = [Int](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: height, by: 2) {
            let row = bytes + y * bytesPerRow
            let cellRow = min(rows - 1, y * rows / height) * columns
            for x in stride(from: 0, to: width, by: 2) {
                let pixel = row + x * 4
                // Rec. 601 luma from B, G, R.
                let luma = (Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8
                let cell = cellRow + min(columns - 1, x * columns / width)
                sums[cell] += luma
                counts[cell] += 1
            }
        }
        cells = zip(sums, counts).map { UInt8($0 / max($1, 1)) }
        self.rows = rows
    }

    /// How many cells differ from `other`'s; all of them when the grids don't match.
    func changedCells(from other: FrameSignature) -> Int {
        guard cells.count == other.cells.count else { return cells.count }
        return zip(cells, other.cells).filter { abs(Int($0) - Int($1)) > Self.threshold }.count
    }

    /// The cells that differ from `other`'s; all of them when the grids don't match.
    func changes(from other: FrameSignature) -> FrameArea {
        let columns = cells.count / max(rows, 1)
        guard cells.count == other.cells.count else {
            return FrameArea(columns: columns, rows: rows, cells: Set(cells.indices))
        }
        return FrameArea(columns: columns, rows: rows, cells: Set(cells.indices.filter {
            abs(Int(cells[$0]) - Int(other.cells[$0])) > Self.threshold
        }))
    }
}

/// Some cells of a frame's grid: a part of the frame.
struct FrameArea: Equatable, Sendable {
    static let none = FrameArea(columns: 0, rows: 0, cells: [])

    let columns: Int
    let rows: Int
    let cells: Set<Int>

    var isEmpty: Bool { cells.isEmpty }

    /// Whether any of it lies between `top` and `bottom` of a frame `height` pixels tall.
    /// A row counts when at least half of it, or of the span if that's the thinner, is
    /// inside: a translation set a little taller than its line grazes the rows around
    /// it, and what moves there — the video above a subtitle — isn't its text changing.
    func reaches(from top: CGFloat, to bottom: CGFloat, height: CGFloat) -> Bool {
        guard columns > 0, rows > 0 else { return false }
        let row = height / CGFloat(rows)
        let enough = min(row, bottom - top) / 2
        return cells.contains { cell in
            let upper = CGFloat(cell / columns) * row
            return min(bottom, upper + row) - max(top, upper) >= enough
        }
    }
}

/// Decides when a watched region has changed enough, and for long enough, to read again.
///
/// The first frame is read at once. After that, a frame unlike the one last read starts
/// a change, which is read as soon as the picture holds still for `settle` — the end of
/// a fade, a scroll, a line of typing — or, if it never does, after `patience`: video
/// behind subtitles never stops moving. A frame that goes back to how the screen looked
/// when last read ends the change without a reading (a blinking caret, a hover going away).
///
/// Moving pictures that come back with the same text are read less and less often, up
/// to `slowest` apart, until the text changes again. Subtitles last two or three seconds;
/// a translation can't change before the line under it is read, so a new one shows
/// within that much, and the old one stays over it no longer.
///
/// Where a change came to a picture that had been holding still — a dialogue box, a
/// page — it is new text until read (`unread`), and the translation over it comes off
/// at once rather than after the reading.
struct ChangeDetector {
    enum Decision: Equatable {
        /// Nothing to read.
        case idle
        /// Ask again at this time, unless another frame comes first.
        case wait(until: TimeInterval)
        case read
    }

    private let settle: TimeInterval
    private let firstPatience: TimeInterval
    private let slowest: TimeInterval
    private var patience: TimeInterval
    /// The picture last read, which later frames are measured against.
    private var reference: FrameSignature?
    private var latest: FrameSignature?
    /// When the picture first differed from `reference`, while it does.
    private var changeStart: TimeInterval?
    private var lastMotion: TimeInterval = 0
    /// The change under way came to a picture that had been holding still.
    private var changeFromStill = false

    init(settle: TimeInterval = 0.25, patience: TimeInterval = 0.5, slowest: TimeInterval = 0.75) {
        self.settle = settle
        firstPatience = patience
        self.slowest = slowest
        self.patience = patience
    }

    /// Where the screen no longer shows what was last read, while that can be known
    /// before reading it again: when the change came to a still picture, whatever text is
    /// there now isn't what the translation over it says. A picture that moves by itself,
    /// video behind subtitles, changes whether its text does or not; there only a
    /// reading tells, and this stays empty.
    var unread: FrameArea {
        guard changeFromStill, let latest, let reference else { return .none }
        return latest.changes(from: reference)
    }

    mutating func observe(_ frame: FrameSignature, at time: TimeInterval) -> Decision {
        // The first frame says nothing about whether the picture moves.
        let wasStill = latest != nil && time - lastMotion >= settle
        if let latest {
            if frame.changedCells(from: latest) > 0 { lastMotion = time }
        } else {
            lastMotion = time
        }
        latest = frame
        guard let reference else { return .read }
        guard frame.changedCells(from: reference) > 0 else {
            changeStart = nil
            changeFromStill = false
            return .idle
        }
        if changeStart == nil {
            changeStart = time
            lastMotion = time
            changeFromStill = wasStill
        }
        return decide(at: time)
    }

    /// For a `wait` coming due with no new frame since.
    mutating func tick(at time: TimeInterval) -> Decision {
        decide(at: time)
    }

    /// `frame` has been read. `textChanged` is whether the reading found different text
    /// from the one before: when moving pictures keep coming back with the same text,
    /// the reader is patient for longer.
    mutating func didRead(_ frame: FrameSignature, at time: TimeInterval, textChanged: Bool) {
        reference = frame
        patience = textChanged ? firstPatience : min(slowest, patience * 1.25)
        // What arrived while it was being read may already be different again: on a
        // still picture, that's new text again.
        if let latest, latest.changedCells(from: frame) > 0 {
            changeStart = time
        } else {
            changeStart = nil
            changeFromStill = false
        }
    }

    private mutating func decide(at time: TimeInterval) -> Decision {
        guard let start = changeStart else { return .idle }
        let still = lastMotion + settle, overdue = start + patience
        if time >= still { return .read }
        guard time < overdue else {
            // Read while it still moves: what moves here moves by itself.
            changeFromStill = false
            return .read
        }
        return .wait(until: min(still, overdue))
    }
}

/// What can be shown again from the last reading of a live region instead of being
/// translated again.
///
/// The same text, wherever it moved to: a scroll isn't new text. And text in the same
/// place that differs only by the odd character: the reader's noise when it reads a
/// subtitle again over moving video — a wrong kana, a stray mark after a name, a run of
/// dots read as a different run of dots. Punctuation and case are left out of the
/// comparison altogether. Lines too short to tell a misread letter from a different
/// word are only ever the same when identical: "Yes" and "Yet" are different lines.
enum LiveDiff {
    /// `translations` as they can still be painted over the paragraphs in `areas` on a
    /// frame `size` big. One whose band across the frame has changed since it was read —
    /// its own line, or a longer one running on past its end — comes off until it's read
    /// again: a translation never stays over text it doesn't say.
    static func paintable(_ translations: [String?], over areas: [CGRect], unread: FrameArea,
                          in size: CGSize) -> [String?] {
        guard !unread.isEmpty else { return translations }
        return zip(translations, areas).map { translation, area in
            unread.reaches(from: area.minY, to: area.maxY, height: size.height) ? nil : translation
        }
    }

    struct Shown: Equatable {
        let text: String
        /// Where it was, in the frame's pixels.
        let rect: CGRect
        let translation: String
    }

    /// From this many letters a line may differ by one and still be the same line.
    static let shortestMisread = 5
    /// From this many letters a line may differ by `1 - alike` of them.
    static let shortest = 20
    static let alike = 0.92

    /// For each of `paragraphs`, the translation it can show again, or nil to translate.
    static func reuse(_ paragraphs: [(text: String, rect: CGRect)], from shown: [Shown]) -> [String?] {
        let known = Dictionary(shown.map { (key($0.text), $0.translation) }, uniquingKeysWith: { first, _ in first })
        return paragraphs.map { paragraph in
            let text = key(paragraph.text)
            if let same = known[text] { return same }
            return shown.first { old in
                old.rect.intersects(paragraph.rect) && misread(text, as: key(old.text))
            }?.translation
        }
    }

    /// How alike a line must be to what was painted in its place for that to stay up
    /// while the line is translated again: the same line misread worse than `reuse`
    /// lets pass, not the next one.
    static let standingIn = 0.6

    /// For each of `paragraphs`, what can stay painted over it until its own translation
    /// lands: the translation of the line in its place, if that line was nearly it.
    static func standIns(_ paragraphs: [(text: String, rect: CGRect)], from shown: [Shown]) -> [String?] {
        paragraphs.map { paragraph in
            let text = Array(key(paragraph.text))
            return shown.first { old in
                let before = Array(key(old.text))
                let longer = max(text.count, before.count)
                guard !old.translation.isEmpty, longer > 0, old.rect.intersects(paragraph.rect),
                      Double(min(text.count, before.count)) >= Double(longer) * standingIn
                else { return false }
                return 1 - Double(distance(text, before)) / Double(longer) >= standingIn
            }?.translation
        }
    }

    /// Whether the lines of a new reading are those of the one before, each in its
    /// place give or take a misread letter. Then nothing on screen is new, however the
    /// lines would be grouped into paragraphs this time, and what's painted stays.
    static func sameReading(_ lines: [(text: String, rect: CGRect)], as before: [(text: String, rect: CGRect)]) -> Bool {
        guard lines.count == before.count else { return false }
        var left = before.map { (key: key($0.text), rect: $0.rect) }
        for line in lines {
            let text = key(line.text)
            guard let match = left.firstIndex(where: { $0.rect.intersects(line.rect) && misread(text, as: $0.key) })
            else { return false }
            left.remove(at: match)
        }
        return true
    }

    /// What's compared: the letters and digits, in lowercase. A line with none is
    /// compared as it is.
    static func key(_ text: String) -> String {
        let letters = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        return letters.isEmpty ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ") : letters
    }

    /// Whether `a` is `b` with no more misread letters than a line that long can have.
    static func misread(_ a: String, as b: String) -> Bool {
        let a = Array(a), b = Array(b)
        let longer = max(a.count, b.count)
        let allowed = longer >= shortest ? Int(Double(longer) * (1 - alike)) : longer >= shortestMisread ? 1 : 0
        guard allowed > 0, abs(a.count - b.count) <= allowed else { return a == b }
        return distance(a, b) <= allowed
    }

    /// The fewest letters to change, add or drop to make `a` into `b`.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
