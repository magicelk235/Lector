import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Popovers over a capture: "Look Up" on a word — the word, how it's read, what it is in
/// the user's language and what the Mac's dictionaries say of it — and any other popover
/// shown beside a word. One at a time; a new one replaces the last.
///
/// A popover's window is a child of the capture window it's shown from and takes that
/// window's level, so it shows over Lector's screen-saver-level capture windows rather
/// than behind them (checked: both end up at 1000, the popover in front).
@MainActor
enum LookupPopover {
    private static var current: Shown?

    /// Whether the popover on screen has a text field being typed in. Its keys reach it
    /// through the capture window — `NSApp.keyWindow` stays that window, and its
    /// `sendEvent` sees them first — so a capture window that takes keys of its own in
    /// `sendEvent` must let them through while this is true.
    static var isEditing: Bool {
        guard let window = current?.popover.contentViewController?.view.window, window.isVisible,
              let editor = window.firstResponder as? NSTextView
        else { return false }
        return editor.isEditable
    }

    /// Shows a transient NSPopover anchored to `rect` (in `view`'s coordinates) with: the
    /// term (large, selectable), its reading, the translation (spinner until
    /// `translation.translations.first` is non-nil; "Couldn't translate" on `.failed`
    /// status; hidden when `translation` is nil), the dictionary definition (scrollable,
    /// capped height, hidden when nil), and an "Open in Dictionary" button (dict:// URL
    /// with the term percent-encoded), which also calls `onOpenDictionary`: Dictionary.app
    /// would open behind the capture, so the capture should close. Closing: the popover's
    /// own transient behaviour; Esc.
    static func show(term: String, language: Locale.Language?, translation: TranslationJob?,
                     relativeTo rect: CGRect, of view: NSView, onOpenDictionary: @escaping () -> Void) {
        let popover = NSPopover()
        popover.behavior = .transient
        let content = LookupView(term: term,
                                 reading: WordLookup.reading(of: term, language: language),
                                 definition: WordLookup.definition(of: term),
                                 translation: translation) { [weak popover] in
            popover?.close()
            onOpenDictionary()
        }
        let host = NSHostingController(rootView: content)
        // The popover takes the content's height: short for a word with no definition,
        // up to the definition's cap for one with a long entry.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        present(popover, relativeTo: rect, of: view)
    }

    /// Shows any popover by `rect` in `view`, above Lector's capture windows: below it
    /// where there's room. Esc closes it, before the capture window would end the
    /// capture with it.
    ///
    /// Keys typed into a text field in it work without activating Lector: the capture
    /// window keeps key focus and AppKit forwards them to the popover's field (see
    /// `isEditing`). SwiftUI's first text field is focused as the popover opens, so it
    /// can be typed in straight away; clicking into the popover does activate Lector,
    /// as a popover's window can't be made non-activating.
    static func present(_ popover: NSPopover, relativeTo rect: CGRect, of view: NSView) {
        current?.popover.close()
        current = Shown(popover: popover)
        // `.maxY` is the bottom edge only in a flipped view.
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    /// A popover on screen, and the Esc that closes it. Keys go to the capture window
    /// under it, which would take Esc to end the whole capture; this sees the key first.
    @MainActor
    private final class Shown {
        let popover: NSPopover
        private var monitor: Any?
        private var closing: (any NSObjectProtocol)?

        init(popover: NSPopover) {
            self.popover = popover
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Hidden along with the capture window it belongs to, it's no longer
                // what Esc is for.
                guard event.keyCode == UInt16(kVK_Escape), let self,
                      self.popover.contentViewController?.view.window?.isVisible == true
                else { return event }
                self.popover.close()
                return nil
            }
            // An observer rather than the delegate, which is the caller's.
            closing = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                                                             object: popover, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        private func end() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let closing { NotificationCenter.default.removeObserver(closing) }
            monitor = nil
            closing = nil
            if LookupPopover.current === self { LookupPopover.current = nil }
        }
    }
}

private struct LookupView: View {
    let term: String
    let reading: String?
    let definition: String?
    let translation: TranslationJob?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .naturalDirection(of: term)
                if let reading {
                    Text(reading)
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                        .naturalDirection(of: reading)
                }
            }
            if let translation {
                TranslationLine(job: translation)
            }
            if let definition {
                Divider()
                ScrollView {
                    Text(definition)
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                        .naturalDirection(of: definition)
                }
                // As tall as the entry up to the cap, rather than always the cap.
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Open in Dictionary") {
                    if let url = Self.dictionaryURL(for: term) { NSWorkspace.shared.open(url) }
                    close()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accent)
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .frame(width: 320)
        .optionalAppleTranslation(for: translation)
    }

    /// Dictionary.app at `term`. Everything but ASCII letters and digits is escaped: the
    /// term is the URL's whole path, and a "/" or "?" in it would end the term early.
    static func dictionaryURL(for term: String) -> URL? {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard let escaped = term.addingPercentEncoding(withAllowedCharacters: plain) else { return nil }
        return URL(string: "dict://" + escaped)
    }
}

/// The term in the user's language, as the job brings it.
private struct TranslationLine: View {
    let job: TranslationJob

    var body: some View {
        if let text = job.translations.first ?? nil {
            Text(text)
                .font(.body)
                .foregroundStyle(Color.ink)
                .naturalDirection(of: text)
        } else {
            switch job.status {
            case .working, .downloading:
                ProgressView()
                    .controlSize(.small)
            case .failed:
                Text("Couldn't translate")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            // Finished with nothing to show: already in the user's language, or not words.
            case .done, .sameLanguage, .nothingToTranslate:
                EmptyView()
            }
        }
    }
}

private extension View {
    /// Apple's session is handed out only to a view on screen, and this is the one the
    /// translation is shown in.
    @ViewBuilder
    func optionalAppleTranslation(for job: TranslationJob?) -> some View {
        if let job { appleTranslation(for: job) } else { self }
    }

    /// Lays `text` out in its own direction, right-to-left for Hebrew or Arabic, whatever
    /// the system's: aligned to the side it starts from, wrapping toward the other.
    func naturalDirection(of text: String) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .environment(\.layoutDirection, text.startsRightToLeft ? .rightToLeft : .leftToRight)
    }
}

private extension String {
    /// Whether the first letter with a direction of its own is Hebrew, Arabic or another
    /// right-to-left script's.
    var startsRightToLeft: Bool {
        for scalar in unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                return false
            }
        }
        return false
    }
}
