import SwiftUI

/// A key or key combination, drawn the same wherever Lector names one: the red symbol
/// on a faint ink cap. `width` fixes the cap's width, so caps in a column line up and a
/// new shortcut doesn't shift anything. `listening` is a recorder waiting for keys: the
/// same cap, outlined in red, with the prompt in muted ink.
struct Keycap: View {
    let text: String
    var size: CGFloat = 13
    var width: CGFloat?
    var listening = false

    init(_ text: String, size: CGFloat = 13, width: CGFloat? = nil, listening: Bool = false) {
        self.text = text
        self.size = size
        self.width = width
        self.listening = listening
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(listening ? Color.inkMuted : Color.accent)
            .padding(.horizontal, size * 0.45)
            .padding(.vertical, size * 0.12)
            .frame(width: width)
            .background(Color.ink.opacity(0.07), in: shape)
            .overlay(shape.strokeBorder(listening ? Color.accent : Palette.hairline,
                                        lineWidth: listening ? 1.5 : 1))
    }
}
