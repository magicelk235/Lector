import AppKit

/// A clear, borderless panel over the whole display a capture came from, for showing
/// something in place over it — the word picker, the in-place translation. It takes
/// key focus for the keyboard without activating Lector: activating would bring every
/// Lector window forward too, so a Settings window left behind another app would jump
/// over it mid-capture. Focus never leaves the user's app, so there is none to restore.
@MainActor
class CaptureWindow: NSPanel {
    /// Where a capture sits: the display it's on, and its rect within that display in
    /// flipped (top-left origin) coordinates — the content view's space.
    struct Placement {
        let frame: CGRect
        let local: CGRect
        /// The part of the display clear of the menu bar and the Dock, in the same flipped
        /// coordinates: where anything shown beside the capture should stay.
        let visible: CGRect

        /// `rect` is where the capture was on screen, in global AppKit coordinates.
        init(_ rect: CGRect) {
            let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main!
            frame = screen.frame
            local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
            let shown = screen.visibleFrame
            visible = CGRect(x: shown.minX - frame.minX, y: frame.maxY - shown.maxY,
                             width: shown.width, height: shown.height)
        }
    }

    init(_ placement: Placement) {
        let frame = placement.frame
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        isReleasedWhenClosed = false
        // Lector is never the active app while this is up, so it must not hide on that.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    func present() {
        makeKeyAndOrderFront(nil)
        if let contentView { makeFirstResponder(contentView) }
    }

    func dismiss() {
        orderOut(nil)
    }
}
