import AppKit
import SwiftUI

/// What the small pill beside a capture says: what is going on, and the keys that work
/// here. The word picker has only keys; the translation overlay says what it's
/// translating from and into as well, or that a language pack is downloading.
struct CaptureHint: Equatable {
    enum Status: Equatable {
        /// `from` names the languages translated from — "French", "French, Japanese +5" —
        /// and is nil while they're still being worked out.
        case translating(from: String?, into: String)
        /// A language pack the translation is waiting for: "Czech → Hebrew", and how
        /// much of it is on the Mac, 0…1, or nil until known.
        case downloading(String, progress: Double?)
        /// Nothing was changed: "Already in Hebrew".
        case unchanged(String)
    }

    struct Key: Equatable {
        let key: String
        let action: String
        /// Still shown once the pill has settled into its short form.
        var essential = false
    }

    /// A line about part of the capture, said while the rest is shown regardless.
    struct Note: Equatable {
        let text: String
        let systemImage: String

        /// "Can't translate Persian into Hebrew".
        static func warning(_ text: String) -> Note { Note(text: text, systemImage: "exclamationmark.triangle.fill") }
        /// "Persian: rough translation".
        static func info(_ text: String) -> Note { Note(text: text, systemImage: "info.circle") }
    }

    var status: Status?
    /// A spinner beside the status: there's more still to come.
    var isWorking = false
    var notes: [Note] = []
    var keys: [Key]

    /// The word picker's.
    static let picking = CaptureHint(keys: [
        Key(key: "Drag", action: "to select"),
        Key(key: "⌘C", action: "copy", essential: true),
        Key(key: "⌘A", action: "all"),
        Key(key: "Tab", action: "translate", essential: true),
        Key(key: "Esc", action: "close"),
    ])

    /// The translation overlay's; Space shows whichever of the two isn't on screen.
    /// Settled, it says only what was translated.
    static func translating(showingOriginal: Bool) -> [Key] {
        [
            Key(key: "Space", action: showingOriginal ? "translation" : "original"),
            Key(key: "Tab", action: "language"),
            Key(key: "⌘C", action: "copy"),
            Key(key: "Esc", action: "close"),
        ]
    }

    /// "French"; "French, Japanese"; "French, Japanese +5": the two with the most text,
    /// and how many more.
    static func sources(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    /// The same moment, apart from how far a download has got: a new one deserves the
    /// user's eye again, a download ticking along doesn't.
    func isSameMoment(as other: CaptureHint) -> Bool {
        var a = self, b = other
        if case .downloading(let pair, _) = a.status { a.status = .downloading(pair, progress: nil) }
        if case .downloading(let pair, _) = b.status { b.status = .downloading(pair, progress: nil) }
        return a == b
    }

    /// What's left to show once the user's choices are applied: never the downloads or
    /// the notes, which say why a translation is waiting or incomplete.
    func trimmed(by options: PillOptions) -> CaptureHint {
        var hint = self
        if !options.showsKeys { hint.keys = [] }
        if !options.showsLanguages, case .translating = hint.status {
            hint.status = nil
            hint.isWorking = false
        }
        return hint
    }

    var isEmpty: Bool { status == nil && notes.isEmpty && keys.isEmpty }
}

/// Shows a `CaptureHint` attached to the capture: just below it, else above it, else
/// beside it, and only inside it — in the corner with the least text under it — when
/// the capture fills the screen. It never takes a click: everything still goes to the
/// words, and a click on it outside the capture closes like any other click outside.
/// One line when that's no wider than the capture; beside a small capture the status
/// and the keys take a line each, rather than a strip twice the capture's width.
///
/// Full when it appears or has something new to say; after a few seconds it settles
/// into its short form, the status without the keys, so it doesn't compete with the
/// text. It stays opaque throughout: it sits over whatever the screen shows, and
/// translucent small type over a busy page can't be read. Pointing at it brings the
/// keys back — or, when it had to sit over the capture, gets it out of the way.
@MainActor
final class CapturePill {
    private let host = PassThroughHostingView(rootView: CapturePillView(hint: .picking, stacked: false, full: true))
    /// Measures the one-line layout without showing it.
    private let measure = NSHostingView(rootView: CapturePillView(hint: .picking, stacked: false, full: true))
    private let options: PillOptions
    private var hint: CaptureHint?
    private var stacked = false
    private var isInside = false
    private var isPointedAt = false
    private var isSettled = false
    private var settling: Task<Void, Never>?
    /// Where it was last placed from, to place it again when its size changes.
    private var layout: (capture: CGRect, visible: CGRect, words: [CGRect])?

    /// Space left between the pill and the capture, and kept from the screen's edges.
    nonisolated static let gap: CGFloat = 8
    /// Narrower captures than this still get a one-line pill if it fits in this width.
    private static let oneLineWidth: CGFloat = 420

    init(in view: NSView, options: PillOptions) {
        self.options = options
        host.alphaValue = 0
        view.addSubview(host)
    }

    /// `capture` and `visible` (the screen clear of menu bar and Dock) are in the
    /// parent view's flipped coordinates; `words` are the words' rects, to keep off.
    func show(_ hint: CaptureHint, capture: CGRect, visible: CGRect, words: [CGRect]) {
        let hint = hint.trimmed(by: options)
        let isNew = self.hint.map { !$0.isSameMoment(as: hint) } ?? true
        layout = (capture, visible, words)
        if self.hint != hint {
            self.hint = hint
            // Only when it changed: paragraphs land many times a second, the hint far less.
            measure.rootView = CapturePillView(hint: hint, stacked: false, full: true)
            stacked = measure.fittingSize.width > max(capture.width, Self.oneLineWidth)
        }
        if isNew {
            settle(false)
        } else {
            update()
        }
    }

    /// The words moved — the translation was swapped for the original or back — so the
    /// least crowded corner may be another one.
    func relayout(capture: CGRect, visible: CGRect, words: [CGRect]) {
        guard hint != nil else { return }
        layout = (capture, visible, words)
        place()
    }

    func pointerMoved(to point: CGPoint) {
        let over = host.frame.contains(point)
        guard over != isPointedAt else { return }
        isPointedAt = over
        update()
    }

    /// Full again for a few seconds, then settled; or settled now.
    private func settle(_ settled: Bool) {
        isSettled = settled
        update()
        settling?.cancel()
        guard !settled, options.shortens else { return }
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.settle(true)
        }
    }

    private func update() {
        guard let hint else { return }
        // Pointed at from outside the capture it opens up; over the capture it makes way.
        let full = !isSettled || (isPointedAt && !isInside)
        let view = CapturePillView(hint: hint, stacked: stacked, full: full)
        if host.rootView != view { host.rootView = view }
        place()
        let alpha: CGFloat = hint.isEmpty ? 0 : isPointedAt && isInside ? 0.08 : 1
        guard host.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            host.animator().alphaValue = alpha
        }
    }

    private func place() {
        guard let layout else { return }
        let placed = Self.frame(size: host.fittingSize, beside: layout.capture, within: layout.visible,
                                avoiding: layout.words)
        host.frame = placed.frame
        isInside = placed.inside
    }

    /// Where a pill of `size` goes for a capture at `capture`, all in flipped
    /// coordinates. Outside the capture wherever the screen leaves room — below, above,
    /// to the right, to the left — centred on the capture along that side;
    /// failing that, inside it, in whichever corner or edge covers the least of `words`.
    nonisolated static func frame(size: CGSize, beside capture: CGRect, within visible: CGRect,
                                  avoiding words: [CGRect]) -> (frame: CGRect, inside: Bool) {
        let room = visible.insetBy(dx: gap, dy: gap)
        let x = min(max(capture.midX - size.width / 2, room.minX), room.maxX - size.width)
        let y = min(max(capture.midY - size.height / 2, room.minY), room.maxY - size.height)
        let outside = [
            CGRect(x: x, y: capture.maxY + gap, width: size.width, height: size.height),
            CGRect(x: x, y: capture.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: capture.maxX + gap, y: y, width: size.width, height: size.height),
            CGRect(x: capture.minX - gap - size.width, y: y, width: size.width, height: size.height),
        ]
        if let fits = outside.first(where: room.contains) { return (fits, false) }

        let area = capture.intersection(room).insetBy(dx: gap, dy: gap)
        let left = area.minX, right = area.maxX - size.width, center = area.midX - size.width / 2
        let top = area.minY, bottom = area.maxY - size.height
        let corners = [
            CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom), CGPoint(x: center, y: bottom),
            CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: center, y: top),
        ].map { CGRect(origin: $0, size: size) }
        let covered = corners.map { corner in
            words.reduce(CGFloat(0)) { total, word in
                let overlap = corner.intersection(word)
                return overlap.isNull ? total : total + overlap.width * overlap.height
            }
        }
        let best = covered.indices.min { covered[$0] < covered[$1] } ?? 0
        return (corners[best], true)
    }
}

/// Shows SwiftUI content without ever being the target of a click.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct CapturePillView: View, Equatable {
    let hint: CaptureHint
    /// The status above the keys rather than beside them.
    let stacked: Bool
    /// With the keys; settled, only what's essential.
    let full: Bool

    private var keysShown: [CaptureHint.Key] {
        // Settled with a status, the status says enough.
        full ? hint.keys : hint.status == nil ? hint.keys.filter(\.essential) : []
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            if stacked || keysShown.isEmpty || hint.status == nil {
                status
                keys
            } else {
                HStack(spacing: 10) {
                    status
                    Rectangle()
                        .fill(.secondary.opacity(0.4))
                        .frame(width: 1, height: 12)
                    keys
                }
            }
            ForEach(hint.notes, id: \.text) { note in
                Label {
                    Text(note.text).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: note.systemImage).foregroundStyle(Color.accent)
                }
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Nearly opaque, in the system's own window colour: it has to read over any page,
        // light or dark, busy or plain. A hairline, not a shadow, sets it off from the page.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .foregroundStyle(Color.ink)
        .tint(Color.accent)
    }

    @ViewBuilder
    private var status: some View {
        if let status = hint.status {
            HStack(spacing: 6) {
                if hint.isWorking, !status.isDownloading {
                    ProgressView().controlSize(.mini)
                }
                statusView(status)
            }
        }
    }

    @ViewBuilder
    private var keys: some View {
        if !keysShown.isEmpty {
            HStack(spacing: 10) {
                ForEach(keysShown, id: \.key) { key in
                    HStack(spacing: 4) {
                        Keycap(key.key, size: 11)
                        Text(key.action)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusView(_ status: CaptureHint.Status) -> some View {
        switch status {
        case .translating(let from, let into):
            HStack(spacing: 4) {
                if let from { Text(from).fontWeight(.semibold) }
                Text("→").foregroundStyle(.secondary)
                Text(into).fontWeight(.semibold)
            }
        case .downloading(let pair, let progress):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(Color.accent)
                Text(pair)
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 64)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
        case .unchanged(let message):
            Text(message).fontWeight(.semibold)
        }
    }
}

private extension CaptureHint.Status {
    var isDownloading: Bool {
        if case .downloading = self { true } else { false }
    }
}
