import AppKit
import LectorKit
import SwiftUI

/// Translation written over the original, the way Google Lens does it — for every
/// capture, one line or many.
///
/// It is the word picker, showing the translation: each paragraph is painted over in
/// its own background colour and rewritten in the target language, and the translated
/// words are picked exactly like recognised ones — drag across to select, ⌘C (or
/// Return) to copy the selection, double-click for a paragraph, Esc or a click outside
/// to close. Space flips to the original and back.
///
/// Paragraphs are repainted as they arrive — an instant offline draft first where
/// there is one, then Apple's version one paragraph at a time — but never in the middle
/// of a drag. Anything that needs saying (already in your language, a pack
/// downloading, can't translate) is a brief message, not a panel.
@MainActor
final class TranslationOverlayWindow: PickerWindow {
    let job: TranslationJob
    private let original: (image: CGImage, text: RecognizedText)
    private let blocks: [Paragraphs.Block]
    private let screenRect: CGRect
    private var translated: TranslationRenderer.Rendering?
    private var showsOriginal = false
    private var announced: TranslationJob.Status?
    private let spinner = NSProgressIndicator()

    /// `rect` is where the capture was on screen, in global AppKit coordinates.
    init(job: TranslationJob, image: CGImage, rect: CGRect, text: RecognizedText) {
        self.job = job
        original = (image, text)
        blocks = Paragraphs.blocks(text)
        screenRect = rect
        super.init(image: image, rect: rect, text: text)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.sizeToFit()
        spinner.frame.origin = CGPoint(x: picker.rect.maxX - spinner.frame.width - 8, y: picker.rect.minY + 8)
        picker.addSubview(spinner)
        spinner.startAnimation(nil)

        // Invisible: carries Apple's session where one is needed, and reports changes.
        let driver = NSHostingView(rootView: TranslationDriver(job: job) { [weak self] in self?.jobChanged() })
        driver.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        picker.addSubview(driver)
    }

    /// The paragraphs, in the order the job translates them.
    var paragraphs: [String] { blocks.map(\.text) }

    private func jobChanged() {
        repaint()
        announce()
    }

    private func repaint() {
        guard job.translations.contains(where: { $0 != nil }) else { return }
        // A swap mid-drag would pull the words out from under the pointer.
        if picker.isPressing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.repaint() }
            return
        }
        guard let rendering = TranslationRenderer.render(
            over: original.image, original: original.text, blocks: blocks, translations: job.translations,
            rightToLeft: job.target.characterDirection == .rightToLeft)
        else { return }
        translated = rendering
        if !showsOriginal { picker.show(image: rendering.image, text: rendering.text) }
    }

    private func announce() {
        let status = job.status
        switch status {
        case .working:
            return
        case .downloading(let pair):
            if announced != status {
                Toast.shared.show("Downloading \(pair) language pack…", systemImage: "arrow.down.circle",
                                  near: screenRect)
            }
        case .done:
            stopSpinner()
        case .sameLanguage:
            stopSpinner()
            if announced != status {
                Toast.shared.show("Already in \(Languages.name(job.target))", systemImage: "character.bubble",
                                  near: screenRect)
            }
        case .failed(let message):
            stopSpinner()
            if announced != status {
                Toast.shared.show(message, systemImage: "exclamationmark.triangle", near: screenRect)
                picker.onCancel?()
            }
        }
        announced = status
    }

    private func stopSpinner() {
        spinner.stopAnimation(nil)
        spinner.removeFromSuperview()
    }

    /// Space flips between translation and original; everything else is the picker's.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 49, let translated {
            showsOriginal.toggle()
            if showsOriginal {
                picker.show(image: original.image, text: original.text)
            } else {
                picker.show(image: translated.image, text: translated.text)
            }
            return
        }
        super.sendEvent(event)
    }
}

/// Hosts `.translationTask` for the job and calls back whenever it changes.
private struct TranslationDriver: View {
    let job: TranslationJob
    let changed: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .appleTranslation(for: job)
            .onChange(of: job.revision) { _, _ in changed() }
            .onChange(of: job.status, initial: true) { _, _ in changed() }
    }
}
