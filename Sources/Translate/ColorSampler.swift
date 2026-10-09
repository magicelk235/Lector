import Accelerate
import AppKit

/// The background and text colours of a patch of screen, so a translation can be
/// painted over the original in the page's own colours instead of a generic box.
enum ColorSampler {
    struct Colors {
        /// In 8-bit sRGB, the colour space the translation is painted in.
        let backgroundRGB: RGB
        let inkRGB: RGB

        var background: NSColor { backgroundRGB.color }
        var ink: NSColor { inkRGB.color }
    }

    private static let fallback = Colors(backgroundRGB: RGB(red: 255, green: 255, blue: 255),
                                         inkRGB: RGB(red: 0, green: 0, blue: 0))

    /// `rect` is in the image's pixels, top-left origin; `lineHeight`, one of its lines',
    /// says how far around it the page is looked at.
    static func colors(in bitmap: Bitmap, rect: CGRect, lineHeight: CGFloat) -> Colors {
        let samples = samples(of: bitmap, in: rect)
        // Text is sparse, so the commonest colour is the background; the commonest
        // colour clearly different from it is the text. Anti-aliased edges spread
        // across many in-between colours and never win either count.
        guard var background = dominant(samples)?.color else { return fallback }
        // On a picture — a video, a game behind a see-through box — neither holds. In a
        // tight box, dense type can outnumber each of the picture's many colours: a
        // colour that is all but missing just outside the box, where the page around the
        // text is, is the text's own, and the page is what is there instead.
        let rim = max(2, lineHeight * 0.15)
        let around = Self.samples(of: bitmap, in: rect.insetBy(dx: -rim, dy: -rim), excluding: rect)
        if let outside = dominant(around)?.color, outside.distance(to: background) > 90,
           around.count(where: { $0.bin == background.bin }) * 10 < around.count {
            background = outside
        }
        // And the picture's own colours far from the page can outnumber the text's, whose
        // edges spread over many: the ink is the commonest of them that can be read on
        // the page, where any can.
        let candidates = samples.filter { $0.distance(to: background) > 90 }
        let legible = candidates.filter { $0.contrast(with: background) >= 3 }
        let ink = dominant(legible.isEmpty ? candidates : legible)?.color ?? contrasting(background)
        return Colors(backgroundRGB: background, inkRGB: ink)
    }

    /// Whether `rect` is mostly one colour — a page, a card, a button — rather than a
    /// picture, whose colours are many.
    static func isPlain(_ bitmap: Bitmap, rect: CGRect) -> Bool {
        let samples = samples(of: bitmap, in: rect)
        guard let top = dominant(samples) else { return false }
        return top.share >= 0.7
    }

    /// Every so many pixels of `rect` but those in `hole`: plenty to find the dominant
    /// colours. Picked, not averaged: averaged, a thin light stroke on a dark page
    /// shrinks to grey, and grey wins the ink count.
    private static func samples(of bitmap: Bitmap, in rect: CGRect, excluding hole: CGRect = .null) -> [RGB] {
        let area = rect.integral.intersection(bitmap.frame)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return [] }
        let step = max(1, Int(max(area.width, area.height) / 160))
        var samples: [RGB] = []
        for y in stride(from: Int(area.minY), to: Int(area.maxY), by: step) {
            for x in stride(from: Int(area.minX), to: Int(area.maxX), by: step)
            where !hole.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                samples.append(bitmap[x, y])
            }
        }
        return samples
    }

    /// The commonest exact colour of the most populated 16-level colour bin, and the
    /// bin's share of `colors`. Exact, not the bin's average: on a white page the bin
    /// also holds the faintest edges of the text, and their average is the off-white of
    /// a box that shows.
    private static func dominant(_ colors: [RGB]) -> (color: RGB, share: Double)? {
        guard let first = colors.first else { return nil }
        var bins = [Int](repeating: 0, count: 4096), top = first.bin
        for color in colors {
            bins[color.bin] += 1
            if bins[color.bin] > bins[top] { top = color.bin }
        }
        // Within the bin, each channel's low four bits tell its colours apart.
        var counts = [Int](repeating: 0, count: 4096), commonest = first
        for color in colors where color.bin == top {
            let exact = (color.red & 15) << 8 | (color.green & 15) << 4 | (color.blue & 15)
            counts[exact] += 1
            let best = (commonest.red & 15) << 8 | (commonest.green & 15) << 4 | (commonest.blue & 15)
            if commonest.bin != top || counts[exact] > counts[best] { commonest = color }
        }
        return (commonest, Double(bins[top]) / Double(colors.count))
    }

    private static func contrasting(_ background: RGB) -> RGB {
        let luminance = 0.299 * Double(background.red) + 0.587 * Double(background.green)
            + 0.114 * Double(background.blue)
        return luminance > 128 ? RGB(red: 0, green: 0, blue: 0) : RGB(red: 255, green: 255, blue: 255)
    }
}

/// A colour in 8-bit sRGB.
struct RGB: Hashable {
    var red: Int
    var green: Int
    var blue: Int

    /// Summed over the channels, 0 to 765.
    func distance(to other: RGB) -> Int {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
    }

    /// WCAG's contrast ratio between the two, from 1 for the same luminance to 21 for
    /// black and white: 3 is the least large type reads at.
    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Relative luminance, 0 for black to 1 for white.
    private var luminance: Double {
        0.2126 * Self.linear[red] + 0.7152 * Self.linear[green] + 0.0722 * Self.linear[blue]
    }

    /// Each 8-bit sRGB level as linear light.
    private static let linear = (0...255).map { level in
        let value = Double(level) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    var color: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    fileprivate var bin: Int {
        (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
    }
}

/// Part of an image as 8-bit sRGB pixels — the colours a translation is painted in —
/// addressed in the image's own pixels, top-left origin.
struct Bitmap {
    /// The part of the image it holds.
    let frame: CGRect
    private let width: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage, rect: CGRect) {
        let frame = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !frame.isNull, frame.width >= 1, frame.height >= 1, let crop = image.cropping(to: frame) else { return nil }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.frame = CGRect(x: frame.minX, y: frame.minY, width: CGFloat(width), height: CGFloat(height))
        self.width = width
        self.bytes = bytes
    }

    /// The pixel at `x`, `y` in the image, which must be inside `frame`.
    subscript(x: Int, y: Int) -> RGB {
        let index = ((y - Int(frame.minY)) * width + x - Int(frame.minX)) * 4
        return RGB(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]))
    }

    /// How far each pixel of `rect` lies from `page` towards `ink`: 0 for the page, 255
    /// for solid ink, an anti-aliased edge for what it covers — coloured text on a
    /// coloured page too. Nil when the two are too close to tell apart.
    func inkness(in rect: CGRect, from page: RGB, to ink: RGB) -> Plane? {
        let red = ink.red - page.red, green = ink.green - page.green, blue = ink.blue - page.blue
        let length = red * red + green * green + blue * blue
        guard length >= 48 * 48 else { return nil }
        // Each pixel less the page, along the way to the ink, over the length of the way:
        // scaled up as far as the matrix's 16 bits allow, and back down by the divisor.
        let scale = 128
        let matrix = [red, green, blue, 0].map { Int16($0 * scale) }
        let bias = [-page.red, -page.green, -page.blue, 0].map { Int16($0) }
        return plane(in: rect) { source, target in
            vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &target, matrix, Int32(length * scale / 255), bias, 0,
                                                   vImage_Flags(kvImageNoFlags))
        }
    }

    /// 1 for each pixel of `rect` within `tolerance` of `color`, summed over channels,
    /// and 0 for the rest.
    func matching(_ color: RGB, within tolerance: Int, in rect: CGRect) -> Plane? {
        func distances(from value: Int) -> [Pixel_8] {
            (0...255).map { Pixel_8(abs($0 - value)) }
        }
        let threshold = (0...255).map { Pixel_8($0 <= tolerance ? 1 : 0) }
        return plane(in: rect) { source, target in
            // Each channel's distance from the colour, summed, then held against the tolerance.
            var channels = [UInt8](repeating: 0, count: Int(source.height) * Int(source.width) * 4)
            return channels.withUnsafeMutableBytes { bytes in
                var distance = vImage_Buffer(data: bytes.baseAddress, height: source.height, width: source.width,
                                             rowBytes: Int(source.width) * 4)
                let flags = vImage_Flags(kvImageNoFlags)
                // In the bitmap's order: red, green, blue, and the unused fourth byte.
                var error = vImageTableLookUp_ARGB8888(&source, &distance, distances(from: color.red),
                                                       distances(from: color.green), distances(from: color.blue),
                                                       [Pixel_8](repeating: 0, count: 256), flags)
                guard error == kvImageNoError else { return error }
                error = vImageMatrixMultiply_ARGB8888ToPlanar8(&distance, &target, [1, 1, 1, 0], 1, nil, 0, flags)
                guard error == kvImageNoError else { return error }
                return withUnsafePointer(to: target) { vImageTableLookUp_Planar8($0, $0, threshold, flags) }
            }
        }
    }

    /// A plane of `rect`, its bytes worked out by `fill` from the bitmap's pixels there.
    private func plane(in rect: CGRect,
                       _ fill: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error) -> Plane? {
        let area = rect.integral.intersection(frame)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let left = Int(area.minX - frame.minX), top = Int(area.minY - frame.minY)
        let columns = Int(area.width), rows = Int(area.height)
        var values = [UInt8](repeating: 0, count: columns * rows)
        let error = bytes.withUnsafeBytes { pixels in
            values.withUnsafeMutableBytes { plane in
                // vImage only reads the source; its buffer type is mutable all the same.
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels.baseAddress! + (top * width + left) * 4),
                                           height: vImagePixelCount(rows), width: vImagePixelCount(columns),
                                           rowBytes: width * 4)
                var target = vImage_Buffer(data: plane.baseAddress, height: vImagePixelCount(rows),
                                           width: vImagePixelCount(columns), rowBytes: columns)
                return fill(&source, &target)
            }
        }
        return error == kvImageNoError ? Plane(frame: area, values: values) : nil
    }
}

/// A byte for each pixel of part of an image, row by row, addressed in the image's own
/// pixels. Its questions are asked of whole rows and columns at once, by vImage, vDSP
/// and `memchr`: measuring a page asks them of millions of pixels, and a debug build
/// would take seconds over them one by one.
struct Plane {
    let frame: CGRect
    private let left: Int, top: Int, width: Int, height: Int
    private let values: [UInt8]
    /// Each column of `values` laid out as a row, the rightmost first: reading down a
    /// column is then reading along memory. Kept by planes made `turned`.
    private let columns: [UInt8]?

    fileprivate init(frame: CGRect, values: [UInt8], turned: Bool = false) {
        self.frame = frame
        left = Int(frame.minX)
        top = Int(frame.minY)
        width = Int(frame.width)
        height = Int(frame.height)
        self.values = values
        guard turned else {
            columns = nil
            return
        }
        var columns = [UInt8](repeating: 0, count: values.count)
        let (width, height) = (width, height)
        let error = values.withUnsafeBytes { source in
            columns.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                                         height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var to = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(width),
                                       width: vImagePixelCount(height), rowBytes: height)
                return vImageRotate90_Planar8(&from, &to, UInt8(kRotate90DegreesCounterClockwise), 0,
                                              vImage_Flags(kvImageNoFlags))
            }
        }
        self.columns = error == kvImageNoError ? columns : nil
    }

    /// The same plane, able to answer `first(_:column:rows:)`.
    func turned() -> Plane {
        Plane(frame: frame, values: values, turned: true)
    }

    /// `columns` by `rows`, clamped to the plane, as 1 where a pixel is at least
    /// `threshold` and 0 elsewhere.
    func mask(columns: ClosedRange<Int>, rows: ClosedRange<Int>, atLeast threshold: UInt8) -> Mask? {
        guard let (from, to) = span(columns, of: left, width), let (first, last) = span(rows, of: top, height)
        else { return nil }
        let across = to - from + 1, down = last - first + 1
        let table = (0...255).map { Pixel_8($0 >= threshold ? 1 : 0) }
        var ones = [UInt8](repeating: 0, count: across * down)
        values.withUnsafeBytes { source in
            ones.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress! + first * width + from),
                                         height: vImagePixelCount(down), width: vImagePixelCount(across), rowBytes: width)
                var to = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(down),
                                       width: vImagePixelCount(across), rowBytes: across)
                _ = vImageTableLookUp_Planar8(&from, &to, table, vImage_Flags(kvImageNoFlags))
            }
        }
        var floats = [Float](repeating: 0, count: ones.count)
        vDSP_vfltu8(ones, 1, &floats, 1, vDSP_Length(ones.count))
        return Mask(left: left + from, top: top + first, width: across, height: down, values: floats)
    }

    /// How many pixels of `columns` by `rows` hold `value`, and of how many.
    func count(_ value: UInt8, columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> (Int, of: Int) {
        guard let at = mask(columns: columns, rows: rows, atLeast: value) else { return (0, 0) }
        let above = value == 255 ? 0 : mask(columns: columns, rows: rows, atLeast: value + 1)?.total ?? 0
        return (at.total - above, at.width * at.height)
    }

    /// The leftmost of `columns` where any of `rows` holds `value`.
    func first(_ value: UInt8, columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> Int? {
        guard let (from, to) = span(columns, of: left, width), let (first, last) = span(rows, of: top, height)
        else { return nil }
        return values.withUnsafeBytes { values in
            (first...last).compactMap { row -> Int? in
                let start = values.baseAddress! + row * width + from
                return memchr(start, Int32(value), to - from + 1).map { left + from + start.distance(to: UnsafeRawPointer($0)) }
            }.min()
        }
    }

    /// The rightmost of `columns` where any of `rows` holds `value`.
    func last(_ value: UInt8, columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> Int? {
        guard let (from, to) = span(columns, of: left, width), let (first, last) = span(rows, of: top, height)
        else { return nil }
        return values.withUnsafeBytes { values in
            (first...last).compactMap { row -> Int? in
                let start = values.baseAddress! + row * width
                var found: Int?, column = from
                while column <= to, let hit = memchr(start + column, Int32(value), to - column + 1) {
                    found = start.distance(to: UnsafeRawPointer(hit))
                    column = found! + 1
                }
                return found.map { left + $0 }
            }.max()
        }
    }

    /// The first of `rows`, top down, at which column `x` holds `value`. Only for a plane
    /// made `turned`.
    func first(_ value: UInt8, column x: Int, rows: ClosedRange<Int>) -> Int? {
        guard let columns, x >= left, x < left + width, let (first, last) = span(rows, of: top, height)
        else { return nil }
        return columns.withUnsafeBytes { columns in
            let start = columns.baseAddress! + (width - 1 - (x - left)) * height
            return memchr(start + first, Int32(value), last - first + 1).map { top + start.distance(to: UnsafeRawPointer($0)) }
        }
    }

    /// Whether any pixel of column `x` within `rows` is at least `threshold`.
    func any(column x: Int, rows: ClosedRange<Int>, atLeast threshold: UInt8) -> Bool {
        guard x >= left, x < left + width, let (from, to) = span(rows, of: top, height) else { return false }
        return values.withUnsafeBufferPointer { values in
            var index = from * width + x - left
            for _ in from...to {
                if values[index] >= threshold { return true }
                index += width
            }
            return false
        }
    }

    /// The runs along row `y` within `columns` of values above `floor`, each the sum of
    /// its values over 255: how wide a stroke is, its anti-aliased edges counted for what
    /// they cover.
    func runs(row y: Int, columns: ClosedRange<Int>, above floor: UInt8) -> [CGFloat] {
        guard let (from, to) = span(columns, of: left, width), y >= top, y < top + height else { return [] }
        return values.withUnsafeBufferPointer { values in
            var runs: [CGFloat] = [], run = 0
            for index in (y - top) * width + from...(y - top) * width + to {
                if values[index] > floor {
                    run += Int(values[index])
                } else if run > 0 {
                    runs.append(CGFloat(run) / 255)
                    run = 0
                }
            }
            if run > 0 { runs.append(CGFloat(run) / 255) }
            return runs
        }
    }

    /// `range` clamped to `start..<start + length`, as offsets from `start`.
    private func span(_ range: ClosedRange<Int>, of start: Int, _ length: Int) -> (Int, Int)? {
        let from = max(range.lowerBound, start) - start, to = min(range.upperBound, start + length - 1) - start
        return from <= to ? (from, to) : nil
    }
}

/// Part of a plane as 1s and 0s, for counting along its rows and down its columns at
/// once. `left` and `top` are where it starts in the image's pixels; rows and columns
/// are counted from there.
struct Mask {
    let left: Int, top: Int, width: Int, height: Int
    private var values: [Float]

    fileprivate init(left: Int, top: Int, width: Int, height: Int, values: [Float]) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.values = values
    }

    var total: Int {
        var sum: Float = 0
        vDSP_sve(values, 1, &sum, vDSP_Length(values.count))
        return Int(sum)
    }

    /// For each row, how many of `columns` are 1: all of them unless given.
    func rowSums(columns: ClosedRange<Int>? = nil) -> [Int] {
        let columns = (columns ?? 0...width - 1).clamped(to: 0...width - 1)
        return values.withUnsafeBufferPointer { values in
            (0..<height).map { row in
                var sum: Float = 0
                vDSP_sve(values.baseAddress! + row * width + columns.lowerBound, 1, &sum, vDSP_Length(columns.count))
                return Int(sum)
            }
        }
    }

    /// For each column, how many of `rows` are 1: all of them unless given.
    func columnSums(rows: ClosedRange<Int>? = nil) -> [Int] {
        let rows = (rows ?? 0...height - 1).clamped(to: 0...height - 1)
        var sums = [Float](repeating: 0, count: width)
        values.withUnsafeBufferPointer { values in
            for row in rows {
                vDSP_vadd(sums, 1, values.baseAddress! + row * width, 1, &sums, 1, vDSP_Length(width))
            }
        }
        return sums.map { Int($0) }
    }

    /// Sets every row of `column` to 0.
    mutating func clear(column: Int) {
        let (width, height) = (width, height)
        values.withUnsafeMutableBufferPointer { values in
            vDSP_vclr(values.baseAddress! + column, width, vDSP_Length(height))
        }
    }
}
