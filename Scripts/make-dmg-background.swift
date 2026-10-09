// The DMG window's background: a ⌘⇧4 capture over a line of text that Lector has just
// translated, with the pill it shows under every capture, and the drag from the app to
// Applications below. The headline is the translated line.
//
// Light, whatever the system's appearance: Finder draws the icons' names in black on
// any background picture, and doesn't switch the picture with the appearance either.
// Drawn at 2x and saved at 144 dpi, so Finder shows it at its size in points, sharp on
// Retina.
//
// Usage: swift Scripts/make-dmg-background.swift <output.png>
// The geometry has to match the window and icon positions in make-dmg.sh.
import AppKit

let W = 640.0, H = 440.0

// Lector's light-appearance colours, from Sources/Shared/Palette.swift.
func hex(_ v: UInt32, _ alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255, alpha: alpha)
}
let accent = hex(0x8F3A38)
let ink = hex(0x2E2414)
let hairline = NSColor(white: 0, alpha: 0.12)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context

func font(_ size: Double, _ weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
    let plain = NSFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let descriptor = plain.fontDescriptor.withDesign(.rounded) else { return plain }
    return NSFont(descriptor: descriptor, size: size) ?? plain
}

func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
}

/// Coordinates below are top-down, like Finder's icon positions; this flips them.
func rect(x: Double, top: Double, width: Double, height: Double) -> NSRect {
    NSRect(x: x, y: H - top - height, width: width, height: height)
}

// Canvas: a light neutral with a trace of the lectern's red.
NSGradient(starting: hex(0xE9E3E2), ending: hex(0xF5F2F1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// The translated line, painted over the original the way Lector paints a paragraph.
let headlineFont = font(26, .bold)
let lead = text("Any text on screen, ", headlineFont, ink)
let tail = text("in your language.", headlineFont, accent)
let headlineWidth = lead.size().width + tail.size().width
let headlineHeight = lead.size().height
let patch = rect(x: (W - headlineWidth) / 2 - 16, top: 82,
                 width: headlineWidth + 32, height: headlineHeight + 20)
hex(0xE2D9D7).setFill()
NSBezierPath(roundedRect: patch, xRadius: 4, yRadius: 4).fill()
let baseline = NSPoint(x: patch.minX + 16, y: patch.midY - headlineHeight / 2)
lead.draw(at: baseline)
tail.draw(at: NSPoint(x: baseline.x + lead.size().width, y: baseline.y))

// The capture around it, still being dragged out: the screenshot selection's border,
// and the crosshair at the corner under the pointer.
let capture = patch.insetBy(dx: -10, dy: -10)
let border = NSBezierPath(rect: capture.insetBy(dx: 0.5, dy: 0.5))
border.lineWidth = 1
NSColor(white: 0, alpha: 0.45).setStroke()
border.stroke()

let corner = NSPoint(x: capture.maxX, y: capture.minY)
func crosshair(_ color: NSColor, _ width: Double) {
    let arm = 11.0, gap = 3.0
    let path = NSBezierPath()
    for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
        path.move(to: NSPoint(x: corner.x + dx * gap, y: corner.y + dy * gap))
        path.line(to: NSPoint(x: corner.x + dx * arm, y: corner.y + dy * arm))
    }
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}
crosshair(NSColor(white: 1, alpha: 0.9), 3)
crosshair(NSColor(white: 0, alpha: 0.85), 1.25)

// The pill under the capture, as CapturePillView draws it while translating.
let pillFont = font(12, .regular), pillBold = font(12, .semibold)
let keyFont = font(11, .semibold, rounded: true)
let secondary = ink.withAlphaComponent(0.6)

enum Piece { case text(NSAttributedString), divider, key(String) }
let pieces: [(Piece, after: Double)] = [
    (.text(text("French", pillBold, ink)), 4),
    (.text(text("→", pillFont, secondary)), 4),
    (.text(text("English", pillBold, ink)), 10),
    (.divider, 10),
    (.key("Space"), 4),
    (.text(text("original", pillFont, secondary)), 10),
    (.key("⌘C"), 4),
    (.text(text("copy", pillFont, secondary)), 0),
]
func keyLabel(_ key: String) -> NSAttributedString { text(key, keyFont, accent) }
func keySize(_ key: String) -> NSSize {
    let size = keyLabel(key).size()
    return NSSize(width: size.width + 11 * 0.9, height: size.height + 11 * 0.24)
}
func width(of piece: Piece) -> Double {
    switch piece {
    case .text(let string): string.size().width
    case .divider: 1
    case .key(let key): keySize(key).width
    }
}

let contentWidth = pieces.reduce(0) { $0 + width(of: $1.0) + $1.after }
let pill = rect(x: (W - contentWidth) / 2 - 12, top: H - capture.minY + 12,
                width: contentWidth + 24, height: 30)
let pillShape = NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12)
NSColor(white: 1, alpha: 0.96).setFill()
pillShape.fill()
hairline.setStroke()
pillShape.lineWidth = 1
pillShape.stroke()

var x = pill.minX + 12
for (piece, after) in pieces {
    switch piece {
    case .text(let string):
        string.draw(at: NSPoint(x: x, y: pill.midY - string.size().height / 2))
    case .divider:
        secondary.withAlphaComponent(0.4).setFill()
        NSRect(x: x, y: pill.midY - 6, width: 1, height: 12).fill()
    case .key(let key):
        let size = keySize(key)
        let cap = NSRect(x: x, y: pill.midY - size.height / 2, width: size.width, height: size.height)
        let capShape = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.4, yRadius: 4.4)
        ink.withAlphaComponent(0.07).setFill()
        capShape.fill()
        hairline.setStroke()
        capShape.lineWidth = 1
        capShape.stroke()
        let label = keyLabel(key)
        label.draw(at: NSPoint(x: cap.midX - label.size().width / 2, y: cap.midY - label.size().height / 2))
    }
    x += width(of: piece) + after
}

// The drag: Finder puts the 112pt icons' centres at (180, 300) and (460, 300).
let arrowY = H - 300
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 262, y: arrowY))
shaft.line(to: NSPoint(x: 360, y: arrowY))
shaft.lineWidth = 9
shaft.lineCapStyle = .round
accent.setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 380, y: arrowY))
head.line(to: NSPoint(x: 358, y: arrowY + 13))
head.line(to: NSPoint(x: 358, y: arrowY - 13))
head.close()
head.lineWidth = 7
head.lineJoinStyle = .round
accent.setFill()
head.fill()
head.stroke()

NSGraphicsContext.current = nil

// Faint grain, so the dark gradient doesn't band on real displays.
var generator = SystemRandomNumberGenerator()
let pixels = rep.bitmapData!
for offset in stride(from: 0, to: rep.bytesPerRow * rep.pixelsHigh, by: 4) {
    let noise = Int.random(in: -3...3, using: &generator)
    for channel in 0..<3 {
        pixels[offset + channel] = UInt8(clamping: Int(pixels[offset + channel]) + noise)
    }
}

try! rep.representation(using: .png, properties: [:])!.write(to: output)
