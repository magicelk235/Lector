import AppKit
import Carbon.HIToolbox
import LectorKit

/// Owns the three hotkeys and runs what they start: the system screenshot crosshair,
/// then copying (grab), translating in place (translate) or translating live (live)
/// what the user picked.
@MainActor
@Observable
final class AppController {
    enum Purpose { case grab, translate, live }

    private(set) var settings: AppSettings
    /// Shortcuts another app already holds, so Settings can say so.
    private(set) var conflicts: Set<UInt32> = []

    let offline: OpusMTTranslator

    var onNeedsPermission: (() -> Void)?
    /// The user picked the language an app's text is in, by bundle identifier, or went
    /// back to detecting it (nil): to be remembered in the settings.
    var onChooseSource: ((_ app: String, _ language: String?) -> Void)?
    /// A translation got going: into `target`, from the language most of the text is in
    /// (nil for live translation, which reads it later): for the language pickers to
    /// offer first.
    var onTranslate: ((_ target: String, _ source: Locale.Language?) -> Void)?

    /// The live translation running, if one is.
    private(set) var live: LiveTranslation?

    private var picker: PickerWindow?
    /// True while the system screenshot crosshair is on screen.
    private var isCapturing = false
    private var overlay: TranslationOverlayWindow?
    /// The language the last translation was from: the likeliest one next time, and
    /// the one to warm up while the user drags.
    private var lastSource: Locale.Language?
    /// The same per app, since launch: a game's text is in the game's language.
    private var lastSources: [String: Locale.Language] = [:]
    /// The app in front when the capture under way began: whose text it is.
    private var sourceApp: String?
    private var work: Task<Void, Never>?
    private var escapeRegistered = false
    private let reader = ScreenTextReader()
    private let appleSessions = AppleSessionCache()
    private let memory = TranslationMemory()

    private static let grabID: UInt32 = 1
    private static let translateID: UInt32 = 2
    private static let liveID: UInt32 = 3
    private static let escapeID: UInt32 = 4

    init(settings: AppSettings) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        offline = OpusMTTranslator(modelsDirectory: support
            .appendingPathComponent(AppConstants.supportFolder, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true))
        offline.prefetchesPacks = settings.prefetchesPacks
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
        escapeRegistered = false
        cancel()
        stopLive()
    }

    func apply(_ settings: AppSettings) {
        let shortcutsChanged = settings.grabShortcut != self.settings.grabShortcut
            || settings.translateShortcut != self.settings.translateShortcut
            || settings.liveShortcut != self.settings.liveShortcut
        self.settings = settings
        offline.prefetchesPacks = settings.prefetchesPacks
        if shortcutsChanged { registerHotKeys() }
    }

    /// While a shortcut is being recorded the old one mustn't fire.
    func suspendHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        escapeRegistered = false
    }

    func resumeHotKeys() {
        registerHotKeys()
        updateEscape()
    }

    private func registerHotKeys() {
        var conflicts: Set<UInt32> = []
        let shortcuts: [(UInt32, Shortcut, Purpose)] = [
            (Self.grabID, settings.grabShortcut, .grab),
            (Self.translateID, settings.translateShortcut, .translate),
            (Self.liveID, settings.liveShortcut, .live),
        ]
        for (id, shortcut, purpose) in shortcuts {
            if !HotKeyCenter.shared.register(id: id, shortcut: shortcut, handler: { [weak self] in self?.begin(purpose) }) {
                conflicts.insert(id)
            }
        }
        self.conflicts = conflicts
    }

    var grabConflict: Bool { conflicts.contains(Self.grabID) }
    var translateConflict: Bool { conflicts.contains(Self.translateID) }
    var liveConflict: Bool { conflicts.contains(Self.liveID) }

    // MARK: Flow

    func begin(_ purpose: Purpose) {
        // The live shortcut again stops what it started.
        if purpose == .live, live != nil {
            stopLive()
            return
        }
        // The system crosshair is already up; a second press shouldn't stack another.
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            onNeedsPermission?()
            return
        }
        cancel()
        sourceApp = Self.frontmostApp()
        isCapturing = true
        updateEscape()
        if purpose != .grab { warmTranslation() }
        work = Task {
            defer {
                isCapturing = false
                updateEscape()
            }
            do {
                guard let capture = try await SystemCapture.run(), !Task.isCancelled else { return }
                switch purpose {
                case .grab: grab(capture)
                case .translate: translate(capture)
                case .live: startLive(capture)
                }
            } catch {
                Toast.shared.show(error.localizedDescription, systemImage: "exclamationmark.triangle",
                                  near: NSScreen.main?.frame ?? .zero, kind: .notice)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        closePicker()
        closeOverlay()
    }

    /// The app the user is in, whose text is about to be captured; nil for Lector itself.
    private static func frontmostApp() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app.bundleIdentifier
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
                Toast.shared.show("No text found", systemImage: "text.magnifyingglass", near: pointer, kind: .notice)
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
        let window = PickerWindow(image: image, rect: rect, text: text,
                                  paragraphs: Paragraphs.blocks(text).map(\.lines), hint: .picking,
                                  pill: settings.pill)
        let app = sourceApp
        window.picker.onCancel = { [weak self] in self?.closePicker() }
        window.picker.onCopy = { [weak self] copied in
            self?.closePicker()
            Self.copy(copied, near: rect)
        }
        // Only while this picker is the one up: once the overlay has taken over, a Tab
        // that still reached it must not open a second overlay over the first.
        window.picker.onTranslate = { [weak self, weak window] in
            guard let self, let window, picker === window else { return }
            translateInPlace(image, at: rect, text: text, app: app)
        }
        picker = window
        window.present()
        updateEscape()
        // Tab may be next, with no drag to hide loading the models behind.
        warmTranslation()
    }

    private func closePicker() {
        picker?.dismiss()
        picker = nil
        updateEscape()
    }

    /// Every capture is translated in place, over the original. Translating starts the
    /// moment the text is read; finding where the box was on screen, which only the
    /// overlay needs, goes on alongside it.
    private func translate(_ capture: ScreenCapture) {
        let job = makeJob()
        let app = sourceApp
        work = Task {
            async let reading = reader.read(capture.image)
            async let located = CaptureLocator.locate(capture)
            let text = (try? await reading) ?? .empty
            guard !Task.isCancelled else { return }
            guard !text.isEmpty else {
                Toast.shared.show("No text found", systemImage: "text.magnifyingglass",
                                  near: CGRect(origin: capture.pointer, size: .zero), kind: .notice)
                return
            }
            let blocks = Paragraphs.blocks(text)
            job.start(paragraphs: blocks.map(\.text), choosing: chosenSource(for: app))
            let rect = await located
            guard !Task.isCancelled else {
                job.cancel()
                return
            }
            showOverlay(job: job, image: capture.image, at: rect, text: text, blocks: blocks, app: app)
        }
    }

    /// Tab in the word picker: the same capture translated where it is, without
    /// capturing or reading it again. The overlay opens over the picker, showing the
    /// same picture, and the picker goes from under it.
    private func translateInPlace(_ image: CGImage, at rect: CGRect, text: RecognizedText, app: String?) {
        let blocks = Paragraphs.blocks(text)
        let job = makeJob()
        job.start(paragraphs: blocks.map(\.text), choosing: chosenSource(for: app))
        showOverlay(job: job, image: image, at: rect, text: text, blocks: blocks, app: app)
        picker?.dismiss()
        picker = nil
        updateEscape()
    }

    private func showOverlay(job: TranslationJob, image: CGImage, at rect: CGRect, text: RecognizedText,
                             blocks: [Paragraphs.Block], app: String?) {
        closeOverlay()
        let window = TranslationOverlayWindow(job: job, image: image, rect: rect, text: text, blocks: blocks,
                                              pill: settings.pill)
        window.picker.onCancel = { [weak self] in self?.closeOverlay() }
        window.picker.onCopy = { [weak self] copied in
            self?.closeOverlay()
            Self.copy(copied, near: rect)
        }
        window.onChooseSource = { [weak self] language in
            guard let app else { return }
            self?.onChooseSource?(app, language?.minimalIdentifier)
        }
        overlay = window
        window.present()
        updateEscape()
    }

    private func closeOverlay() {
        guard let overlay else { return }
        overlay.job.cancel()
        overlay.dismiss()
        self.overlay = nil
        updateEscape()
    }

    private func makeJob() -> TranslationJob {
        let job = TranslationJob(target: settings.targetLanguage, offline: offline, appleSessions: appleSessions,
                                 memory: memory)
        let app = sourceApp
        let target = settings.targetLanguage
        job.onSourceDetected = { [weak self] source in
            self?.lastSource = source
            if let app { self?.lastSources[app] = source }
            self?.onTranslate?(target, source)
        }
        return job
    }

    /// What the user said this app's text is in, if they did.
    private func chosenSource(for app: String?) -> Locale.Language? {
        app.flatMap { settings.sourceLanguages[$0] }.map { Locale.Language(identifier: $0) }
    }

    /// Starts loading the translation models for the likeliest language pair the moment
    /// a shortcut is pressed, so the time the user spends dragging pays for it: the
    /// language picked for the app in front, else the one its text was last in, else
    /// the last one translated from at all, else one the user reads.
    private func warmTranslation() {
        let target = Locale.Language(identifier: settings.targetLanguage)
        let source = chosenSource(for: sourceApp)
            ?? sourceApp.flatMap { lastSources[$0] }
            ?? lastSource
            ?? LanguageDetector.defaultPreferred
                .map { Locale.Language(identifier: $0) }
                .first { $0.languageCode != target.languageCode }
        guard let source, source.languageCode != target.languageCode else { return }
        appleSessions.warm(from: source, to: target)
        let offline = offline
        Task.detached(priority: .userInitiated) {
            guard await offline.availability(from: source, to: target) == .ready else { return }
            _ = try? await offline.translate("Hello", from: source, to: target)
        }
    }

    // MARK: Live

    var isLive: Bool { live != nil }

    /// The region drawn with the crosshair is found on screen, as for the overlay, and
    /// watched from then on.
    private func startLive(_ capture: ScreenCapture) {
        let app = sourceApp
        work = Task {
            let rect = await CaptureLocator.locate(capture)
            guard !Task.isCancelled else { return }
            let session = LiveTranslation(rect: rect, target: settings.targetLanguage, choosing: chosenSource(for: app),
                                          offline: offline, appleSessions: appleSessions, memory: memory,
                                          reader: reader)
            // Beside the region, never on it: anything over it would be read and
            // translated along with the text.
            session.onEnd = { [weak self, weak session] reason in
                guard let self, live === session else { return }
                live = nil
                updateEscape()
                Toast.shared.show(reason, systemImage: "exclamationmark.triangle", beside: rect, kind: .notice)
            }
            live = session
            updateEscape()
            do {
                try await session.start(first: capture.image)
                onTranslate?(settings.targetLanguage, nil)
                Toast.shared.show("Live translation · Esc to stop",
                                  systemImage: "dot.radiowaves.left.and.right", beside: rect)
            } catch {
                guard live === session else { return }
                stopLive()
                Toast.shared.show(error.localizedDescription, systemImage: "exclamationmark.triangle", beside: rect,
                                  kind: .notice)
            }
        }
    }

    func stopLive() {
        guard let live else { return }
        live.stop()
        self.live = nil
        // A pack download it was reporting stops being news.
        Toast.shared.hide()
        updateEscape()
    }

    /// Esc stops live translation — but only while nothing else of Lector's wants Esc:
    /// the crosshair, the picker and the overlay each close with it, and a hot key would
    /// get to it before they could.
    private func updateEscape() {
        let wanted = live != nil && !isCapturing && picker == nil && overlay == nil
        if wanted, !escapeRegistered {
            escapeRegistered = HotKeyCenter.shared.register(
                id: Self.escapeID, shortcut: Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, key: "⎋"),
                handler: { [weak self] in self?.stopLive() })
        } else if !wanted, escapeRegistered {
            HotKeyCenter.shared.unregister(id: Self.escapeID)
            escapeRegistered = false
        }
    }

    private static func copy(_ text: String, near rect: CGRect) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.shared.show("Copied", systemImage: "checkmark.circle.fill", near: rect)
    }
}
