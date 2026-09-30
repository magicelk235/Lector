import CoreGraphics

public struct RecognizedWord: Sendable, Equatable {
    public let text: String
    /// Pixel coordinates in the image that was read, top-left origin.
    public let rect: CGRect
    /// Index into `RecognizedText.lines`.
    public let lineIndex: Int

    public init(text: String, rect: CGRect, lineIndex: Int) {
        self.text = text
        self.rect = rect
        self.lineIndex = lineIndex
    }
}

public struct RecognizedLine: Sendable, Equatable {
    public let text: String
    /// Pixel coordinates in the image that was read, top-left origin.
    public let rect: CGRect
    /// Indices into `RecognizedText.words`.
    public let wordRange: Range<Int>

    public init(text: String, rect: CGRect, wordRange: Range<Int>) {
        self.text = text
        self.rect = rect
        self.wordRange = wordRange
    }
}

/// Everything read from one image, in reading order.
///
/// Words run in reading order within each line — right to left for Hebrew or Arabic,
/// which is also their logical order, so joined text pastes correctly — and lines run
/// top to bottom, column by column.
public struct RecognizedText: Sendable, Equatable {
    public let words: [RecognizedWord]
    public let lines: [RecognizedLine]

    public init(words: [RecognizedWord], lines: [RecognizedLine]) {
        self.words = words
        self.lines = lines
    }

    public static let empty = RecognizedText(words: [], lines: [])

    /// Lines joined with "\n".
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool { words.isEmpty }

    public var isSingleLine: Bool { lines.count == 1 }

    /// The selected words in reading order, lines separated by "\n". Words keep the
    /// spacing they had on screen where they were adjacent; otherwise they are joined
    /// with a space, or with nothing in scripts written without spaces.
    public func text(ofWords indices: some Sequence<Int>) -> String {
        let selected = Set(indices.filter(words.indices.contains))
        guard !selected.isEmpty else { return "" }

        var result: [String] = []
        for line in lines {
            let chosen = line.wordRange.filter(selected.contains)
            guard let first = chosen.first else { continue }
            let separators = separators(in: line)
            var text = words[first].text
            for (previous, index) in zip(chosen, chosen.dropFirst()) {
                text += index == previous + 1
                    ? separators[index - line.wordRange.lowerBound]
                    : Self.separator(between: words[previous].text, and: words[index].text)
                text += words[index].text
            }
            result.append(text)
        }
        return result.joined(separator: "\n")
    }

    /// What stands before each word of `line` in the line's own text: a space, or
    /// nothing. Found by locating the words in order; a word that cannot be found
    /// (text assembled by hand, say) falls back to the script rule.
    private func separators(in line: RecognizedLine) -> [String] {
        let text = line.text
        var cursor = text.startIndex
        var separators: [String] = []
        var previous: String?
        for index in line.wordRange {
            let word = words[index].text
            if let found = text.range(of: word, range: cursor..<text.endIndex) {
                let gap = text[cursor..<found.lowerBound]
                separators.append(previous == nil || gap.isEmpty ? "" : " ")
                cursor = found.upperBound
            } else {
                separators.append(previous.map { Self.separator(between: $0, and: word) } ?? "")
            }
            previous = word
        }
        return separators
    }

    /// A space between words, except where either side is written without spaces —
    /// Chinese, Japanese, Thai and their neighbours.
    static func separator(between earlier: String, and later: String) -> String {
        guard let last = earlier.unicodeScalars.last, let first = later.unicodeScalars.first else {
            return ""
        }
        return isUnspaced(last) || isUnspaced(first) ? "" : " "
    }

    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        Script.of(scalar)?.joinsWithoutSpaces ?? scalar.isUnspacedPunctuation
    }
}
