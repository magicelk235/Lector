import AppKit
import ImageIO
import ScreenCaptureKit

/// A region the user picked with macOS's own screenshot crosshair.
struct ScreenCapture {
    let image: CGImage
    /// Where the pointer was when the selection finished (global AppKit coordinates):
    /// a corner of a dragged box, or inside the window a Space-click captured.
    let pointer: CGPoint
}

/// Runs the system's ⌘⇧4 tool — the real one, so the crosshair, the size readout,
/// Space for a whole window and Esc to cancel all behave exactly as users know them.
@MainActor
enum SystemCapture {
    private static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// Nil when the user cancels with Esc.
    static func run() async throws -> ScreenCapture? {
        // A private per-user temporary file, read straight back and deleted. TIFF, not
        // PNG: uncompressed, so neither side spends time on compression.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = tool
        // -i the interactive crosshair, -x no shutter sound, -o no window shadow in
        // window mode, -r no DPI metadata.
        process.arguments = ["-i", "-x", "-o", "-r", "-t", "tiff", file.path]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let pointer = NSEvent.mouseLocation

        // Decoded immediately: the file is gone as soon as this returns.
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }

        return ScreenCapture(image: image, pointer: pointer)
    }
}

/// Works out where on screen a `screencapture` selection was, which it doesn't report
/// and the word picker and in-place translation both need. A single copied line never asks.
///
/// Watching the mouse doesn't work: while the crosshair is up, `screencapture` owns
/// the event stream and global monitors see nothing. What is known afterwards is
/// enough, though. The image gives the exact size, and the pointer is still where the
/// button was released — one corner of a dragged box, or somewhere inside the window
/// a Space-click captured. That leaves at most five places the box can be, and a
/// look at just that part of the screen shows which one holds the same pixels.
@MainActor
enum CaptureLocator {
    static func locate(_ capture: ScreenCapture) async -> CGRect {
        let image = capture.image, pointer = capture.pointer
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let backing = screen?.backingScaleFactor ?? 2
        let size = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)

        var candidates = corners(pointer: pointer, size: size)
        if let window = windowRect(at: pointer),
           abs(window.width - size.width) < 4, abs(window.height - size.height) < 4 {
            candidates.insert(CGRect(origin: window.origin, size: size), at: 0)
        }

        guard let screen else { return candidates[0] }
        let frame = screen.frame
        // Only the area the candidates cover, in the display's top-left-origin points.
        let area = candidates.dropFirst().reduce(candidates[0]) { $0.union($1) }.intersection(frame)
        let local = CGRect(x: area.minX - frame.minX, y: frame.maxY - area.maxY,
                           width: area.width, height: area.height).integral
        guard !local.isEmpty, let snapshot = await snapshot(of: screen, area: local) else { return candidates[0] }

        let scored = candidates.compactMap { rect -> (CGRect, Double)? in
            let pixels = CGRect(x: (rect.minX - frame.minX - local.minX) * backing,
                                y: (frame.maxY - rect.maxY - local.minY) * backing,
                                width: CGFloat(image.width), height: CGFloat(image.height)).integral
            guard CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
                    .insetBy(dx: -1, dy: -1).contains(pixels),
                  let crop = snapshot.cropping(to: pixels),
                  let difference = ImageDifference.mean(crop, image)
            else { return nil }
            return (rect, difference)
        }
        return scored.min { $0.1 < $1.1 }?.0 ?? candidates[0]
    }

    /// The four boxes of `size` with a corner at `pointer`, likeliest first: most
    /// people drag from top-left to bottom-right, leaving the pointer bottom-right.
    static func corners(pointer: CGPoint, size: CGSize) -> [CGRect] {
        [
            CGRect(x: pointer.x - size.width, y: pointer.y, width: size.width, height: size.height),
            CGRect(x: pointer.x, y: pointer.y, width: size.width, height: size.height),
            CGRect(x: pointer.x - size.width, y: pointer.y - size.height, width: size.width, height: size.height),
            CGRect(x: pointer.x, y: pointer.y - size.height, width: size.width, height: size.height),
        ]
    }

    private static func snapshot(of screen: NSScreen, area: CGRect) async -> CGImage? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == number })
        else { return nil }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = Int(area.width * screen.backingScaleFactor)
        configuration.height = Int(area.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
            configuration: configuration)
    }

    /// The frontmost ordinary window under `point`, in AppKit coordinates.
    private static func windowRect(at point: CGPoint) -> CGRect? {
        // Window-server bounds have a top-left origin measured from the primary display.
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.contains(cgPoint)
            else { continue }
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }
        return nil
    }
}

/// How different two images of the same size look, as a mean grey-level difference
/// (0 identical, 255 opposite) over a downsampled grid.
enum ImageDifference {
    static func mean(_ a: CGImage, _ b: CGImage) -> Double? {
        let width = 128
        let height = max(4, min(128, Int((Double(width) * Double(b.height) / Double(max(b.width, 1))).rounded())))
        guard let first = gray(a, width: width, height: height),
              let second = gray(b, width: width, height: height)
        else { return nil }
        var total = 0
        for index in first.indices { total += abs(Int(first[index]) - Int(second[index])) }
        return Double(total) / Double(first.count)
    }

    private static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
