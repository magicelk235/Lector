import SwiftUI

extension View {
    /// The system's Liquid Glass where it exists, a material everywhere else; the same
    /// hairline as the capture pill's around either.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Palette.hairline))
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Palette.hairline))
        }
    }
}
