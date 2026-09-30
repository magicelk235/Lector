import AppKit

/// The background and text colours of a patch of screen, so a translation can be
/// painted over the original in the page's own colours instead of a generic box.
enum ColorSampler {
    struct Colors {
        let background: NSColor
        let ink: NSColor
    }

    /// `rect` is in `image`'s pixels, top-left origin.
    static func colors(in image: CGImage, rect: CGRect) -> Colors {
        let fallback = Colors(background: .white, ink: .black)
        guard let crop = image.cropping(to: rect.integral), crop.width > 0, crop.height > 0 else { return fallback }

        // A small copy is plenty to find the two dominant colours.
        let shrink = min(1, 160 / CGFloat(max(crop.width, crop.height)))
        let width = max(1, Int(CGFloat(crop.width) * shrink)), height = max(1, Int(CGFloat(crop.height) * shrink))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return fallback }

        let colors = stride(from: 0, to: pixels.count, by: 4).map {
            (Int(pixels[$0]), Int(pixels[$0 + 1]), Int(pixels[$0 + 2]))
        }
        // Text is sparse, so the commonest colour is the background; the commonest
        // colour clearly different from it is the text. Anti-aliased edges spread
        // across many in-between colours and never win either count.
        guard let background = dominant(colors) else { return fallback }
        let inkCandidates = colors.filter { distance($0, background) > 90 }
        let ink = dominant(inkCandidates) ?? contrasting(background)
        return Colors(background: color(background), ink: color(ink))
    }

    private typealias RGB = (Int, Int, Int)

    /// Average of the pixels in the most populated 16-level colour bin.
    private static func dominant(_ colors: [RGB]) -> RGB? {
        guard !colors.isEmpty else { return nil }
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for (r, g, b) in colors {
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let bin = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (bin.count + 1, bin.r + r, bin.g + g, bin.b + b)
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return nil }
        return (top.r / top.count, top.g / top.count, top.b / top.count)
    }

    private static func distance(_ a: RGB, _ b: RGB) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    private static func contrasting(_ background: RGB) -> RGB {
        let luminance = 0.299 * Double(background.0) + 0.587 * Double(background.1) + 0.114 * Double(background.2)
        return luminance > 128 ? (0, 0, 0) : (255, 255, 255)
    }

    private static func color(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }
}
