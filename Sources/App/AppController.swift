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
    let license: LicenseManager
    let usage: UsageMeter

    var onNeedsPermission: (() -> Void)?
    /// A shortcut was refused because the plan's limit for it was reached.
    var onLimit: ((Limit) -> Void)?
    /// The user picked the language an app's text is in, by bundle identifier, or went
    /// back to detecting it (nil): to be remembered in the settings.
    var onChooseSource: ((_ app: String, _ language: String?) -> Void)?
    /// A translation got going: into `target`, from the language most of the text is in
    /// (nil for live translation, which reads it later): for the language pickers to
    /// offer first.
    var onTranslate: ((_ target: String, _ source: Locale.Language?) -> Void)?
    /// An app's glossary changed from a capture: to be saved in the settings, an empty
    /// one removed.
    var onChangeGlossary: ((_ app: String, _ terms: [GlossaryTerm]) -> Void)?
    /// Live translation watched an area in an app's window, by bundle identifier: to be
    /// remembered in the settings, so that the live shortcut there watches it again.
    var onRememberLiveArea: ((_ app: String, _ area: LiveArea) -> Void)?
    /// Names seen often in each app's text since launch, offered for its glossary.
    let names = NameSuggestions()

    /// The live translation running, if one is.
    private(set) var live: LiveTranslation?

    private var picker: PickerWindow?
    /// True while the system screenshot crosshair is on screen.
    private var isCapturing = false
    private var overlay: TranslationOverlayWindow?
    /// The app the overlay's capture came from.
    private var overlayApp: String?
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

    init(settings: AppSettings, license: LicenseManager, usage: UsageMeter) {
        self.settings = settings
        self.license = license
        self.usage = usage
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
        let glossaryChanged = settings.glossaries != self.settings.glossaries
        self.settings = settings
        offline.prefetchesPacks = settings.prefetchesPacks
        if shortcutsChanged { registerHotKeys() }
        // A term added or changed over the overlay, or in Settings while it's up, shows there at once.
        if glossaryChanged, let overlay {
            overlay.glossaryChanged(glossary(for: overlayApp))
        }
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

    /// `remembering`: live translation may go back to the area remembered for the app in
    /// front instead of having one drawn.
    func begin(_ purpose: Purpose, remembering: Bool = true) {
        // The live shortcut again stops what it started — or, just after it went back to a
        // remembered area, stops it to have a new one drawn.
        var remembering = remembering
        if purpose == .live, live != nil {
            let redraws = redrawsUntil.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false
            stopLive()
            guard redraws else { return }
            remembering = false
        }
        // The system crosshair is already up; a second press shouldn't stack another.
        guard !isCapturing else { return }
        if let limit = limit(for: purpose) {
            onLimit?(limit)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            onNeedsPermission?()
            return
        }
        cancel()
        sourceApp = Self.frontmostApp()
        if purpose == .live, remembering, watchRemembered() { return }
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

    /// Something on screen or under way that an app update would cut short.
    var isBusy: Bool { isCapturing || live != nil || picker != nil || overlay != nil }

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
                return
            }
            usage.record(.grab)
            if text.isSingleLine {
                Self.copy(text.text, near: pointer)
            } else {
                let rect = await located
                guard !Task.isCancelled else { return }
                showPicker(capture.image, at: rect, text: text)
            }
        }
    }

    private func showPicker(_ image: CGImage, at rect: CGRect, text: RecognizedText) {
        let blocks = Paragraphs.blocks(text)
        let window = PickerWindow(image: image, rect: rect, text: text, paragraphs: blocks.map(\.lines),
                                  hint: .picking, pill: settings.pill)
        let app = sourceApp
        window.picker.onCancel = { [weak self] in self?.closePicker() }
        window.picker.onCopy = { [weak self] copied in
            self?.closePicker()
            Self.copy(copied, near: rect)
        }
        // What the clicked word's paragraph is in, told as a translation would tell it,
        // the whole capture together: kanji among kana elsewhere on screen are Japanese.
        window.picker.onContextMenu = { [weak self, weak window] term, line, anchor in
            guard let self, let window else { return nil }
            let paragraph = blocks.firstIndex { $0.lines.contains(line) }
            let language = paragraph.flatMap {
                LanguageDetector.languages(of: blocks.map(\.text), choosing: chosenSource(for: app)).languages[$0]
            }
            return WordMenu.menu(for: term, language: language, isOriginal: true, actions: wordActions(app: app),
                                 anchor: anchor, in: window.picker)
        }
        // Only while this picker is the one up: once the overlay has taken over, a Tab
        // that still reached it must not open a second overlay over the first.
        window.picker.onTranslate = { [weak self, weak window] in
            guard let self, let window, picker === window else { return }
            if let limit = limit(for: .translate) {
                closePicker()
                onLimit?(limit)
                return
            }
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
            usage.record(.translation)
            if let app { names.note(blocks.map(\.text), app: app) }
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
        usage.record(.translation)
        if let app { names.note(blocks.map(\.text), app: app) }
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
                                              pill: settings.pill, actions: wordActions(app: app))
        window.picker.onCancel = { [weak self] in self?.closeOverlay() }
        window.picker.onCopy = { [weak self] copied in
            self?.closeOverlay()
            Self.copy(copied, near: rect)
        }
        window.onChooseSource = { [weak self] language in
            guard let app else { return }
            self?.onChooseSource?(app, language?.minimalIdentifier)
        }
        if let app {
            window.suggestedName = names.offer(for: app, in: blocks.map(\.text), excluding: glossary(for: app))
            window.onKeepName = { [weak self] name in self?.setTerm(.keep(name), for: app) }
        }
        overlay = window
        overlayApp = app
        window.present()
        updateEscape()
    }

    private func closeOverlay() {
        guard let overlay else { return }
        overlay.job.cancel()
        overlay.dismiss()
        self.overlay = nil
        overlayApp = nil
        updateEscape()
    }

    private func makeJob() -> TranslationJob {
        let job = TranslationJob(target: settings.targetLanguage, offline: offline, appleSessions: appleSessions,
                                 memory: memory)
        let app = sourceApp
        job.glossary = glossary(for: app)
        let target = settings.targetLanguage
        job.onSourceDetected = { [weak self] source in
            self?.lastSource = source
            if let app { self?.lastSources[app] = source }
            self?.onTranslate?(target, source)
        }
        return job
    }

    // MARK: Glossary and lookup

    private func glossary(for app: String?) -> [GlossaryTerm] {
        app.flatMap { settings.glossaries[$0] } ?? []
    }

    /// Adds `term` to `app`'s glossary, or replaces the one with the same original.
    func setTerm(_ term: GlossaryTerm, for app: String) {
        var terms = glossary(for: app)
        if let index = terms.firstIndex(matching: term.original) {
            terms[index] = term
        } else {
            terms.append(term)
        }
        onChangeGlossary?(app, terms)
    }

    func removeTerm(_ original: String, for app: String) {
        var terms = glossary(for: app)
        terms.removeAll { $0.original.compare(original, options: .caseInsensitive) == .orderedSame }
        onChangeGlossary?(app, terms)
    }

    private func wordActions(app: String?) -> WordActions {
        WordActions(
            app: app, target: settings.targetLanguage,
            lookUp: { [weak self] term, language, anchor, view in self?.lookUp(term, in: language, at: anchor, of: view) },
            glossary: { [weak self] in self?.glossary(for: app) ?? [] },
            setTerm: { [weak self] term in if let app { self?.setTerm(term, for: app) } },
            removeTerm: { [weak self] original in if let app { self?.removeTerm(original, for: app) } })
    }

    /// The popover for a looked-up word, with its translation: from `language` when
    /// that's known, else from what the word is detected to be in. A look-up isn't a
    /// capture and doesn't count against the plan's translations.
    private func lookUp(_ term: String, in language: Locale.Language?, at anchor: CGRect, of view: NSView) {
        let target = Locale.Language(identifier: settings.targetLanguage)
        var job: TranslationJob?
        if language.map({ !LanguageDetector.same($0, target) }) ?? true {
            let started = TranslationJob(target: settings.targetLanguage, offline: offline,
                                         appleSessions: appleSessions, memory: memory)
            started.start(paragraphs: [term], choosing: language, firmly: language != nil)
            job = started
        }
        LookupPopover.show(term: term, language: language, translation: job, relativeTo: anchor, of: view,
                           onOpenDictionary: { [weak self] in self?.cancel() })
    }

    /// What the user said this app's text is in, if they did.
    private func chosenSource(for app: String?) -> Locale.Language? {
        app.flatMap { settings.sourceLanguages[$0] }.map { Locale.Language(identifier: $0) }
    }

    /// Why the plan won't let `purpose` start now, if it won't.
    private func limit(for purpose: Purpose) -> Limit? {
        license.tier.limit(for: purpose, grabs: usage.used(.grab), translations: usage.used(.translation))
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

    /// Until this time the live shortcut stops live translation to have a new area drawn,
    /// rather than only stopping it: set when it went back to a remembered area, for as
    /// long as the message offering that is up.
    private var redrawsUntil: TimeInterval?

    /// The region drawn with the crosshair is found on screen, as for the overlay, and
    /// watched from then on. Drawn in a window, it's watched in that window, which the
    /// translation then follows, and it's remembered for the window's app; across windows
    /// or out on the desktop, it's watched where it is on the display.
    private func startLive(_ capture: ScreenCapture) {
        let app = sourceApp
        work = Task {
            let rect = await CaptureLocator.locate(capture)
            guard !Task.isCancelled else { return }
            guard let window = WindowList.holding(rect, among: WindowList.onScreen(),
                                                  own: ProcessInfo.processInfo.processIdentifier)
            else {
                await watch(.screen(rect), first: capture.image, app: app)
                return
            }
            // What little of the area was past the window's edge is left out.
            let kept = rect.intersection(window.frame)
            let area = LiveArea(kept, in: window.frame)
            // The text is the window's app's, whether that app was in front or not.
            let owner = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier
            let first = LiveTranslation.crop(capture.image, of: rect, to: kept) ?? capture.image
            if await watch(.window(window, area), first: first, app: owner ?? app), let owner {
                onRememberLiveArea?(owner, area)
            }
        }
    }

    /// The live shortcut in an app with a remembered area watches that area of the app's
    /// front window again, without the crosshair. False when there's nothing to watch — no
    /// area remembered for the app, none of its windows on screen — and one is drawn.
    private func watchRemembered() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, let app = front.bundleIdentifier,
              app == sourceApp, let area = settings.liveAreas[app],
              let window = WindowList.frontmost(of: front.processIdentifier, among: WindowList.onScreen())
        else { return false }
        warmTranslation()
        work = Task {
            guard let first = try? await LiveTranslation.snapshot(of: area, in: window) else {
                // As if nothing were remembered: the crosshair, to draw the area.
                if !Task.isCancelled { begin(.live, remembering: false) }
                return
            }
            guard !Task.isCancelled else { return }
            await watch(.window(window, area), first: first, app: app, remembered: true)
        }
        return true
    }

    /// Starts live translation of `place`, translating `first` at once; `app` is whose
    /// text it is. Returns whether it's running; when it couldn't start, a message beside
    /// the region says why.
    @discardableResult
    private func watch(_ place: LiveTranslation.Place, first: CGImage, app: String?,
                       remembered: Bool = false) async -> Bool {
        let session = LiveTranslation(place, target: settings.targetLanguage, choosing: chosenSource(for: app),
                                      glossary: glossary(for: app), offline: offline, appleSessions: appleSessions,
                                      memory: memory, reader: reader)
        // Beside the region, never on it: anything over it would be read and translated
        // along with the text.
        session.onEnd = { [weak self, weak session] reason in
            guard let self, let session, live === session else { return }
            live = nil
            redrawsUntil = nil
            updateEscape()
            Toast.shared.show(reason, systemImage: "exclamationmark.triangle", beside: session.rect, kind: .notice)
        }
        live = session
        updateEscape()
        do {
            try await session.start(first: first)
            // Stopped while it was starting.
            guard live === session else { return false }
            onTranslate?(settings.targetLanguage, nil)
            let message = remembered
                ? "Live translation · same area · \(settings.liveShortcut.label) again to redraw"
                : "Live translation · Esc to stop"
            if remembered {
                redrawsUntil = ProcessInfo.processInfo.systemUptime + Toast.duration(for: message, kind: .confirmation)
            }
            Toast.shared.show(message, systemImage: "dot.radiowaves.left.and.right", beside: session.rect)
            return true
        } catch {
            guard live === session else { return false }
            stopLive()
            Toast.shared.show(error.localizedDescription, systemImage: "exclamationmark.triangle", beside: session.rect,
                              kind: .notice)
            return false
        }
    }

    func stopLive() {
        guard let live else { return }
        live.stop()
        self.live = nil
        redrawsUntil = nil
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
