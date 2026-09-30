import AppKit
import SwiftUI

/// A brief confirmation beside where the user was working: "Copied", "No text
/// found". Doesn't take focus or clicks, and fades on its own.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String, systemImage: String, near rect: CGRect) {
        dismissal?.cancel()
        panel?.orderOut(nil)

        let host = NSHostingView(rootView: ToastView(message: message, systemImage: systemImage))
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

        let visible = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        }
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.system(size: 15, weight: .semibold))
            // Sized to its own text: the panel is measured from this, and without it
            // the label gets squeezed to "Copi…".
            .fixedSize()
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .glassBackground(cornerRadius: 16)
            .padding(6)
    }
}
