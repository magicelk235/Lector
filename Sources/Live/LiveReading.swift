import CoreGraphics
import LectorKit

/// A reading of a live region made ready to translate. Game dialogue and video
/// subtitles come back from the reader with things a page doesn't have:
///
/// - Lines without a letter: a video player's clock, a counter. There's nothing in them
///   to translate, and as they tick every reading would look like new text.
/// - The readings of kanji, set in small kana just above them (furigana). Read as lines
///   of their own they would be translated as words of their own.
/// - Japanese and Chinese set in phrases a space or two apart, as games for children
///   are: the reader returns each phrase of a row as a line, in no reliable order, and
///   each would be translated alone. The phrases of a row become one line again.
enum LiveReading {
    static func cleaned(_ text: RecognizedText) -> RecognizedText {
        var lines = text.lines.map { line in
            Line(fragments: [Fragment(text: line.text, rect: line.rect,
                                      words: line.wordRange.filter(text.words.indices.contains).map { text.words[$0] })])
        }
        lines.removeAll { !$0.text.contains(where: \.isLetter) }
        let bases = lines
        lines.removeAll { line in bases.contains { isReading(line, of: $0) } }

        var joined: [Line] = []
        var taken = Set<Int>()
        for index in lines.indices where !taken.contains(index) {
            taken.insert(index)
            var line = lines[index]
            while let next = lines.indices.first(where: { !taken.contains($0) && line.adjoins(lines[$0]) }) {
                taken.insert(next)
                line.fragments += lines[next].fragments
            }
            joined.append(line)
        }

        var words: [RecognizedWord] = []
        var recognized: [RecognizedLine] = []
        for line in joined {
            let start = words.count
            for word in line.ordered.flatMap(\.words) {
                words.append(RecognizedWord(text: word.text, rect: word.rect, lineIndex: recognized.count))
            }
            recognized.append(RecognizedLine(text: line.text, rect: line.rect, wordRange: start..<words.count))
        }
        return RecognizedText(words: words, lines: recognized)
    }

    private struct Fragment {
        let text: String
        let rect: CGRect
        let words: [RecognizedWord]
    }

    private struct Line {
        var fragments: [Fragment]

        var ordered: [Fragment] { fragments.sorted { $0.rect.minX < $1.rect.minX } }
        var text: String { ordered.dropFirst().reduce(ordered[0].text) { Paragraphs.join($0, $1.text) } }
        var rect: CGRect { fragments.dropFirst().reduce(fragments[0].rect) { $0.union($1.rect) } }

        /// The next phrase of the same row: beside it, at its height, at most a couple of
        /// characters away, and both written without spaces.
        func adjoins(_ other: Line) -> Bool {
            let a = rect, b = other.rect
            let height = max(a.height, b.height)
            let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let gap = max(b.minX - a.maxX, a.minX - b.maxX)
            return shared >= min(a.height, b.height) * 0.6
                && height / max(min(a.height, b.height), 1) < 1.35
                && gap > -height * 0.3 && gap <= height * 2.2
                && LiveReading.isSpaceless(text) && LiveReading.isSpaceless(other.text)
        }
    }

    /// Mostly letters of a script written without spaces.
    private static func isSpaceless(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && letters.filter(Paragraphs.isSpaceless).count * 2 >= letters.count
    }

    /// Small kana right above a line of Japanese, within its width: how a kanji's
    /// reading is printed.
    private static func isReading(_ line: Line, of base: Line) -> Bool {
        let small = line.rect, below = base.rect
        let letters = line.text.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(isKana), base.text.contains(where: isKanji) else { return false }
        return small.height <= below.height * 0.6
            && small.maxY <= below.minY + below.height * 0.3
            && below.minY - small.maxY <= small.height
            && small.midX >= below.minX && small.midX <= below.maxX
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) }
    }

    private static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }
}
