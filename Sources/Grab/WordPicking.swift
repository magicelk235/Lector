import CoreGraphics
import LectorKit

/// A contiguous run of words, in reading order, chosen by dragging across them —
/// the same model as selecting text in a document, so RTL and multi-column captures
/// behave the way the reader expects rather than the way the pixels happen to lie.
struct WordSelection: Equatable {
    var anchor: Int
    var focus: Int

    init(anchor: Int, focus: Int) {
        self.anchor = anchor
        self.focus = focus
    }

    init(word: Int) {
        self.init(anchor: word, focus: word)
    }

    var range: ClosedRange<Int> { min(anchor, focus)...max(anchor, focus) }

    static func all(in text: RecognizedText) -> WordSelection? {
        text.words.isEmpty ? nil : WordSelection(anchor: 0, focus: text.words.count - 1)
    }

    static func line(containing word: Int, in text: RecognizedText) -> WordSelection {
        let range = text.lines[text.words[word].lineIndex].wordRange
        return WordSelection(anchor: range.lowerBound, focus: range.upperBound - 1)
    }
}

/// What a copy puts on the pasteboard: the selected words as the paragraphs they're in,
/// not as the lines the screen happened to wrap them into. Lines of one paragraph are
/// joined the way `Paragraphs` joins them — a space, nothing between CJK or Thai, a
/// word broken by a hyphen made whole — and paragraphs keep a line break between them,
/// so pasting into a document gives sentences rather than "Vous\npouvez l'annuler".
enum CopiedText {
    /// `paragraphs` are runs of `text`'s line indices that make up one paragraph each;
    /// a line in none of them stands on its own.
    static func text(ofWords words: ClosedRange<Int>, in text: RecognizedText, paragraphs: [Range<Int>]) -> String {
        var paragraphOfLine = Array(text.lines.indices)
        for (number, lines) in paragraphs.enumerated() {
            for line in lines where paragraphOfLine.indices.contains(line) {
                paragraphOfLine[line] = text.lines.count + number
            }
        }

        var result: [String] = []
        var previousParagraph: Int?
        let selected = words.lowerBound..<(words.upperBound + 1)
        for (index, line) in text.lines.enumerated() {
            let chosen = line.wordRange.clamped(to: selected)
            guard !chosen.isEmpty else { continue }
            let piece = text.text(ofWords: chosen)
            if previousParagraph == paragraphOfLine[index], let earlier = result.popLast() {
                result.append(Paragraphs.join(earlier, piece))
            } else {
                result.append(piece)
            }
            previousParagraph = paragraphOfLine[index]
        }
        return result.joined(separator: "\n")
    }
}

enum WordHitTest {
    /// The word a pointer at `point` means, in the recognised image's pixel space.
    ///
    /// Never nil while there are words: a drag that wanders into the gap between two
    /// lines or past the end of one should still extend the selection, as it does in
    /// any text view. The nearest line is found first so a point just below a line
    /// doesn't jump to a word in a neighbouring column that happens to be closer.
    static func word(at point: CGPoint, in text: RecognizedText) -> Int? {
        guard let line = text.lines.indices.min(by: {
            lineDistance(point, text.lines[$0].rect) < lineDistance(point, text.lines[$1].rect)
        }) else { return nil }

        let words = text.lines[line].wordRange
        return words.min(by: {
            distance(point, text.words[$0].rect) < distance(point, text.words[$1].rect)
        })
    }

    /// Vertical distance dominates; horizontal only separates lines at the same height
    /// (columns), so it is scaled down rather than ignored.
    private static func lineDistance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        return dy * 4 + dx
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
