import AppKit
import LectorKit
import SwiftUI
import Translation

/// Translates the paragraphs of one capture as fast as the Mac allows, each from the
/// language it is in.
///
/// Apple's on-device translation is the good one, but it works through a capture a line
/// at a time at about a second a sentence — six paragraphs take four to six seconds
/// however they are sent (measured: batches, parallel sessions and one joined request
/// all serialise). The offline Opus-MT model does the same six in a quarter of a second,
/// less well.
///
/// So first the paragraphs are sorted out (`TranslationPlan`): those already in the
/// target language, and numbers, shortcuts, code and addresses, stay as they are, and
/// the rest go by the language each is in. Anything translated since launch shows at
/// once (`TranslationMemory`). For each language, when the offline pack for the pair is
/// on the Mac its draft goes up at once and Apple's version replaces it as it lands,
/// neighbouring paragraphs sent together so each is translated knowing the others
/// (`ContextWindows`). Without the pack, Apple's paragraphs appear as they come; the
/// pack is fetched for next time only if the user asked for drafts (`engines`). Pairs
/// Apple can't do at all go to the offline model alone, downloading it first if needed.
@MainActor
@Observable
final class TranslationJob {
    enum Status: Equatable {
        case working
        case done
        /// Everything with words in it is already in the target language.
        case sameLanguage
        /// Nothing but numbers, shortcuts, code and addresses.
        case nothingToTranslate
        /// Fetching a language pack before anything can be translated: the pair, e.g.
        /// "Czech → Hebrew", and how much of it is on the Mac, 0…1, or nil until known.
        case downloading(String, progress: Double?)
        case failed(String)
    }

    private(set) var status: Status = .working
    /// One per paragraph, in `Paragraphs.blocks` order; nil while the paragraph is still
    /// the original on screen: not reached yet, or left as it is.
    private(set) var translations: [String?] = []
    /// Bumped on every change to `translations`, for observers.
    private(set) var revision = 0
    /// The language most of the text is in, once known.
    private(set) var source: Locale.Language?
    /// Every language the capture is being translated from, most letters first: a page
    /// in eight languages is told as such, not by its largest one. Empty until the plan
    /// is made.
    private(set) var sourceLanguages: [Locale.Language] = []
    /// Languages translated only by a many-language pack, in `sourceLanguages` order:
    /// what comes out is rough, and the user should be told so. Filled in as each
    /// language's engine is settled.
    private(set) var roughSources: [Locale.Language] = []
    /// The language the user said the text is in, or nil to tell from the text.
    private(set) var chosenSource: Locale.Language?
    private var choiceIsFirm = false
    /// Something worth saying once about part of the capture — a language that can't be
    /// translated — while the rest is translated regardless.
    private(set) var notice: String?
    let target: Locale.Language
    /// Set to hand work to Apple through `.translationTask`: on macOS 15, and whenever
    /// Apple needs to ask the user to download a language.
    private(set) var appleConfiguration: TranslationSession.Configuration?

    /// Called with the source language once it's known, so the next capture can warm
    /// the right engine while the user is still dragging.
    var onSourceDetected: ((Locale.Language) -> Void)?

    private var texts: [String] = []
    /// Translations handed in with `start`, by paragraph.
    private var known: [Int: String] = [:]
    /// Whether each paragraph has its final translation, which a draft mustn't replace.
    private var isFinal: [Bool] = []
    /// Why Apple or a download failed, for when nothing could be translated at all.
    private var failure: String?
    /// Bumped by every start, so work left over from before a restart drops its results.
    private var generation = 0
    private let offline: OpusMTTranslator
    private let appleSessions: AppleSessionCache
    private let memory: TranslationMemory
    private var job: Task<Void, Never>?
    private var drafts: [Task<Void, Never>] = []
    /// Languages waiting their turn at `.translationTask`, which hands out one session at
    /// a time.
    private var viewQueue: [ViewRequest] = []

    init(target: String, offline: OpusMTTranslator, appleSessions: AppleSessionCache, memory: TranslationMemory) {
        self.target = Locale.Language(identifier: target)
        self.offline = offline
        self.appleSessions = appleSessions
        self.memory = memory
    }

    /// Languages to offer when the detection is wrong, likeliest first: never the
    /// target, and only languages written in the text's script, which a choice can apply to.
    var sourceChoices: [Locale.Language] {
        let words = texts.filter { Untranslatable.kind(of: $0) == nil }.joined(separator: "\n")
        return LanguageDetector.candidates(for: words, excluding: target, limit: 10)
            .filter { LanguageDetector.isWritten(words, in: $0) }
            .prefix(5).map { $0 }
    }

    /// - Parameters:
    ///   - chosen: the language the user says the text is in, or nil to tell.
    ///   - firmly: chosen for this very capture rather than remembered from an earlier
    ///     one, so it applies even where the text plainly reads otherwise.
    ///   - known: translations already shown for some paragraphs, by index — live
    ///     translation's for text it has read before — which are kept as they are.
    func start(paragraphs: [String], choosing chosen: Locale.Language? = nil, firmly: Bool = false,
               known: [Int: String] = [:]) {
        texts = paragraphs
        chosenSource = chosen
        choiceIsFirm = firmly
        self.known = known
        generation += 1
        translations = Array(repeating: nil, count: paragraphs.count)
        isFinal = Array(repeating: false, count: paragraphs.count)
        revision += 1
        status = .working
        notice = nil
        failure = nil
        source = nil
        sourceLanguages = []
        roughSources = []
        guard !paragraphs.isEmpty else {
            status = .failed("No text found")
            return
        }
        let run = generation
        job = Task { await translateAll(run) }
    }

    /// The same paragraphs again, from `chosen` or from what they're detected to be in.
    func restart(choosing chosen: Locale.Language?) {
        cancel()
        start(paragraphs: texts, choosing: chosen, firmly: true)
    }

    func cancel() {
        job?.cancel()
        // Their own tasks, so closing the capture has to stop them explicitly; left
        // running, they would hold up the next capture's translation behind them.
        drafts.forEach { $0.cancel() }
        drafts = []
        let waiting = viewQueue
        viewQueue = []
        waiting.forEach { $0.done.resume() }
        appleConfiguration = nil
    }

    // MARK: Routing

    private func translateAll(_ run: Int) async {
        let plan = TranslationPlan(texts, target: target, choosing: chosenSource, firmly: choiceIsFirm)
        source = plan.source
        let letters = Dictionary(plan.groups.map { group in
            (group.source, group.paragraphs.reduce(0) { $0 + texts[$1].count(where: \.isLetter) })
        }, uniquingKeysWith: +)
        sourceLanguages = plan.groups.map(\.source).sorted { letters[$0, default: 0] > letters[$1, default: 0] }
        if let source { onSourceDetected?(source) }
        switch plan.outcome {
        case .translate: break
        case .alreadyInTarget: status = .sameLanguage; return
        case .nothingToTranslate: status = .nothingToTranslate; return
        case .unknownLanguage: status = .failed("Unknown language"); return
        }

        // What has been translated since launch shows at once; only the rest goes on.
        var pending: [TranslationPlan.Group] = []
        var remembered: [Locale.Language] = []
        for group in plan.groups {
            let left = group.paragraphs.filter { index in
                if let text = known[index] {
                    show(text, at: index, isFinal: true, source: group.source, run: run)
                    return false
                }
                guard let known = memory.lookup(texts[index], from: group.source, to: target) else { return true }
                show(known.text, at: index, isFinal: known.isFinal, source: nil, run: run)
                return !known.isFinal
            }
            if left.isEmpty {
                remembered.append(group.source)
            } else {
                pending.append(TranslationPlan.Group(source: group.source, paragraphs: left))
            }
        }
        await withTaskGroup(of: Void.self) { languages in
            for group in pending {
                languages.addTask { await self.translate(group, run: run) }
            }
            // Shown from memory, but how rough it is still depends on what made it.
            for source in remembered {
                languages.addTask {
                    let engines = await self.engines(for: source)
                    await self.noteRoughness(of: source, engines: engines, run: run)
                }
            }
        }
        guard run == generation, !Task.isCancelled else { return }
        let missing = plan.translated.filter { translations[$0] == nil }
        status = missing.count == plan.translated.count
            ? .failed(failure ?? notice ?? "Couldn't translate this text.")
            : .done
    }

    /// Which engines a language goes to, from what Apple and the offline packs can do
    /// for its pair.
    enum Engines: Equatable {
        /// Apple translates, with the pack's draft first when the pack is on the Mac.
        /// `prepare`: Apple has to download its own model first, and asks the user.
        /// `prefetchPack`: fetch the pack in the background for an instant draft next time.
        case apple(prepare: Bool, prefetchPack: Bool)
        /// The pack on the Mac is the translation.
        case offline
        /// The pack is the only way to translate the pair: fetch it, then translate.
        case downloadThenOffline
        case unsupported
    }

    /// A pack is downloaded unasked only when nothing else can translate the pair. Packs
    /// are 100–250 MB, and a session across a few languages once fetched gigabytes of
    /// drafts for pairs Apple already did; fetching those is the user's choice
    /// (`prefetchesPacks`, the "Download packs for instant drafts" setting).
    static func engines(apple: LanguageAvailability.Status, offline: TranslatorAvailability,
                        prefetchesPacks: Bool) -> Engines {
        let packIsMissing = if case .needsDownload = offline { true } else { false }
        switch (apple, offline) {
        case (.installed, _):
            return .apple(prepare: false, prefetchPack: packIsMissing && prefetchesPacks)
        case (_, .ready):
            // Apple can't, or not without a download: the draft is the translation.
            return .offline
        case (.supported, _):
            return .apple(prepare: true, prefetchPack: packIsMissing && prefetchesPacks)
        case (_, .needsDownload):
            return .downloadThenOffline
        default:
            return .unsupported
        }
    }

    private func engines(for source: Locale.Language) async -> Engines {
        Self.engines(apple: await LanguageAvailability().status(from: source, to: target),
                     offline: await offline.availability(from: source, to: target),
                     prefetchesPacks: offline.prefetchesPacks)
    }

    /// Adds `source` to `roughSources` when the offline pack is its translation and that
    /// pack is a many-language one (`OpusMTTranslator.isRough`). With Apple translating,
    /// a rough draft is replaced as Apple's lines land, so nothing is said.
    private func noteRoughness(of source: Locale.Language, engines: Engines, run: Int) {
        guard run == generation, engines == .offline || engines == .downloadThenOffline,
              offline.isRough(from: source, to: target), !roughSources.contains(source) else { return }
        roughSources = sourceLanguages.filter { roughSources.contains($0) || $0 == source }
    }

    private func translate(_ group: TranslationPlan.Group, run: Int) async {
        let source = group.source
        let offlineAvailability = await offline.availability(from: source, to: target)
        let apple = await LanguageAvailability().status(from: source, to: target)
        guard run == generation, !Task.isCancelled else { return }
        let engines = Self.engines(apple: apple, offline: offlineAvailability, prefetchesPacks: offline.prefetchesPacks)
        noteRoughness(of: source, engines: engines, run: run)

        // The draft runs alongside Apple rather than before it: they don't compete, the
        // offline model is done long before Apple's first paragraph.
        var draft: Task<Void, Never>?
        if offlineAvailability == .ready {
            let task = Task { await draftOffline(group, run: run) }
            drafts.append(task)
            draft = task
        }

        switch engines {
        case .apple(prepare: false, let prefetch):
            await translateWithApple(group, drafted: draft != nil, run: run)
            if prefetch { prefetchPack(from: source) }
        case .apple(prepare: true, let prefetch):
            // Apple needs its model for this pair first, and asks the user for it.
            if prefetch { prefetchPack(from: source) }
            NSApp.activate(ignoringOtherApps: true)
            await translateThroughView(group, prepare: true, drafted: false, run: run)
        case .offline:
            await draft?.value
            settle(group, run: run)
        case .downloadThenOffline:
            await downloadThenTranslateOffline(group, run: run)
        case .unsupported:
            notice = "Can't translate \(Languages.name(source)) into \(Languages.name(target))"
        }
    }

    /// Puts a paragraph's translation up, unless it's a draft and the final one is
    /// already there, and keeps it for the next time the same text turns up.
    private func show(_ text: String, at index: Int, isFinal final: Bool, source: Locale.Language?, run: Int) {
        guard run == generation, !Task.isCancelled, translations.indices.contains(index),
              final || !isFinal[index] else { return }
        if translations[index] != text {
            translations[index] = text
            revision += 1
        }
        isFinal[index] = isFinal[index] || final
        if let source { memory.remember(text, isFinal: final, for: texts[index], from: source, to: target) }
    }

    // MARK: Offline

    /// Fills in each paragraph the moment the offline model finishes it — short ones
    /// first — wherever Apple hasn't answered already: its version is the better one.
    private func draftOffline(_ group: TranslationPlan.Group, run: Int) async {
        let (lines, sink) = AsyncStream.makeStream(of: (index: Int, text: String).self)
        let offline = offline, target = target, source = group.source
        let texts = group.paragraphs.map { self.texts[$0] }
        let translation = Task.detached(priority: .userInitiated) {
            defer { sink.finish() }
            _ = try? await offline.translate(lines: texts, from: source, to: target) { sink.yield(($0, $1)) }
        }
        await withTaskCancellationHandler {
            for await line in lines where group.paragraphs.indices.contains(line.index) {
                show(line.text, at: group.paragraphs[line.index], isFinal: false, source: source, run: run)
            }
        } onCancel: {
            translation.cancel()
        }
    }

    /// The offline drafts are the translation: nothing better is coming for this pair.
    private func settle(_ group: TranslationPlan.Group, run: Int) {
        for index in group.paragraphs {
            if let text = translations[index] { show(text, at: index, isFinal: true, source: group.source, run: run) }
        }
    }

    private func downloadThenTranslateOffline(_ group: TranslationPlan.Group, run: Int) async {
        let source = group.source
        let pair = "\(Languages.name(source)) → \(Languages.name(target))"
        status = .downloading(pair, progress: nil)
        do {
            // At most about a hundred calls a download (`OpusMTTranslator.download`).
            try await offline.download(from: source, to: target) { [weak self] fraction in
                Task { @MainActor in self?.downloaded(fraction, of: pair, run: run) }
            }
            guard run == generation, !Task.isCancelled else { return }
            status = .working
            await draftOffline(group, run: run)
            settle(group, run: run)
        } catch {
            guard run == generation, !Task.isCancelled else { return }
            status = .working
            failure = error.localizedDescription
        }
    }

    /// Progress hops to the main actor in tasks that may land out of order, so it only
    /// ever moves forward, and only while that pair is still what's downloading.
    private func downloaded(_ fraction: Double, of pair: String, run: Int) {
        guard run == generation, case .downloading(pair, let shown) = status, fraction > shown ?? -1 else { return }
        status = .downloading(pair, progress: fraction)
    }

    /// Fetched for next time, outside this job: closing the capture mustn't stop it.
    private func prefetchPack(from source: Locale.Language) {
        let offline = offline, target = target
        Task.detached(priority: .utility) {
            try? await offline.download(from: source, to: target) { _ in }
        }
    }

    // MARK: Apple

    private func translateWithApple(_ group: TranslationPlan.Group, drafted: Bool, run: Int) async {
        if #available(macOS 26, *) {
            let box = appleSessions.session(from: group.source, to: target)
            do {
                try await translate(group, with: box, prepare: false, drafted: drafted, run: run)
                return
            } catch {
                guard run == generation, !Task.isCancelled else { return }
                // A kept session can go stale (model updated, service restarted).
                appleSessions.forget(from: group.source, to: target)
            }
        }
        await translateThroughView(group, prepare: false, drafted: drafted, run: run)
    }

    private struct ViewRequest {
        let id = UUID()
        let group: TranslationPlan.Group
        let prepare: Bool
        let drafted: Bool
        let run: Int
        let done: CheckedContinuation<Void, Never>
    }

    private func translateThroughView(_ group: TranslationPlan.Group, prepare: Bool, drafted: Bool, run: Int) async {
        guard run == generation, !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            viewQueue.append(ViewRequest(group: group, prepare: prepare, drafted: drafted, run: run, done: continuation))
            if viewQueue.count == 1 { configureView(for: group) }
        }
    }

    /// Called from `.translationTask`, the only place macOS 15 hands out a session.
    func translateWithApple(_ session: TranslationSession) async {
        guard let request = viewQueue.first else { return }
        do {
            try await translate(request.group, with: SessionBox(session: session), prepare: request.prepare,
                                drafted: request.drafted, run: request.run)
        } catch {
            if request.run == generation, !Task.isCancelled { failure = error.localizedDescription }
        }
        // Cancelled meanwhile: the queue has been emptied and its waiters resumed.
        guard viewQueue.first?.id == request.id else { return }
        viewQueue.removeFirst()
        request.done.resume()
        if let next = viewQueue.first { configureView(for: next.group) } else { appleConfiguration = nil }
    }

    private func configureView(for group: TranslationPlan.Group) {
        if var configuration = appleConfiguration, configuration.source == group.source,
           configuration.target == target {
            // A session is handed out again only for a changed configuration.
            configuration.invalidate()
            appleConfiguration = configuration
        } else {
            appleConfiguration = TranslationSession.Configuration(source: group.source, target: target)
        }
    }

    /// Sends `group` to Apple, neighbours together on one line (`ContextWindows`), and
    /// drops each paragraph in over any offline draft as its line lands. A line whose
    /// marks came back wrong is sent again a paragraph at a time. With no offline draft
    /// to look at meanwhile (`drafted` false), the first line is kept short so something
    /// is up within about half a second.
    private func translate(_ group: TranslationPlan.Group, with box: SessionBox, prepare: Bool, drafted: Bool,
                           run: Int) async throws {
        let texts = group.paragraphs.map { self.texts[$0] }
        let source = group.source
        let windows = appleSessions.contextWorks(from: source, to: target)
            ? ContextWindows.windows(texts, lead: drafted ? nil : ContextWindows.lead).flatMap { window in
                // Text that uses every mark itself can't be split back: one at a time.
                window.count > 1 && ContextWindows.separator(for: Array(texts[window])) == nil
                    ? window.map { $0..<($0 + 1) } : [window]
            }
            : texts.indices.map { $0..<($0 + 1) }
        var again: [Range<Int>] = []
        for try await result in Self.appleStream(box, texts: texts, windows: windows, prepare: prepare) {
            guard run == generation, !Task.isCancelled else { return }
            switch result {
            case .translated(let position, let text):
                show(text, at: group.paragraphs[position], isFinal: true, source: source, run: run)
            case .matched:
                appleSessions.noteContext(worked: true, from: source, to: target)
            case .unmatched(let window):
                appleSessions.noteContext(worked: false, from: source, to: target)
                again += window.map { $0..<($0 + 1) }
            }
        }
        guard !again.isEmpty else { return }
        for try await result in Self.appleStream(box, texts: texts, windows: again, prepare: false) {
            guard run == generation, !Task.isCancelled else { return }
            if case .translated(let position, let text) = result {
                show(text, at: group.paragraphs[position], isFinal: true, source: source, run: run)
            }
        }
    }

    enum AppleResult: Sendable {
        case translated(position: Int, text: String)
        /// A window of several paragraphs came back with its marks in place.
        case matched
        /// A window whose translation couldn't be split back into its paragraphs.
        case unmatched(Range<Int>)
    }

    /// Off the main actor because `TranslationSession`'s methods are `@concurrent`: a
    /// session built on the main actor can't be sent to them under Swift 6. Lines stream
    /// out as Apple finishes each, not all at the end.
    private nonisolated static func appleStream(_ box: SessionBox, texts: [String], windows: [Range<Int>],
                                                prepare: Bool) -> AsyncThrowingStream<AppleResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if prepare { try await box.session.prepareTranslation() }
                    let separators = windows.map { window in
                        window.count > 1 ? ContextWindows.separator(for: Array(texts[window])) : nil
                    }
                    let requests = windows.enumerated().map { number, window in
                        let line = separators[number].map { ContextWindows.join(Array(texts[window]), separator: $0) }
                            ?? texts[window.lowerBound]
                        return TranslationSession.Request(sourceText: line, clientIdentifier: String(number))
                    }
                    for try await response in box.session.translate(batch: requests) {
                        guard let number = Int(response.clientIdentifier ?? ""), windows.indices.contains(number)
                        else { continue }
                        let window = windows[number]
                        if let separator = separators[number] {
                            if let parts = ContextWindows.split(response.targetText, separator: separator,
                                                                count: window.count) {
                                continuation.yield(.matched)
                                for (position, part) in zip(window, parts) {
                                    continuation.yield(.translated(position: position, text: part))
                                }
                            } else {
                                continuation.yield(.unmatched(window))
                            }
                        } else {
                            continuation.yield(.translated(position: window.lowerBound, text: response.targetText))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension View {
    /// Hosts Apple's `.translationTask` for `job`: the only place a session is handed
    /// out on macOS 15, and where Apple's download confirmation comes from.
    func appleTranslation(for job: TranslationJob) -> some View {
        translationTask(job.appleConfiguration) { session in
            await job.translateWithApple(session)
        }
    }
}

/// Carries a `TranslationSession` across to `appleStream`, off the main actor.
///
/// Unchecked is accurate rather than convenient: `TranslationSession` is a non-Sendable
/// class, but it is only ever driven through its own async methods, one job at a time.
struct SessionBox: @unchecked Sendable {
    let session: TranslationSession
}

/// Apple translation sessions kept for the life of the app, one per language pair.
@MainActor
final class AppleSessionCache {
    private var sessions: [String: SessionBox] = [:]
    /// How sending neighbours together has gone, per pair.
    private var context: [String: (worked: Int, failed: Int)] = [:]

    @available(macOS 26, *)
    func session(from source: Locale.Language, to target: Locale.Language) -> SessionBox {
        let key = Self.key(source, target)
        if let kept = sessions[key] { return kept }
        let box = SessionBox(session: TranslationSession(installedSource: source, target: target))
        sessions[key] = box
        return box
    }

    func forget(from source: Locale.Language, to target: Locale.Language) {
        sessions[Self.key(source, target)] = nil
    }

    /// Whether to send a pair's paragraphs together. Until it has failed twice without
    /// ever working it's assumed to work: a model that doesn't keep the marks costs each
    /// paragraph a second request, so that is found out once, not on every capture.
    func contextWorks(from source: Locale.Language, to target: Locale.Language) -> Bool {
        let record = context[Self.key(source, target)] ?? (0, 0)
        return record.worked > 0 || record.failed < 2
    }

    func noteContext(worked: Bool, from source: Locale.Language, to target: Locale.Language) {
        let key = Self.key(source, target)
        var record = context[key] ?? (0, 0)
        if worked { record.worked += 1 } else { record.failed += 1 }
        context[key] = record
    }

    /// Gets Apple's model loaded while the user is still dragging. The first request
    /// after a pause costs about a second more than the rest (2.1s against 1.0s,
    /// measured); this pays that second before the capture exists.
    func warm(from source: Locale.Language, to target: Locale.Language) {
        guard #available(macOS 26, *), source.languageCode != target.languageCode else { return }
        let box = session(from: source, to: target)
        Task.detached(priority: .userInitiated) {
            _ = try? await box.session.translate("Hello")
        }
    }

    private static func key(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
    }
}
