import CoreGraphics
import HoverLensKit

/// Rebuilds sentences that OCR split into visual lines, so a wrapped paragraph is
/// translated as one thought instead of line fragments — while a menu, list or UI
/// labels stay one item per line.
///
/// A line runs on into the next when it is nearly as wide as the widest line (it
/// wrapped rather than ended), doesn't end in terminal punctuation, and the next line
/// sits directly beneath it in the same column at the same size and doesn't start
/// with a capital — a wrapped sentence almost never does, while menu items and list
/// entries almost always do. Scripts without case fall back on the geometry alone.
enum Paragraphs {
    /// One paragraph and where it sits in the recognised image.
    struct Block: Equatable {
        var text: String
        /// Union of its lines, in the image's pixels (top-left origin).
        var rect: CGRect
        /// Height of one of its lines, in pixels.
        var lineHeight: CGFloat
        /// Which of the recognised text's lines it was built from.
        var lines: Range<Int>
    }

    static func split(_ text: RecognizedText) -> [String] {
        blocks(text).map(\.text)
    }

    static func blocks(_ text: RecognizedText) -> [Block] {
        let lines = text.lines
        guard !lines.isEmpty else { return [] }

        let widest = lines.map(\.rect.width).max() ?? 0
        var blocks: [Block] = []
        var current = Block(text: lines[0].text, rect: lines[0].rect, lineHeight: lines[0].rect.height, lines: 0..<1)

        for index in 1..<lines.count {
            let earlier = lines[index - 1], later = lines[index]
            if continues(earlier, into: later, widest: widest) {
                current.text = join(current.text, later.text)
                current.rect = current.rect.union(later.rect)
                current.lineHeight = max(current.lineHeight, later.rect.height)
                current.lines = current.lines.lowerBound..<(index + 1)
            } else {
                blocks.append(current)
                current = Block(text: later.text, rect: later.rect, lineHeight: later.rect.height, lines: index..<(index + 1))
            }
        }
        blocks.append(current)
        return blocks.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func continues(_ earlier: RecognizedLine, into later: RecognizedLine, widest: CGFloat) -> Bool {
        let a = earlier.rect, b = later.rect
        let height = max(a.height, b.height)
        guard height > 0 else { return false }

        let wrapped = a.width >= widest * 0.75
        let adjacent = b.minY >= a.midY && b.minY - a.maxY < height * 0.8
        let sameColumn = a.minX < b.maxX && b.minX < a.maxX
        let sameSize = max(a.height, b.height) / max(min(a.height, b.height), 1) < 1.5
        let ended = earlier.text.last.map { terminal.contains($0) } ?? true
        let startsNew = later.text.first?.isUppercase == true

        return wrapped && adjacent && sameColumn && sameSize && !ended && !startsNew
    }

    /// Joins with a space, except where the script doesn't use them (CJK, Thai) or a
    /// word was hyphenated across the break.
    static func join(_ earlier: String, _ later: String) -> String {
        guard let last = earlier.last, let first = later.first else { return earlier + later }
        if last == "-", first.isLowercase {
            return String(earlier.dropLast()) + later
        }
        if isSpaceless(last) && isSpaceless(first) {
            return earlier + later
        }
        return earlier + " " + later
    }

    private static let terminal: Set<Character> = [".", "!", "?", ":", "。", "！", "？", "؟", "।", "…"]

    static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK ideographs
             0x3000...0x303F, 0xFF00...0xFFEF, // CJK punctuation, full-width forms
             0x0E00...0x0E7F, 0x0E80...0x0EFF, // Thai, Lao
             0x1000...0x109F, 0x1780...0x17FF: // Myanmar, Khmer
            return true
        default:
            return false
        }
    }
}
