import CoreGraphics

/// An 8-bit grayscale copy of an image, the form Tesseract reads fastest.
///
/// The buffer is manually allocated rather than a Swift Array because Tesseract keeps
/// the pointer it is given and reads from it during recognition; a pointer that is
/// only valid inside `withUnsafeBufferPointer` would dangle.
final class GrayImage: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixels: UnsafeMutablePointer<UInt8>

    private init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        pixels = .allocate(capacity: self.width * self.height)
        pixels.initialize(repeating: 255, count: self.width * self.height)
    }

    deinit {
        pixels.deallocate()
    }

    /// `image` scaled by `scale`: small text is enlarged because Tesseract reads
    /// glyphs under about 20px tall noticeably worse.
    convenience init?(_ image: CGImage, scale: CGFloat = 1) {
        self.init(width: Int((CGFloat(image.width) * scale).rounded()),
                  height: Int((CGFloat(image.height) * scale).rounded()))
        guard let context = makeContext() else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Crops of `image` stacked top to bottom on white, each scaled by `scale`. Lets
    /// one recognition pass sample several lines from anywhere in a large image.
    convenience init?(stacking regions: [CGRect], of image: CGImage, scale: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crops = regions.map { $0.intersection(bounds).integral }.filter { !$0.isEmpty }
        guard !crops.isEmpty else { return nil }
        let gap = 8 * scale
        self.init(width: Int(((crops.map(\.width).max() ?? 0) * scale).rounded()),
                  height: Int((crops.reduce(0) { $0 + $1.height * scale + gap }).rounded()))
        guard let context = makeContext() else { return nil }
        context.interpolationQuality = .high
        // CoreGraphics draws bottom-up, so the first crop goes at the top.
        var top = CGFloat(height)
        for crop in crops {
            guard let piece = image.cropping(to: crop) else { continue }
            let size = CGSize(width: crop.width * scale, height: crop.height * scale)
            top -= size.height
            context.draw(piece, in: CGRect(origin: CGPoint(x: 0, y: top), size: size))
            top -= gap
        }
    }

    private func makeContext() -> CGContext? {
        CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }
}
