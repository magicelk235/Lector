import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Watches one region of the screen through ScreenCaptureKit and hands over a frame to
/// read whenever its text may have changed — never while the region stays as it is.
///
/// The region is part of a display, or part of one window: then it's watched wherever the
/// window goes and whatever covers it, and when the window is resized the region is moved
/// to its new place in it (`hold`, `reframe`).
///
/// ScreenCaptureKit sends a display's frames only when something on it moves, at most
/// `framesPerSecond` of them, and marks the ones with nothing new as idle; a window's come
/// at that rate, moving or not. Each new one is boiled down to a `FrameSignature` and
/// given to a `ChangeDetector`, which decides whether, and when, it's worth reading.
/// Lector's own windows are left out of the picture, so the translation painted over the
/// region is never read back.
///
/// Everything here runs on one serial queue; `onFrame` and `onUnread` are called there too.
final class RegionWatcher: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let framesPerSecond: Int32 = 6

    /// A frame to read, with its signature and its framing (`hold`) to report back with
    /// `finishedReading`.
    var onFrame: (@Sendable (_ image: CGImage, _ signature: FrameSignature, _ framing: Int) -> Void)?
    /// The stream stopped by itself: the display went away, the window closed, permission
    /// was revoked.
    var onFailure: (@Sendable (Error) -> Void)?
    /// Where the screen has changed since it was last read, as far as that can be told
    /// before reading it again (`ChangeDetector.unread`); called whenever that changes.
    var onUnread: (@Sendable (FrameArea) -> Void)?

    private let queue = DispatchQueue(label: "Lector.RegionWatcher", qos: .userInitiated)
    private var stream: SCStream?
    private var detector = ChangeDetector()
    private var latest: (pixels: CVPixelBuffer, signature: FrameSignature)?
    private var reading = false
    private var wakeUp: DispatchWorkItem?
    /// What `onUnread` was last told; nil to tell it again whatever it is.
    private var reported: FrameArea?
    /// How many times the region has been moved within its window (`hold`): a frame handed
    /// over before the last time is of the region as it was.
    private var framing = 0
    /// Frames are let go, from `hold` until the stream has taken on the region's new place.
    private var holding = false

    /// `region` is in the display's points, top-left origin.
    func start(display number: CGDirectDisplayID, region: CGRect, scale: CGFloat) async throws {
        let (display, own) = try await Self.capturable(display: number)
        try await start(SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                        configuration: Self.configuration(region: region, scale: scale, window: false))
    }

    /// `region` is in the window's points, from its top-left corner. Only the window is in
    /// the picture: nothing in front of it ever is, Lector's translation over it included.
    func start(window id: CGWindowID, region: CGRect, scale: CGFloat) async throws {
        let filter = try await Self.filter(window: id)
        try await start(filter, configuration: Self.configuration(region: region, scale: scale, window: true))
    }

    private func start(_ filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.sync { self.stream = stream }
    }

    /// `region` of window `id` as it is now, as the watch would see it, in the window's
    /// points from its top-left corner.
    static func snapshot(window id: CGWindowID, region: CGRect, scale: CGFloat) async throws -> CGImage {
        let filter = try await filter(window: id)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration(region: region, scale: scale, window: true))
    }

    /// Window `id` alone. Off-screen windows count: by the time the watch starts, the
    /// window may have gone to another Space. One ScreenCaptureKit doesn't offer — closed
    /// meanwhile, or kept out of screen captures by its app — can't be watched.
    private static func filter(window id: CGWindowID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw LiveError.offScreen }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    private static func configuration(region: CGRect, scale: CGFloat, window: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = max(1, Int((region.width * scale).rounded()))
        configuration.height = max(1, Int((region.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 4
        if window {
            // Measured from the window's own corner, as `region` is, rather than from the
            // corner of its shadow.
            configuration.ignoreShadowsSingleWindow = true
            // Frames as big as asked for even with the window on a display with fewer
            // pixels a point, so that each one covers the region exactly.
            configuration.scalesToFit = true
            configuration.captureResolution = .best
        }
        return configuration
    }

    /// The display to watch, and Lector itself, whose windows are left out of the picture:
    /// the translation painted over the region and the messages beside it. Read back, they
    /// would be translated again — Lector's own words, over the text they replaced.
    /// Leaving out the application rather than its windows leaves out the ones it opens
    /// later too. Off-screen windows count: an application with none on screen isn't
    /// listed among on-screen ones, and as the watch starts Lector may have none — the
    /// panel over the region not drawn yet, the menu bar hidden over a full-screen video.
    static func capturable(display number: CGDirectDisplayID) async throws
        -> (display: SCDisplay, own: [SCRunningApplication]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == number }) else { throw LiveError.offScreen }
        return (display, content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier })
    }

    func stop() {
        let stream = queue.sync { () -> SCStream? in
            wakeUp?.cancel()
            wakeUp = nil
            onFrame = nil
            onFailure = nil
            onUnread = nil
            latest = nil
            defer { self.stream = nil }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    /// Lets go of every frame, and of the reading under way, until `reframe`: the window is
    /// being resized, and what's at the region's old place in it isn't the region any more.
    /// Returns the new framing: readings handed over before it are of the region as it was.
    func hold() -> Int {
        queue.sync {
            framing += 1
            holding = true
            reading = false
            latest = nil
            detector = ChangeDetector()
            reported = nil
            wakeUp?.cancel()
            wakeUp = nil
            return framing
        }
    }

    /// Watches `region` of the window from now on — the region at the window's new size, in
    /// its points from its top-left corner — and reads it afresh as soon as the stream has
    /// taken that on. False when the stream wouldn't, as while the screen is locked: frames
    /// are still let go then, for the caller to try again.
    func reframe(_ region: CGRect, scale: CGFloat) async -> Bool {
        let (stream, framing) = queue.sync { (self.stream, self.framing) }
        guard let stream else { return false }
        do {
            try await stream.updateConfiguration(Self.configuration(region: region, scale: scale, window: true))
        } catch {
            return false
        }
        queue.sync {
            // Held again meanwhile: that hold's own reframe lets go.
            if self.framing == framing { holding = false }
        }
        return true
    }

    /// The frame with `signature` has been read; `textChanged` is whether its text
    /// differed from the reading before.
    func finishedReading(_ signature: FrameSignature, framing: Int, textChanged: Bool) {
        queue.async { [self] in
            // A reading of the region as it was before the window was resized: `hold` has
            // let it go already.
            guard framing == self.framing else { return }
            reading = false
            detector.didRead(signature, at: now, textChanged: textChanged)
            // The reading's translations replace what was painted: where the screen has
            // changed again since, that's said anew.
            reported = nil
            act(on: detector.tick(at: now))
        }
    }

    private var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !holding, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer, let signature = FrameSignature(pixels)
        else { return }
        latest = (pixels, signature)
        act(on: detector.observe(signature, at: now))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [self] in onFailure?(error) }
    }

    private func act(on decision: ChangeDetector.Decision) {
        let unread = detector.unread
        if unread != reported {
            reported = unread
            onUnread?(unread)
        }
        wakeUp?.cancel()
        wakeUp = nil
        switch decision {
        case .idle:
            break
        case .wait(let until):
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                act(on: detector.tick(at: now))
            }
            wakeUp = item
            queue.asyncAfter(deadline: .now() + max(0, until - now), execute: item)
        case .read:
            // One reading at a time; what changes meanwhile is decided on when it's done.
            guard !reading, let latest, let onFrame else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(latest.pixels, options: nil, imageOut: &image)
            guard let image else { return }
            reading = true
            onFrame(image, latest.signature, framing)
        }
    }
}
