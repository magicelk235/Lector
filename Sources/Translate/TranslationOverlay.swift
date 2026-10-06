import AppKit
import LectorKit
import SwiftUI

/// Translation written over the original, the way Google Lens does it — for every
/// capture, one line or many.
///
/// It is the word picker, showing the translation: each paragraph is painted over in
/// its own background colour and rewritten in the target language, and the translated
/// words are picked exactly like recognised ones — drag across to select, ⌘C (or
/// Return) to copy the selection, or everything with nothing selected, double-click for
/// a paragraph, Esc or a click outside to close. Space flips to the original and back,
/// and a copy takes whichever is on screen. Tab tries the next language the text could
/// be in when the detected one is wrong, ⇧Tab the one before; after the last comes
/// detecting it again. Unlike the word picker, the words carry no marks until the
/// pointer is on them: the translation should read as text, not as a grid of boxes.
///
/// Paragraphs are repainted as they arrive — an instant offline draft first where
/// there is one, then Apple's version — but never in the middle of a drag. The pill
/// beside the capture says what is translated from and into, shows a pack downloading
/// with its progress for as long as it takes, and lists the keys. When nothing needed
/// translating there's nothing to show over the screen: a message says so and the
/// overlay closes.
@MainActor
final class TranslationOverlayWindow: PickerWindow {
    let job: TranslationJob
    /// The user picked a source language with Tab, or went back to detecting it (nil).
    var onChooseSource: ((Locale.Language?) -> Void)?

    private let original: (image: CGImage, text: RecognizedText, paragraphs: [Range<Int>])
    private let renderer: TranslationRenderer
    private let screenRect: CGRect
    private var translated: TranslationRenderer.Rendering?
    private var showsOriginal = false
    private var announced: TranslationJob.Status?
    /// A repaint is already queued for the next turn of the run loop.
    private var repaintQueued = false
    /// What Tab steps through: nil for detecting the language, then the languages the
    /// text could be in, likeliest first. Worked out on the first press, when the
    /// detection has run.
    private var choices: [Locale.Language?] = []
    private var choice = 0
    /// What detecting the language last came up with, which is what the nil choice gives.
    private var detected: Locale.Language?

    /// `rect` is where the capture was on screen, in global AppKit coordinates; `blocks`
    /// are `text`'s paragraphs, in the order `job` translates them.
    init(job: TranslationJob, image: CGImage, rect: CGRect, text: RecognizedText, blocks: [Paragraphs.Block],
         pill: PillOptions) {
        self.job = job
        let paragraphs = blocks.map(\.lines)
        original = (image, text, paragraphs)
        renderer = TranslationRenderer(capture: image, original: text, blocks: blocks,
                                       rightToLeft: job.target.characterDirection == .rightToLeft)
        screenRect = rect
        super.init(image: image, rect: rect, text: text, paragraphs: paragraphs,
                   hint: CaptureHint(status: .translating(from: nil, into: Languages.name(job.target)),
                                     isWorking: true, keys: CaptureHint.translating(showingOriginal: false)),
                   pill: pill)
        picker.copiesAllWhenNothingSelected = true
        picker.marksEveryWord = false

        // Invisible: carries Apple's session where one is needed, and reports changes.
        let driver = NSHostingView(rootView: TranslationDriver(job: job) { [weak self] in self?.jobChanged() })
        driver.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        picker.addSubview(driver)
    }

    /// The job may have finished before the overlay was on screen — text that was all in
    /// the target language already — and closing a window that isn't up yet would leave
    /// it to come up afterwards; so it's looked at again once it is.
    override func present() {
        super.present()
        jobChanged()
    }

    private func jobChanged() {
        // While detecting — before any Tab, or back at it — what it found is what the
        // detecting choice gives.
        if choices.isEmpty || choices[choice] == nil, let source = job.source {
            detected = source
        }
        scheduleRepaint()
        announce()
        updateHint()
    }

    /// Paragraphs of an offline draft land a few milliseconds apart; they're painted
    /// together, once per turn of the run loop, rather than once each.
    private func scheduleRepaint(after delay: TimeInterval = 0) {
        guard !repaintQueued else { return }
        repaintQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            repaintQueued = false
            repaint()
        }
    }

    private func repaint() {
        // A swap mid-drag would pull the words out from under the pointer.
        if picker.isPressing {
            scheduleRepaint(after: 0.15)
            return
        }
        guard job.translations.contains(where: { $0 != nil }) else {
            // Nothing translated (yet, or again after Tab): the capture as it was.
            if translated != nil, !showsOriginal { showOriginal() }
            translated = nil
            return
        }
        guard let rendering = renderer.render(job.translations) else { return }
        translated = rendering
        if !showsOriginal { showTranslation(rendering) }
    }

    private func showOriginal() {
        picker.show(image: original.image, text: original.text, paragraphs: original.paragraphs)
    }

    /// A rendering has one line per paragraph, each its own paragraph.
    private func showTranslation(_ rendering: TranslationRenderer.Rendering) {
        picker.show(image: rendering.image, text: rendering.text, paragraphs: [])
    }

    /// What can only be said once a capture is over goes in a message; the rest is the
    /// pill's. A capture the user hasn't changed the language of closes when there's
    /// nothing to show: the original under a dimmed screen would look like a translation
    /// that didn't happen. After a Tab it stays, so the next Tab can follow.
    private func announce() {
        guard isVisible else { return }
        let status = job.status
        defer { announced = status }
        guard announced != status, choices.isEmpty else { return }
        switch status {
        case .sameLanguage:
            close(saying: "Already in \(Languages.name(job.target))", systemImage: "character.bubble")
        case .nothingToTranslate:
            close(saying: "Nothing to translate", systemImage: "character.bubble")
        case .failed(let message):
            close(saying: message, systemImage: "exclamationmark.triangle", kind: .notice)
        case .working, .done, .downloading:
            break
        }
    }

    private func close(saying message: String, systemImage: String, kind: Toast.Kind = .confirmation) {
        Toast.shared.show(message, systemImage: systemImage, near: screenRect, kind: kind)
        picker.onCancel?()
    }

    private func updateHint() {
        let target = Languages.name(job.target)
        var hint = CaptureHint(keys: CaptureHint.translating(showingOriginal: showsOriginal))
        switch job.status {
        case .downloading(let pair, let progress):
            hint.status = .downloading(pair, progress: progress)
        case .sameLanguage:
            hint.status = .unchanged("Already in \(target)")
        case .nothingToTranslate:
            hint.status = .unchanged("Nothing to translate")
        case .working, .done, .failed:
            // What was actually translated from, most text first.
            let from = CaptureHint.sources(job.sourceLanguages.map { Languages.name($0) })
            hint.status = .translating(from: from, into: target)
            hint.isWorking = job.status == .working
        }
        for source in job.roughSources {
            hint.notes.append(.info("\(Languages.name(source)): rough translation"))
        }
        if let notice = job.notice { hint.notes.append(.warning(notice)) }
        if case .failed(let message) = job.status, message != job.notice { hint.notes.append(.warning(message)) }
        picker.showHint(hint)
    }

    /// The next language the text could be in, or with ⇧ the one before, translated
    /// from at once and remembered for the app it was captured from. Always one that
    /// differs from what is on screen: a language the translation already came from —
    /// detected, or remembered for the app — would change nothing. After the last
    /// language comes detecting it again.
    private func cycleSource(backwards: Bool) {
        if choices.isEmpty {
            var list: [Locale.Language?] = [nil]
            // Compared with their script: Simplified and Traditional Chinese are two choices.
            for language in job.sourceChoices
            where !list.contains(where: { $0.map { LanguageDetector.same($0, language) } ?? false }) {
                list.append(language)
            }
            choices = list
            choice = 0
        }
        let next = Self.nextChoice(after: choice, in: choices, backwards: backwards, shown: job.source,
                                   detected: detected)
        guard let next else { return }
        choice = next
        let chosen = choices[next]
        announced = nil
        job.restart(choosing: chosen)
        onChooseSource?(chosen)
        updateHint()
    }

    /// The index Tab moves to from `current` in `choices` (nil there is detecting), or
    /// nil when every other choice would show the same as now: `shown` is the language
    /// on screen, `detected` what detecting gives.
    nonisolated static func nextChoice(after current: Int, in choices: [Locale.Language?], backwards: Bool,
                                       shown: Locale.Language?, detected: Locale.Language?) -> Int? {
        guard choices.count > 1 else { return nil }
        var next = current
        repeat {
            next = (next + (backwards ? choices.count - 1 : 1)) % choices.count
            guard let gives = choices[next] ?? detected, let shown else { return next }
            if !LanguageDetector.same(gives, shown) { return next }
        } while next != current
        return nil
    }

    /// Space flips between translation and original; Tab and ⇧Tab change the language
    /// translated from; everything else is the picker's.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 49 {
            if let translated {
                showsOriginal.toggle()
                if showsOriginal {
                    showOriginal()
                } else {
                    showTranslation(translated)
                }
                updateHint()
            }
            return
        }
        if event.type == .keyDown, event.keyCode == 48 {
            cycleSource(backwards: event.modifierFlags.contains(.shift))
            return
        }
        super.sendEvent(event)
    }
}

/// Hosts `.translationTask` for a job and calls back whenever it changes: the overlay's
/// and live translation's invisible link to their job.
struct TranslationDriver: View {
    let job: TranslationJob
    let changed: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .appleTranslation(for: job)
            .onChange(of: job.revision) { _, _ in changed() }
            .onChange(of: job.status, initial: true) { _, _ in changed() }
            .onChange(of: job.notice) { _, _ in changed() }
            .onChange(of: job.sourceLanguages) { _, _ in changed() }
            .onChange(of: job.roughSources) { _, _ in changed() }
    }
}
