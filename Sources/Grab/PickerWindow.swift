import AppKit
import HoverLensKit

/// Word picking for a multi-line grab. The captured image is shown back exactly where
/// it was taken, so the screen looks untouched apart from a dimmed surround and the
/// word highlights — and the highlights stay on the words even if what's underneath
/// (a video, a scrolling page) has moved on since.
///
/// No buttons: drag across words to select them, then ⌘C (or Return) copies the
/// selection — selecting alone never copies. Esc or a click outside cancels.
@MainActor
class PickerWindow: CaptureWindow {
    let picker: PickerView

    /// `rect` is where the capture was on screen, in global AppKit coordinates.
    init(image: CGImage, rect: CGRect, text: RecognizedText) {
        let placement = Placement(rect)
        picker = PickerView(frame: CGRect(origin: .zero, size: placement.frame.size), image: image,
                            rect: placement.local, text: text, scale: CGFloat(image.width) / max(rect.width, 1))
        super.init(placement)
        contentView = picker
    }
}

@MainActor
final class PickerView: NSView {
    var onCancel: (() -> Void)?
    var onCopy: ((String) -> Void)?

    private var image: NSImage
    /// The capture, in this view's (flipped) points.
    let rect: CGRect
    private var text: RecognizedText
    /// Word rects in this view's points.
    private var wordRects: [CGRect] = []
    /// Image pixels per point.
    private let scale: CGFloat
    private var selection: WordSelection? {
        didSet { needsDisplay = true }
    }
    /// Where the current press started, to tell a drag from a click.
    private var pressStart: CGPoint?
    /// True while a click or drag is under way; content swaps wait for it.
    var isPressing: Bool { pressStart != nil }

    init(frame: CGRect, image: CGImage, rect: CGRect, text: RecognizedText, scale: CGFloat) {
        self.image = NSImage(cgImage: image, size: rect.size)
        self.rect = rect
        self.text = text
        self.scale = scale
        super.init(frame: frame)
        show(image: image, text: text)
    }

    /// Swaps what's being picked from — the translated rendering and the original, in
    /// translate mode. `image` must be the same pixel size as the capture.
    func show(image: CGImage, text: RecognizedText) {
        self.image = NSImage(cgImage: image, size: rect.size)
        self.text = text
        wordRects = text.words.map { word in
            CGRect(x: rect.minX + word.rect.minX / scale, y: rect.minY + word.rect.minY / scale,
                   width: word.rect.width / scale, height: word.rect.height / scale)
        }
        pressStart = nil
        // Nothing chosen until the user chooses it; ⌘A selects everything.
        selection = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A pointer position in this view → the recognised image's pixels.
    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let surround = NSBezierPath(rect: bounds)
        surround.append(NSBezierPath(rect: rect))
        surround.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        surround.fill()

        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: true, hints: nil)

        let selected = selection?.range
        for (index, word) in wordRects.enumerated() {
            let path = NSBezierPath(roundedRect: word.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3)
            if selected?.contains(index) == true {
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            } else {
                NSColor.gray.withAlphaComponent(0.15).setFill()
            }
            path.fill()
        }

        let outline = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(rect, cursor: .iBeam)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click away from the capture means the user is done, as with any popover.
        guard rect.insetBy(dx: -8, dy: -8).contains(point) else {
            onCancel?()
            return
        }
        guard let word = WordHitTest.word(at: pixelPoint(point), in: text) else { return }
        pressStart = point
        if event.clickCount >= 2 {
            selection = .line(containing: word, in: text)
        } else if event.modifierFlags.contains(.shift), var current = selection {
            current.focus = word
            selection = current
        } else {
            selection = WordSelection(word: word)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard pressStart != nil,
              let word = WordHitTest.word(at: pixelPoint(point), in: text),
              var current = selection else { return }
        current.focus = word
        selection = current
    }

    /// Letting go only ends the selection; copying waits for ⌘C, so a selection can be
    /// adjusted or looked at without the picker closing under it.
    override func mouseUp(with event: NSEvent) {
        pressStart = nil
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, _, _): // Esc
            onCancel?()
        case (36, _, _), (76, _, _), (_, true, "c"): // Return, Enter, ⌘C
            copySelection()
        case (_, true, "a"):
            selection = WordSelection.all(in: text)
        default:
            super.keyDown(with: event)
        }
    }

    private func copySelection() {
        guard let range = selection?.range else { return }
        onCopy?(text.text(ofWords: range))
    }
}
