import AppKit
import SwiftUI

/// Neutral chrome that follows the system's light or dark appearance; the icon gives it
/// two colours. The lectern's red marks symbols, selection, progress, and the primary
/// action. The vellum of the book is the text. Toasts stay Liquid Glass, so they take on
/// whatever is behind them.
enum Palette {
    /// The lectern's red. The same pair as `AccentColor` in the asset catalog, which
    /// tints the system's own controls.
    static let accentLight = NSColor(hex: 0x8F3A38)
    static let accentDark = NSColor(hex: 0xC0544F)
    static let accent = NSColor(name: "Accent") { $0.isDark ? accentDark : accentLight }
    /// Over the screen's own pixels, which can be any colour whatever the system's
    /// appearance: the brighter red, 4.5:1 on both black and white.
    static let onScreen = accentDark

    /// The book's pages, in dark. Vellum can't be read on a light window, so light gets
    /// a dark ink of the same hue: 13:1 there, against vellum's 14:1 on dark.
    static let vellum = NSColor(hex: 0xF8EAD2)
    static let sepia = NSColor(hex: 0x2E2414)
    static let ink = NSColor(name: "Ink") { $0.isDark ? vellum : sepia }

    /// The one edge for anything that floats: the pill, toasts, keycaps.
    static let hairline = Color.primary.opacity(0.12)
}

extension Color {
    static let accent = Color(nsColor: Palette.accent)
    static let ink = Color(nsColor: Palette.ink)
    /// Ink at 72%: past 4.5:1 on the window in both appearances, and still the text's
    /// colour rather than grey.
    static let inkMuted = ink.opacity(0.72)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
