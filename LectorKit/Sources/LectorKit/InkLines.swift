import Accelerate
import CoreGraphics

/// A run of ink about one line tall: where a line of text may be.
struct InkLine: Equatable {
    /// In image pixels.
    let rect: CGRect
    /// The ink, as rects one grid cell tall, each spanning a row of ink cells and the
    /// gaps between letters and words.
    let runs: [CGRect]
    /// The part of this ink outside every one of the lines Vision read in `rects`, or
    /// nil when they take in all but a sliver. The parts left out may be anywhere: the
    /// "索" Vision left beside "検", or the second of two lines whose ink runs
    /// together.
    ///
    /// What is left out stretches up and down as far as the ink goes between the lines
    /// read above and below it: Vision's box for a line can take in the tops of the
    /// next, and a line cut short of its accents is read without them.
    func uncovered(by rects: [CGRect], minimumHeight: CGFloat) -> CGRect? {
        // Vision's boxes sit tight, leaving out the ends of words and accents.
        let read = rects.map { $0.insetBy(dx: -$0.height * 0.25, dy: -$0.height * 0.1) }
        var total: CGFloat = 0, missed: CGFloat = 0
        var box = CGRect.null
        for run in runs {
            total += run.width
            var x = run.minX
            let covering = read.filter { $0.minY <= run.midY && run.midY <= $0.maxY && $0.minX < run.maxX && run.minX < $0.maxX }
                .sorted { $0.minX < $1.minX }
            for rect in covering {
                if rect.minX > x {
                    missed += rect.minX - x
                    box = box.union(CGRect(x: x, y: run.minY, width: rect.minX - x, height: run.height))
                }
                x = max(x, rect.maxX)
            }
            if run.maxX > x {
                missed += run.maxX - x
                box = box.union(CGRect(x: x, y: run.minY, width: run.maxX - x, height: run.height))
            }
        }
        guard missed >= total * 0.25 else { return nil }
        let across = rects.filter { $0.minX < box.maxX && box.minX < $0.maxX }
        let top = across.map(\.maxY).filter { $0 <= box.midY }.max() ?? rect.minY
        let bottom = across.map(\.minY).filter { $0 >= box.midY }.min() ?? rect.maxY
        let minY = max(rect.minY, min(box.minY, top)), maxY = min(rect.maxY, max(box.maxY, bottom))
        guard maxY - minY >= minimumHeight else { return nil }
        return CGRect(x: box.minX, y: minY, width: box.width, height: maxY - minY)
    }
}

/// Where lines of text may be, found from the pixels alone.
///
/// Neither detector at hand finds every line of a screen. Vision's misses short
/// isolated words when they are small next to the image — of five CJK menu labels in a
/// 1104×361 capture it found one — and Tesseract's layout analysis drops a word drawn
/// as a single blob, such as "ملف". Screen text is crisp on a flat background, so a
/// line shows up plainly as a run of high-contrast cells; that is all this looks for.
/// It says where text may be, not that it is text: an icon passes too, and is left
/// for the engines to find nothing in.
enum InkLines {
    /// Runs of ink about one line tall, top to bottom.
    ///
    /// - Parameter textHeight: the typical line height on screen, which sets the grid
    ///   and the gaps that separate words (bridged) from columns (not bridged).
    static func find(in image: GrayImage, textHeight: CGFloat) -> [InkLine] {
        let height = max(textHeight, 8)
        // At least 2×2: contrast is measured within a cell.
        let cell = max(2, Int(height / 8))
        let columns = (image.width + cell - 1) / cell
        let rows = (image.height + cell - 1) / cell
        let ink = inkCells(image, cell: cell, columns: columns, rows: rows)

        // Runs of ink along each row of cells, bridging the gaps between letters and
        // words but not a column gap (over 1.2 line heights).
        let bridge = max(1, Int((height * 0.6 / CGFloat(cell)).rounded()))
        var runs: [(row: Int, start: Int, end: Int)] = []
        var rowStart = [Int](repeating: 0, count: rows + 1)
        ink.withUnsafeBufferPointer { ink in
            for row in 0..<rows {
                rowStart[row] = runs.count
                let base = row * columns
                var column = 0
                while column < columns {
                    guard ink[base + column] else {
                        column += 1
                        continue
                    }
                    var end = column
                    var probe = column + 1
                    while probe < columns, probe - end <= bridge {
                        if ink[base + probe] { end = probe }
                        probe += 1
                    }
                    runs.append((row, column, end))
                    column = end + 1
                }
            }
        }
        rowStart[rows] = runs.count

        // Runs that overlap a run in the row above, or the one above that — which
        // keeps dots and accents with their letters — belong to the same line.
        var parent = Array(runs.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for (index, run) in runs.enumerated() {
            for row in max(0, run.row - 2)..<run.row {
                for other in rowStart[row]..<rowStart[row + 1]
                where runs[other].start <= run.end && run.start <= runs[other].end {
                    parent[root(index)] = root(other)
                }
            }
        }

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var lines: [Int: [CGRect]] = [:]
        for (index, run) in runs.enumerated() {
            let rect = CGRect(x: run.start * cell, y: run.row * cell, width: (run.end - run.start + 1) * cell, height: cell)
            lines[root(index), default: []].append(rect.intersection(bounds))
        }
        return lines.values.compactMap { runs -> InkLine? in
            let rect = runs.dropFirst().reduce(runs[0]) { $0.union($1) }
            // Dots and rules are too short to be a line, pictures and blocks of tightly
            // set lines too tall, and the edge of a button too narrow: the Greek model
            // read one as "ε".
            guard rect.height >= height * 0.4, rect.height <= height * 3, rect.width >= height * 0.5 else { return nil }
            return InkLine(rect: rect, runs: runs)
        }
        .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    /// Cells whose darkest and lightest pixels differ like text from its background.
    ///
    /// Measured with vImage's maximum and minimum filters over a cell-sized window,
    /// then read at each cell's middle: going over every pixel in Swift took 380ms
    /// for a full Retina screen in a debug build.
    private static func inkCells(_ image: GrayImage, cell: Int, columns: Int, rows: Int) -> [Bool] {
        // vImage's windows are odd-sized; one pixel more than an even cell does no harm.
        let window = vImagePixelCount(cell | 1)
        let count = image.width * image.height
        let high = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        let low = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer {
            high.deallocate()
            low.deallocate()
        }
        func buffer(_ pixels: UnsafeMutablePointer<UInt8>) -> vImage_Buffer {
            vImage_Buffer(data: pixels, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
                          rowBytes: image.width)
        }
        var source = buffer(image.pixels), maxima = buffer(high), minima = buffer(low)
        guard vImageMax_Planar8(&source, &maxima, nil, 0, 0, window, window, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImageMin_Planar8(&source, &minima, nil, 0, 0, window, window, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return [Bool](repeating: false, count: columns * rows) }

        var ink = [Bool](repeating: false, count: columns * rows)
        ink.withUnsafeMutableBufferPointer { ink in
            for row in 0..<rows {
                let y = min(image.height - 1, row * cell + cell / 2)
                for column in 0..<columns {
                    let index = y * image.width + min(image.width - 1, column * cell + cell / 2)
                    ink[row * columns + column] = Int(high[index]) - Int(low[index]) > ColumnGaps.inkContrast
                }
            }
        }
        return ink
    }
}
