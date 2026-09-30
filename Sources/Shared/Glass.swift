import SwiftUI

extension View {
    /// The system's Liquid Glass where it exists, a material everywhere else.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.15)))
        }
    }
}
