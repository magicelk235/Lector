import AppKit
import SwiftUI

/// A brief message beside where the user was working: "Copied", "No text found", or
/// why something couldn't be done. Doesn't take focus or clicks, and fades on its own —
/// after long enough to read it — unless it reports something still under way.
@MainActor
final class Toast {
    enum Kind {
        /// Only needs a glance.
        case confirmation
        /// Something went wrong or needs attention: stays long enough to be read even
        /// when it's short.
        case notice
        /// Something under way, like a language pack downloading: stays until it's
        /// replaced or `hide()` ends it.
        case ongoing
    }

    static let shared = Toast()

    private var panel: NSPanel?
    private var host: NSHostingView<ToastView>?
    private var showing: (message: String, kind: Kind)?
    private var dismissal: Task<Void, Never>?

    /// Centred on `rect`: where the user was looking, like the pointer after a copy.
    func show(_ message: String, systemImage: String, near rect: CGRect, kind: Kind = .confirmation) {
        present(ToastView(message: message, systemImage: systemImage, progress: nil, wraps: Self.wraps(message)),
                kind: kind, at: rect) { size, visible in
            CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2).clamped(size, to: visible)
        }
    }

    /// Next to `rect` and never on it — below it, else above, else at a side — for what
    /// must stay in view, like text being translated live, which would otherwise be read
    /// along with the message. `progress`, 0…1, adds a bar.
    func show(_ message: String, systemImage: String, beside rect: CGRect, kind: Kind = .confirmation,
              progress: Double? = nil) {
        present(ToastView(message: message, systemImage: systemImage, progress: progress, wraps: Self.wraps(message)),
                kind: kind, at: rect) { size, visible in
            // The pill's placement, in its flipped coordinates.
            let flip = { (r: CGRect) in CGRect(x: r.minX, y: -r.maxY, width: r.width, height: r.height) }
            let placed = CapturePill.frame(size: size, beside: flip(rect), within: flip(visible), avoiding: [])
            return flip(placed.frame).origin
        }
    }

    /// Ends an `.ongoing` message.
    func hide() {
        guard let panel, showing?.kind == .ongoing else { return }
        // Whatever comes next starts afresh rather than updating one on its way out.
        showing = nil
        fadeOut(panel, after: 0)
    }

    /// `origin` places a message of a size on the visible part of the screen `rect` is on.
    private func present(_ view: ToastView, kind: Kind, at rect: CGRect, origin: (CGSize, CGRect) -> CGPoint) {
        dismissal?.cancel()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let visible = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame ?? rect
        // The same thing still under way, a step further on: updated where it is, not
        // faded out and in again.
        if kind == .ongoing, let panel, let host, showing?.kind == .ongoing, showing?.message == view.message {
            host.rootView = view
            let size = host.fittingSize
            panel.setFrame(CGRect(origin: origin(size, visible), size: size), display: true)
            return
        }
        panel?.orderOut(nil)

        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        panel.setFrameOrigin(origin(size, visible))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel
        self.host = host
        showing = (view.message, kind)

        guard kind != .ongoing else { return }
        fadeOut(panel, after: Self.duration(for: view.message, kind: kind))
    }

    private func fadeOut(_ panel: NSPanel, after delay: TimeInterval) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            guard let self, self.panel === panel else { return }
            self.panel = nil
            host = nil
            showing = nil
        }
    }

    /// How long a message stays up: a second to notice it, then reading at about fifteen
    /// characters a second — a slow pace, since it appears unasked while the user is
    /// looking elsewhere. "Copied" gets 1.4 s; "Can't translate Persian into Hebrew"
    /// 3.3 s. Notices never go in under 3 s, and nothing stays past 10 s.
    nonisolated static func duration(for message: String, kind: Kind) -> TimeInterval {
        let reading = 1 + Double(message.count) / 15
        let shortest: TimeInterval = kind == .confirmation ? 1.2 : 3
        return min(max(reading, shortest), 10)
    }

    /// Wider than this a message wraps rather than running across the screen.
    static let maxTextWidth: CGFloat = 360

    private static func wraps(_ message: String) -> Bool {
        let width = (message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
        return width > maxTextWidth
    }
}

private extension CGPoint {
    /// Moved as little as needed for a box of `size` here to fit inside `visible`.
    func clamped(_ size: CGSize, to visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8),
                y: min(max(y, visible.minY + 8), visible.maxY - size.height - 8))
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String
    let progress: Double?
    let wraps: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
            } icon: {
                // The glass takes its look from whatever is behind it, not from the
                // system's appearance, so the red that reads over both.
                Image(systemName: systemImage).foregroundStyle(Color(nsColor: Palette.onScreen))
            }
                .font(.system(size: 15, weight: .semibold))
                // Sized to its own text: the panel is measured from this, and without it
                // the label gets squeezed to "Copi…". A long message gets a fixed width to
                // wrap in instead, growing downwards.
                .frame(width: wraps ? Toast.maxTextWidth : nil, alignment: .leading)
                .fixedSize(horizontal: !wraps, vertical: true)
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Color(nsColor: Palette.onScreen))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassBackground(cornerRadius: 16)
        .padding(6)
    }
}
