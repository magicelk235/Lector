import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Watches one region of the screen through ScreenCaptureKit and hands over a frame to
/// read whenever its text may have changed — never while the region stays as it is.
///
/// ScreenCaptureKit sends frames only when something on the display moves, at most
/// `framesPerSecond` of them, and marks the ones with nothing new as idle. Each new one
/// is boiled down to a `FrameSignature` and given to a `ChangeDetector`, which decides
/// whether, and when, it's worth reading. Lector's own windows are left out of the
/// picture, so the translation painted over the region is never read back.
///
/// Everything here runs on one serial queue; `onFrame` and `onUnread` are called there too.
final class RegionWatcher: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let framesPerSecond: Int32 = 6

    /// A frame to read, and its signature to report back with `finishedReading`.
    var onFrame: (@Sendable (CGImage, FrameSignature) -> Void)?
    /// The stream stopped by itself: the display went away, permission was revoked.
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

    /// `region` is in the display's points, top-left origin.
    func start(display number: CGDirectDisplayID, region: CGRect, scale: CGFloat) async throws {
        let (display, own) = try await Self.capturable(display: number)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = max(1, Int((region.width * scale).rounded()))
        configuration.height = max(1, Int((region.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 4
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.sync { self.stream = stream }
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

    /// The frame with `signature` has been read; `textChanged` is whether its text
    /// differed from the reading before.
    func finishedReading(_ signature: FrameSignature, textChanged: Bool) {
        queue.async { [self] in
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
        guard type == .screen, sampleBuffer.isValid,
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
            onFrame(image, latest.signature)
        }
    }
}
