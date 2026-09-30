import AppKit

/// A clear, borderless window over the whole display a capture came from, for showing
/// something in place over it — the word picker, the in-place translation. It takes
/// key focus for the keyboard and hands focus back to the user's app when dismissed.
@MainActor
class CaptureWindow: NSWindow {
    /// Where a capture sits: the display it's on, and its rect within that display in
    /// flipped (top-left origin) coordinates — the content view's space.
    struct Placement {
        let frame: CGRect
        let local: CGRect

        /// `rect` is where the capture was on screen, in global AppKit coordinates.
        init(_ rect: CGRect) {
            frame = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main!).frame
            local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        }
    }

    private var previousApp: NSRunningApplication?

    init(_ placement: Placement) {
        let frame = placement.frame
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        // An agent app has to be active for its window to receive ⌘C and Esc.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if let contentView { makeFirstResponder(contentView) }
    }

    /// Takes the window down and hands focus back to whatever the user was in.
    func dismiss() {
        orderOut(nil)
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
    }
}
