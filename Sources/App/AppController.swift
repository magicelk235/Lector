import AppKit
import LectorKit

/// Owns the two hotkeys and runs what they start: the system screenshot crosshair,
/// then copying (grab) or translating in place (translate) what the user picked.
@MainActor
@Observable
final class AppController {
    enum Purpose { case grab, translate }

    private(set) var settings: AppSettings
    /// Shortcuts another app already holds, so Settings can say so.
    private(set) var conflicts: Set<UInt32> = []

    let offline: OpusMTTranslator

    var onNeedsPermission: (() -> Void)?

    private var picker: PickerWindow?
    /// True while the system screenshot crosshair is on screen.
    private var isCapturing = false
    private var overlay: TranslationOverlayWindow?
    /// The language the last translation was from: the likeliest one next time, and
    /// the one to warm up while the user drags.
    private var lastSource: Locale.Language?
    private var work: Task<Void, Never>?
    private let reader = ScreenTextReader()
    private let appleSessions = AppleSessionCache()

    private static let grabID: UInt32 = 1
    private static let translateID: UInt32 = 2

    init(settings: AppSettings) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        offline = OpusMTTranslator(modelsDirectory: support
            .appendingPathComponent(AppConstants.supportFolder, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true))
    }

    func start() {
        registerHotKeys()
        warmUpRecognition()
    }

    /// The first Vision request a process makes loads and compiles its models, which
    /// was measured at around 25 seconds on macOS 27 (and ~0.1s for every call after).
    /// Paying that at launch, in the background, keeps it off the first ⌘⇧2.
    private func warmUpRecognition() {
        guard let sample = Self.warmUpImage() else { return }
        let reader = reader
        Task.detached(priority: .utility) {
            _ = try? await reader.read(sample)
        }
    }

    /// A few words of real text: a blank image can let Vision return before it has
    /// loaded anything.
    private static func warmUpImage() -> CGImage? {
        let size = CGSize(width: 320, height: 60)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: size))
        let text = NSAttributedString(string: "Warm up text", attributes: [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: 12, y: 18)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    func stop() {
        HotKeyCenter.shared.unregisterAll()
        cancel()
    }

    func apply(_ settings: AppSettings) {
        let shortcutsChanged = settings.grabShortcut != self.settings.grabShortcut
            || settings.translateShortcut != self.settings.translateShortcut
        self.settings = settings
        if shortcutsChanged { registerHotKeys() }
    }

    /// While a shortcut is being recorded the old one mustn't fire.
    func suspendHotKeys() {
        HotKeyCenter.shared.unregisterAll()
    }

    func resumeHotKeys() {
        registerHotKeys()
    }

    private func registerHotKeys() {
        var conflicts: Set<UInt32> = []
        if !HotKeyCenter.shared.register(id: Self.grabID, shortcut: settings.grabShortcut,
                                         handler: { [weak self] in self?.begin(.grab) }) {
            conflicts.insert(Self.grabID)
        }
        if !HotKeyCenter.shared.register(id: Self.translateID, shortcut: settings.translateShortcut,
                                         handler: { [weak self] in self?.begin(.translate) }) {
            conflicts.insert(Self.translateID)
        }
        self.conflicts = conflicts
    }

    var grabConflict: Bool { conflicts.contains(Self.grabID) }
    var translateConflict: Bool { conflicts.contains(Self.translateID) }

    // MARK: Flow

    func begin(_ purpose: Purpose) {
        // The system crosshair is already up; a second press shouldn't stack another.
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            onNeedsPermission?()
            return
        }
        cancel()
        isCapturing = true
        if purpose == .translate { warmTranslation() }
        work = Task {
            defer { isCapturing = false }
            do {
                guard let capture = try await SystemCapture.run(), !Task.isCancelled else { return }
                switch purpose {
                case .grab: grab(capture)
                case .translate: translate(capture)
                }
            } catch {
                Toast.shared.show(error.localizedDescription, systemImage: "exclamationmark.triangle",
                                  near: NSScreen.main?.frame ?? .zero)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        closePicker()
        closeOverlay()
    }

    /// Reading the text starts the moment the capture exists. Finding where the box was
    /// on screen runs alongside it, and a single copied line doesn't wait for it at all.
    private func grab(_ capture: ScreenCapture) {
        work = Task {
            async let reading = reader.read(capture.image)
            async let located = CaptureLocator.locate(capture)
            let text = (try? await reading) ?? .empty
            guard !Task.isCancelled else { return }
            let pointer = CGRect(origin: capture.pointer, size: .zero)
            if text.isEmpty {
                Toast.shared.show("No text found", systemImage: "text.magnifyingglass", near: pointer)
            } else if text.isSingleLine {
                Self.copy(text.text, near: pointer)
            } else {
                let rect = await located
                guard !Task.isCancelled else { return }
                showPicker(capture.image, at: rect, text: text)
            }
        }
    }

    private func showPicker(_ image: CGImage, at rect: CGRect, text: RecognizedText) {
        let window = PickerWindow(image: image, rect: rect, text: text)
        window.picker.onCancel = { [weak self] in self?.closePicker() }
        window.picker.onCopy = { [weak self] copied in
            self?.closePicker()
            Self.copy(copied, near: rect)
        }
        picker = window
        window.present()
    }

    private func closePicker() {
        picker?.dismiss()
        picker = nil
    }

    /// Every capture is translated in place, over the original.
    private func translate(_ capture: ScreenCapture) {
        let job = TranslationJob(target: settings.targetLanguage, offline: offline, appleSessions: appleSessions)
        job.onSourceDetected = { [weak self] source in self?.lastSource = source }

        work = Task {
            async let reading = reader.read(capture.image)
            async let located = CaptureLocator.locate(capture)
            let text = (try? await reading) ?? .empty
            guard !Task.isCancelled else { return }
            guard !text.isEmpty else {
                Toast.shared.show("No text found", systemImage: "text.magnifyingglass",
                                  near: CGRect(origin: capture.pointer, size: .zero))
                return
            }
            let rect = await located
            guard !Task.isCancelled else { return }
            showOverlay(job: job, image: capture.image, at: rect, text: text)
        }
    }

    private func showOverlay(job: TranslationJob, image: CGImage, at rect: CGRect, text: RecognizedText) {
        let window = TranslationOverlayWindow(job: job, image: image, rect: rect, text: text)
        window.picker.onCancel = { [weak self] in self?.closeOverlay() }
        window.picker.onCopy = { [weak self] copied in
            self?.closeOverlay()
            Self.copy(copied, near: rect)
        }
        overlay = window
        window.present()
        job.start(paragraphs: window.paragraphs)
    }

    /// Starts loading the translation models for the likeliest language pair the moment
    /// ⌘⇧1 is pressed, so the time the user spends dragging pays for it.
    private func warmTranslation() {
        let target = Locale.Language(identifier: settings.targetLanguage)
        let source = lastSource ?? LanguageDetector.defaultPreferred
            .map { Locale.Language(identifier: $0) }
            .first { $0.languageCode != target.languageCode }
        guard let source else { return }
        appleSessions.warm(from: source, to: target)
        let offline = offline
        Task.detached(priority: .userInitiated) {
            guard await offline.availability(from: source, to: target) == .ready else { return }
            _ = try? await offline.translate("Hello", from: source, to: target)
        }
    }

    private func closeOverlay() {
        guard let overlay else { return }
        overlay.job.cancel()
        overlay.dismiss()
        self.overlay = nil
    }

    private static func copy(_ text: String, near rect: CGRect) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.shared.show("Copied", systemImage: "checkmark.circle.fill", near: rect)
    }
}
