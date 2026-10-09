import AppKit
import LectorKit
import SwiftUI

/// Live translation of one region of the screen — game dialogue, video subtitles:
/// drawn once with the crosshair, then watched, read again whenever its text changes,
/// and kept translated in place until it's stopped.
///
/// The translation is painted over the region the way ⌘⇧1 paints it, in a panel that
/// takes no clicks or keys and never activates Lector, so the game or the video
/// underneath goes on working. Only new text is translated: a paragraph read before is
/// shown again from what's already up (`LiveDiff`) or from memory (`TranslationMemory`),
/// so a line that comes back appears at once and a screen that only scrolled is just
/// repainted. A screen that doesn't change isn't read at all (`RegionWatcher`). And a
/// translation never stays over text it doesn't say: where a still screen changes, it
/// comes off at once, before the new text is even read, and the new translation takes
/// its place as soon as it's ready.
@MainActor
final class LiveTranslation {
    /// The region, in global AppKit coordinates.
    let rect: CGRect
    /// It stopped by itself — the display went away, the stream failed — and why.
    var onEnd: ((String) -> Void)?

    private let target: String
    private let chosen: Locale.Language?
    private let offline: OpusMTTranslator
    private let appleSessions: AppleSessionCache
    private let memory: TranslationMemory
    private let reader: ScreenTextReader
    private let panel: LivePanel
    private let watcher = RegionWatcher()
    private var job: TranslationJob?
    private var renderer: TranslationRenderer?
    /// The lines of the reading on screen, its paragraphs, and what's painted over each.
    private var lines: [(text: String, rect: CGRect)] = []
    private var blocks: [Paragraphs.Block] = []
    /// What each paragraph's translation is, and what's painted over it: its translation,
    /// or until that lands what was over it in the reading before (`standIns`).
    private var shown: [LiveDiff.Shown] = []
    private var painting: [LiveDiff.Shown] = []
    private var standIns: [String?] = []
    /// The reading's frame size, and where each paragraph and its translation lie on it.
    private var frameSize = CGSize.zero
    private var painted: [CGRect] = []
    /// Where the screen has changed since it was read: translations there come off until
    /// it's read again.
    private var unread = FrameArea.none
    private var repaintQueued = false
    private var announced: String?
    /// A pack download is being reported, until the job moves on.
    private var downloading = false
    private var stopped = false

    /// - Parameter chosen: what the user said the app's text is in, if they did.
    init(rect: CGRect, target: String, choosing chosen: Locale.Language?, offline: OpusMTTranslator,
         appleSessions: AppleSessionCache, memory: TranslationMemory, reader: ScreenTextReader) {
        self.rect = rect
        self.target = target
        self.chosen = chosen
        self.offline = offline
        self.appleSessions = appleSessions
        self.memory = memory
        self.reader = reader
        panel = LivePanel(region: rect)
    }

    /// Puts the panel up, translates `first` — the capture the region was drawn on — at
    /// once, and starts watching for changes.
    func start(first: CGImage) async throws {
        panel.orderFrontRegardless()
        read(first, signature: nil)

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw LiveError.offScreen }
        let frame = screen.frame
        let region = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            .intersection(CGRect(origin: .zero, size: frame.size))

        watcher.onFrame = { [weak self] image, signature in
            Task { @MainActor in self?.read(image, signature: signature) }
        }
        watcher.onFailure = { [weak self] error in
            Task { @MainActor in self?.end(error.localizedDescription) }
        }
        watcher.onUnread = { [weak self] area in
            Task { @MainActor in self?.unreadChanged(area) }
        }
        try await watcher.start(display: number, region: region, scale: screen.backingScaleFactor)
        // Stopped while the stream was starting: it mustn't outlive the session.
        if stopped { watcher.stop() }
    }

    func stop() {
        stopped = true
        watcher.stop()
        job?.cancel()
        panel.orderOut(nil)
        if downloading {
            downloading = false
            Toast.shared.hide()
        }
    }

    private func end(_ reason: String) {
        guard !stopped else { return }
        stop()
        onEnd?(reason)
    }

    // MARK: Reading

    private func read(_ image: CGImage, signature: FrameSignature?) {
        Task {
            let text = LiveReading.cleaned((try? await reader.read(image)) ?? .empty)
            guard !stopped else { return }
            let changed = show(text, in: image)
            if let signature { watcher.finishedReading(signature, textChanged: changed) }
        }
    }

    /// Puts up the translation of a new reading of the region, and returns whether its
    /// text was new — rather than the same lines moved, or misread by a letter.
    private func show(_ text: RecognizedText, in image: CGImage) -> Bool {
        let lines = text.lines.map { ($0.text, $0.rect) }
        // The same lines again: what's up stays as it is. Grouped into paragraphs anew,
        // they could come out grouped differently and be translated all over again.
        if renderer != nil, LiveDiff.sameReading(lines, as: self.lines) { return false }
        self.lines = lines
        let blocks = Paragraphs.blocks(text)
        let reused = LiveDiff.reuse(blocks.map { ($0.text, $0.rect) }, from: shown)
        let changed = blocks.count != self.blocks.count || reused.contains { $0 == nil }
        let moved = zip(blocks, self.blocks).contains { new, old in
            abs(new.rect.minX - old.rect.minX) > 3 || abs(new.rect.minY - old.rect.minY) > 3
        }
        guard changed || moved || renderer == nil else { return false }

        self.blocks = blocks
        // A line read worse than before keeps what was painted over it until its new
        // translation lands, rather than the original flashing back meanwhile.
        standIns = LiveDiff.standIns(blocks.map { ($0.text, $0.rect) }, from: painting)
        job?.cancel()
        let job = TranslationJob(target: target, offline: offline, appleSessions: appleSessions, memory: memory)
        var known: [Int: String] = [:]
        for (index, translation) in reused.enumerated() {
            if let translation, !translation.isEmpty { known[index] = translation }
        }
        job.start(paragraphs: blocks.map(\.text), choosing: chosen, known: known)
        self.job = job
        renderer = TranslationRenderer(capture: image, original: text, blocks: blocks,
                                       rightToLeft: job.target.characterDirection == .rightToLeft,
                                       paintsCapture: false)
        frameSize = CGSize(width: image.width, height: image.height)
        painted = blocks.map(\.rect)
        // This reading is of the screen as it is now; the watcher says if it changes again.
        unread = .none
        panel.watch(job) { [weak self] in self?.jobChanged() }
        scheduleRepaint()
        return changed
    }

    private func jobChanged() {
        scheduleRepaint()
        guard let job else { return }
        // Beside the region, never on it: on it, the message would be read along with the
        // text. A download reports its progress until it's done; the rest is said once each.
        if case .downloading(let pair, let progress) = job.status {
            downloading = true
            Toast.shared.show("Downloading \(pair)", systemImage: "arrow.down.circle", beside: rect,
                              kind: .ongoing, progress: progress)
            return
        }
        if downloading {
            downloading = false
            Toast.shared.hide()
        }
        // A region with nothing in it — between two subtitles — isn't worth a word.
        let message: String? = if case .failed(let reason) = job.status { blocks.isEmpty ? nil : reason } else { job.notice }
        if let message, message != announced {
            announced = message
            Toast.shared.show(message, systemImage: "exclamationmark.triangle", beside: rect, kind: .notice)
        }
    }

    private func unreadChanged(_ area: FrameArea) {
        guard area != unread else { return }
        unread = area
        scheduleRepaint()
    }

    /// Paragraphs of a draft land a few milliseconds apart: painted once per turn of the
    /// run loop, not once each.
    private func scheduleRepaint() {
        guard !repaintQueued else { return }
        repaintQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            repaintQueued = false
            repaint()
        }
    }

    private func repaint() {
        guard let job, let renderer, !stopped else { return }
        let translations = zip(job.translations, standIns).map { $0 ?? $1 }
        // Nothing translated over a paragraph — kept as it is, or not translated yet — is
        // remembered as such: it's reused, not translated again, if it comes back.
        shown = zip(blocks, job.translations).map { LiveDiff.Shown(text: $0.text, rect: $0.rect, translation: $1 ?? "") }
        painting = zip(blocks, translations).map { LiveDiff.Shown(text: $0.text, rect: $0.rect, translation: $1 ?? "") }
        let paintable = LiveDiff.paintable(translations, over: painted, unread: unread, in: frameSize)
        let rendering = paintable.contains { $0 != nil } ? renderer.render(paintable) : nil
        if let rendering {
            painted = zip(painted, rendering.text.lines).map { $0.union($1.rect) }
        }
        panel.show(rendering?.image, saying: paintable.compactMap { $0 }.joined(separator: "\n"))
    }
}

enum LiveError: LocalizedError {
    case offScreen

    var errorDescription: String? {
        "Can't watch that area"
    }
}

/// The live translation's panel: exactly over the region, clear except for the
/// translated paragraphs and a thin edge marking what's watched. It takes no clicks and
/// no keys and never activates Lector, so whatever is underneath works as if it weren't
/// there; the translation is also its accessibility value, for VoiceOver.
@MainActor
final class LivePanel: NSPanel {
    private let view: LiveView
    private var driver: NSView?

    /// `region` in global AppKit coordinates.
    init(region: CGRect) {
        let frame = region.insetBy(dx: -LiveView.edge, dy: -LiveView.edge)
        view = LiveView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = view
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Hosts the job's driver: change reports, and Apple's session on macOS 15.
    func watch(_ job: TranslationJob, changed: @escaping () -> Void) {
        driver?.removeFromSuperview()
        let driver = NSHostingView(rootView: TranslationDriver(job: job, changed: changed))
        driver.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.addSubview(driver)
        self.driver = driver
    }

    func show(_ image: CGImage?, saying text: String) {
        view.image = image.map { NSImage(cgImage: $0, size: view.region.size) }
        view.setAccessibilityValue(text)
    }
}

@MainActor
final class LiveView: NSView {
    /// The edge drawn around the region, outside it.
    static let edge: CGFloat = 2

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var region: CGRect { bounds.insetBy(dx: Self.edge, dy: Self.edge) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live translation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: region, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // The picker's red edge, so the watched region shows over light and dark screens alike.
        let line = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        line.lineWidth = 2
        Palette.onScreen.setStroke()
        line.stroke()
    }
}
