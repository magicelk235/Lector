import AppKit
import HoverLensKit
import SwiftUI
import Translation

/// Translates the paragraphs of one capture as fast as the Mac allows.
///
/// Apple's on-device translation is the good one, but it works strictly one paragraph
/// at a time at about a second each — six paragraphs take six seconds however it's
/// called (measured: batches, parallel sessions and one joined request all serialise).
/// The offline Opus-MT model does the same six in a quarter of a second, less well.
///
/// So when the offline pack for the pair is on the Mac, its draft goes up at once and
/// Apple's version replaces it paragraph by paragraph as each one lands. Without the
/// pack, Apple's paragraphs appear one by one, and the pack is fetched in the
/// background so the next capture in this language gets the instant draft. Pairs Apple
/// can't do at all go to the offline model alone, downloading it first if needed.
@MainActor
@Observable
final class TranslationJob {
    enum Status: Equatable {
        case working
        case done
        /// The text is already in the target language.
        case sameLanguage
        /// Fetching a language pack before anything can be translated.
        case downloading(String)
        case failed(String)
    }

    private(set) var status: Status = .working
    /// One per paragraph, in `Paragraphs.blocks` order; nil until something has
    /// translated it.
    private(set) var translations: [String?] = []
    /// Bumped on every change to `translations`, for observers.
    private(set) var revision = 0
    private(set) var source: Locale.Language?
    let target: Locale.Language
    /// Set to hand work to Apple through `.translationTask`: on macOS 15, and whenever
    /// Apple needs to ask the user to download a language.
    private(set) var appleConfiguration: TranslationSession.Configuration?

    /// Called with the source language once it's known, so the next capture can warm
    /// the right engine while the user is still dragging.
    var onSourceDetected: ((Locale.Language) -> Void)?

    private var paragraphs: [String] = []
    private var appleNeedsPrepare = false
    private var appleFinished = false
    private let offline: OpusMTTranslator
    private let appleSessions: AppleSessionCache
    private var job: Task<Void, Never>?

    init(target: String, offline: OpusMTTranslator, appleSessions: AppleSessionCache) {
        self.target = Locale.Language(identifier: target)
        self.offline = offline
        self.appleSessions = appleSessions
    }

    /// Every paragraph's translation, or nil while any is missing.
    var completeTranslation: String? {
        let parts = translations.compactMap { $0 }
        return parts.count == translations.count && !parts.isEmpty ? parts.joined(separator: "\n") : nil
    }

    func start(paragraphs: [String]) {
        self.paragraphs = paragraphs
        translations = Array(repeating: nil, count: paragraphs.count)
        revision += 1
        guard !paragraphs.isEmpty else {
            status = .failed("No text found in that area.")
            return
        }
        job = Task { await route() }
    }

    func cancel() {
        job?.cancel()
        appleConfiguration = nil
    }

    // MARK: Routing

    private func route() async {
        let whole = paragraphs.joined(separator: "\n")
        source = LanguageDetector.language(of: whole)
        if let source {
            onSourceDetected?(source)
            if source.languageCode == target.languageCode {
                status = .sameLanguage
                return
            }
        }

        let offlineAvailability: TranslatorAvailability = if let source {
            await offline.availability(from: source, to: target)
        } else {
            .unsupported
        }
        // The draft runs alongside Apple rather than before it: they don't compete,
        // the offline model is done long before Apple's first paragraph.
        if offlineAvailability == .ready, let source {
            Task { await draftOffline(from: source) }
        }

        let apple: LanguageAvailability.Status = if let source {
            await LanguageAvailability().status(from: source, to: target)
        } else {
            (try? await LanguageAvailability().status(for: whole, to: target)) ?? .unsupported
        }
        guard !Task.isCancelled else { return }

        switch (apple, offlineAvailability) {
        case (.installed, _):
            await translateWithApple()
            if case .needsDownload = offlineAvailability, let source { prefetchPack(from: source) }
        case (_, .ready):
            // Apple can't (or not without a download); the draft is the translation.
            break
        case (_, .needsDownload):
            await downloadThenTranslateOffline()
        case (.supported, .unsupported):
            // Only Apple can do this pair, and it needs its model: Apple asks the user.
            NSApp.activate(ignoringOtherApps: true)
            useAppleThroughView(prepare: true)
        default:
            status = .failed(source.map {
                "Can't translate \(Languages.name($0)) into \(Languages.name(target)) yet."
            } ?? "Couldn't tell what language this is.")
        }
    }

    // MARK: Offline

    private func draftOffline(from source: Locale.Language) async {
        guard let text = try? await offline.translate(paragraphs.joined(separator: "\n"), from: source, to: target),
              !Task.isCancelled, !appleFinished
        else { return }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == paragraphs.count else { return }
        // Only where Apple hasn't already answered: its version is the better one.
        for (index, line) in lines.enumerated() where translations[index] == nil {
            translations[index] = line
        }
        revision += 1
        if completeTranslation != nil, !isAppleRunning { status = .done }
    }

    private func downloadThenTranslateOffline() async {
        guard let source else { return }
        status = .downloading("\(Languages.name(source)) → \(Languages.name(target))")
        do {
            try await offline.download(from: source, to: target) { _ in }
            guard !Task.isCancelled else { return }
            status = .working
            await draftOffline(from: source)
            if completeTranslation == nil { status = .failed("Couldn't translate this text.") }
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    /// Fetched for next time, outside this job: closing the capture mustn't stop it.
    private func prefetchPack(from source: Locale.Language) {
        let offline = offline, target = target
        Task.detached(priority: .utility) {
            try? await offline.download(from: source, to: target) { _ in }
        }
    }

    // MARK: Apple

    private var isAppleRunning = false

    private func translateWithApple() async {
        if #available(macOS 26, *), let source {
            let box = appleSessions.session(from: source, to: target)
            do {
                try await consume(Self.appleStream(box, paragraphs: paragraphs, prepare: false))
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A kept session can go stale (model updated, service restarted).
                appleSessions.forget(from: source, to: target)
            }
        }
        useAppleThroughView(prepare: false)
    }

    private func useAppleThroughView(prepare: Bool) {
        appleNeedsPrepare = prepare
        appleConfiguration = TranslationSession.Configuration(source: source, target: target)
    }

    /// Called from `.translationTask`, the only place macOS 15 hands out a session.
    func translateWithApple(_ session: TranslationSession) async {
        do {
            try await consume(Self.appleStream(SessionBox(session: session), paragraphs: paragraphs,
                                               prepare: appleNeedsPrepare))
        } catch {
            guard !Task.isCancelled else { return }
            if completeTranslation == nil { status = .failed(error.localizedDescription) }
        }
        appleConfiguration = nil
    }

    /// Drops each of Apple's paragraphs in as it lands, over any offline draft.
    private func consume(_ stream: AsyncThrowingStream<AppleResult, Error>) async throws {
        isAppleRunning = true
        defer { isAppleRunning = false }
        for try await result in stream {
            guard !Task.isCancelled else { return }
            if source == nil { source = result.source }
            if translations.indices.contains(result.index) {
                translations[result.index] = result.text
                revision += 1
            }
        }
        appleFinished = true
        if completeTranslation != nil { status = .done }
    }

    struct AppleResult: Sendable {
        let index: Int
        let text: String
        let source: Locale.Language?
    }

    /// Off the main actor because `TranslationSession`'s methods are `@concurrent`: a
    /// session built on the main actor can't be sent to them under Swift 6. Paragraphs
    /// stream out as Apple finishes each, not all at the end.
    private nonisolated static func appleStream(_ box: SessionBox, paragraphs: [String],
                                                prepare: Bool) -> AsyncThrowingStream<AppleResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if prepare { try await box.session.prepareTranslation() }
                    let requests = paragraphs.enumerated().map {
                        TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                    }
                    for try await response in box.session.translate(batch: requests) {
                        continuation.yield(AppleResult(index: Int(response.clientIdentifier ?? "") ?? -1,
                                                       text: response.targetText,
                                                       source: response.sourceLanguage))
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
