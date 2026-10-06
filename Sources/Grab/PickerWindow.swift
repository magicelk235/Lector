import AppKit
import LectorKit

/// Word picking for a multi-line grab. The captured image is shown back exactly where
/// it was taken, so the screen looks untouched apart from a dimmed surround and faint
/// word marks — and the marks stay on the words even if what's underneath (a video, a
/// scrolling page) has moved on since.
///
/// No buttons: drag across words to select them, then ⌘C (or Return) copies the
/// selection — selecting alone never copies. Tab translates the capture right there,
/// and from then on it is the translation overlay. Esc or a click outside cancels. A
/// small pill beside the capture says so (`CapturePill`).
@MainActor
class PickerWindow: CaptureWindow {
    let picker: PickerView

    /// `rect` is where the capture was on screen, in global AppKit coordinates;
    /// `paragraphs` are runs of `text`'s lines that make one paragraph each, for copying.
    init(image: CGImage, rect: CGRect, text: RecognizedText, paragraphs: [Range<Int>], hint: CaptureHint,
         pill: PillOptions) {
        let placement = Placement(rect)
        picker = PickerView(frame: CGRect(origin: .zero, size: placement.frame.size), image: image,
                            rect: placement.local, visible: placement.visible, text: text, paragraphs: paragraphs,
                            scale: CGFloat(image.width) / max(rect.width, 1), hint: hint, pill: pill)
        super.init(placement)
        contentView = picker
    }
}

@MainActor
final class PickerView: NSView {
    var onCancel: (() -> Void)?
    var onCopy: ((String) -> Void)?
    /// Tab: translate what was captured, in place.
    var onTranslate: (() -> Void)?

    private var image: NSImage
    /// The capture, in this view's (flipped) points.
    let rect: CGRect
    /// The screen clear of the menu bar and the Dock, in this view's points.
    private let visible: CGRect
    private var text: RecognizedText
    private var paragraphs: [Range<Int>]
    /// Word rects in this view's points.
    private var wordRects: [CGRect] = []
    /// Image pixels per point.
    private let scale: CGFloat
    private var selection: WordSelection? {
        didSet { needsDisplay = true }
    }
    /// The word under the pointer, which lights up to say it can be picked.
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for index in [oldValue, hovered].compactMap({ $0 }) where wordRects.indices.contains(index) {
                setNeedsDisplay(Self.mark(wordRects[index]).bounds.insetBy(dx: -1, dy: -1))
            }
        }
    }
    /// Where the current press started, to tell a drag from a click.
    private var pressStart: CGPoint?
    /// True while a click or drag is under way; content swaps wait for it.
    var isPressing: Bool { pressStart != nil }
    private var pill: CapturePill?

    /// Faint marks on every word tell the word picker's user that they can be picked.
    /// Over a translation they would turn the text into a patchwork of grey boxes, so
    /// there only the word under the pointer is marked — and the selection, always.
    var marksEveryWord = true {
        didSet { needsDisplay = true }
    }

    init(frame: CGRect, image: CGImage, rect: CGRect, visible: CGRect, text: RecognizedText,
         paragraphs: [Range<Int>], scale: CGFloat, hint: CaptureHint, pill options: PillOptions) {
        self.image = NSImage(cgImage: image, size: rect.size)
        self.rect = rect
        self.visible = visible
        self.text = text
        self.paragraphs = paragraphs
        self.scale = scale
        super.init(frame: frame)
        show(image: image, text: text, paragraphs: paragraphs)
        pill = CapturePill(in: self, options: options)
        showHint(hint)
    }

    /// Swaps what's being picked from — the translated rendering and the original, in
    /// translate mode. `image` must be the same pixel size as the capture.
    func show(image: CGImage, text: RecognizedText, paragraphs: [Range<Int>]) {
        self.image = NSImage(cgImage: image, size: rect.size)
        self.text = text
        self.paragraphs = paragraphs
        wordRects = text.words.map { word in
            CGRect(x: rect.minX + word.rect.minX / scale, y: rect.minY + word.rect.minY / scale,
                   width: word.rect.width / scale, height: word.rect.height / scale)
        }
        pressStart = nil
        hovered = nil
        // Nothing chosen until the user chooses it; ⌘A selects everything.
        selection = nil
        pill?.relayout(capture: rect, visible: visible, words: wordRects)
    }

    /// What the pill beside the capture says.
    func showHint(_ hint: CaptureHint) {
        pill?.show(hint, capture: rect, visible: visible, words: wordRects)
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

    private static func mark(_ word: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: word.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        let surround = NSBezierPath(rect: bounds)
        surround.append(NSBezierPath(rect: rect))
        surround.windingRule = .evenOdd
        // Light enough to keep reading the page the capture came from.
        NSColor.black.withAlphaComponent(0.18).setFill()
        surround.fill()

        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: true, hints: nil)

        let selected = selection?.range
        for (index, word) in wordRects.enumerated() where word.insetBy(dx: -3, dy: -2).intersects(dirtyRect) {
            // Red marks only the selection, like a highlighter: a light wash the text
            // reads through and a line under it. The hint that a word can be picked stays
            // a neutral wash, or the whole capture reads as already highlighted.
            let mark = Self.mark(word)
            if selected?.contains(index) == true {
                Palette.onScreen.withAlphaComponent(0.18).setFill()
                mark.fill()
                Palette.onScreen.setFill()
                NSRect(x: mark.bounds.minX, y: word.maxY - 0.5, width: mark.bounds.width, height: 2).fill()
                continue
            }
            let fill: NSColor
            if index == hovered {
                fill = NSColor.gray.withAlphaComponent(0.18)
            } else if marksEveryWord {
                fill = NSColor.gray.withAlphaComponent(0.08)
            } else {
                continue
            }
            fill.setFill()
            mark.fill()
        }

        // The lectern's red, which reads over light and dark screens alike.
        let edge = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        edge.lineWidth = 2
        Palette.onScreen.setStroke()
        edge.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(rect, cursor: .iBeam)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Always active: Lector never is while a capture is up.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pill?.pointerMoved(to: point)
        // Only a word actually under the pointer: a drag snaps to the nearest one, but
        // lighting up a word an inch away would say it's being pointed at when it isn't.
        hovered = wordRects.firstIndex { $0.insetBy(dx: -2, dy: -1).contains(point) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

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
        case (48, _, _): // Tab
            onTranslate?()
        case (36, _, _), (76, _, _), (_, true, "c"): // Return, Enter, ⌘C
            copySelection()
        case (_, true, "a"):
            selection = WordSelection.all(in: text)
        default:
            super.keyDown(with: event)
        }
    }

    /// In the translation overlay ⌘C with nothing selected copies all that's shown — the
    /// translation, or the original after Space. In the word picker it waits for a pick.
    var copiesAllWhenNothingSelected = false

    private func copySelection() {
        let all = copiesAllWhenNothingSelected ? WordSelection.all(in: text) : nil
        guard let range = (selection ?? all)?.range else { return }
        onCopy?(CopiedText.text(ofWords: range, in: text, paragraphs: paragraphs))
    }
}
