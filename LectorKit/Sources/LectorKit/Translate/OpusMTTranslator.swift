import Foundation
import NaturalLanguage
import Synchronization

public enum OpusMTError: Error, LocalizedError, Equatable {
    case unsupportedPair(source: String, target: String)
    /// `translate` was asked for a pair whose models have not been downloaded.
    case modelsNotDownloaded
    case downloadFailed(String)
    /// A downloaded file did not match the catalog. It has been deleted.
    case corruptDownload(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPair(let source, let target):
            "No offline pack for \(source) → \(target)"
        case .modelsNotDownloaded:
            "Language pack not downloaded"
        case .downloadFailed(let detail):
            "Download failed: \(detail)"
        case .corruptDownload:
            "Language pack damaged. Try again."
        }
    }
}

/// Offline translation with Helsinki-NLP's Opus-MT models (CC-BY 4.0), run on ONNX Runtime.
///
/// The fallback for pairs Apple's Translation framework does not cover. Models are
/// downloaded per pair when asked for, never bundled. A pair is served by one model where
/// one exists (Hebrew → German has its own) or by two with English between them, with the
/// hundred-language models filling in where nothing more specific exists. `availability`
/// answers from a table compiled into the app, so it never touches the network.
///
/// Layout of `modelsDirectory`: one directory per model, named after it
/// (`opus-mt-mul-en/`), holding the model's files and a `manifest.json` written last,
/// whose presence is what marks the model installed. Downloads in progress live in
/// `.partial/` and resume from there.
public final class OpusMTTranslator: Translator {
    private let modelsDirectory: URL
    private let catalog: OpusMTCatalog
    private let cache: ModelCache<MarianModel>
    /// One translation runs at a time: models share ONNX Runtime's thread pool, so two
    /// at once would each take twice as long and finish no sooner.
    private let inference = DispatchQueue(label: "Lector.OpusMT.inference", qos: .userInitiated)
    private let downloads = Mutex<[String: Download]>([:])
    private let prefetch = Atomic<Bool>(false)

    /// Whether packs may be fetched ahead of need for pairs another engine already
    /// translates, for an instant draft. The user's setting, off by default: this
    /// translator only keeps it so every capture's job sees the same answer.
    public var prefetchesPacks: Bool {
        get { prefetch.load(ordering: .relaxed) }
        set { prefetch.store(newValue, ordering: .relaxed) }
    }

    public convenience init(modelsDirectory: URL) {
        self.init(modelsDirectory: modelsDirectory, catalog: .shared)
    }

    /// Two loaded models cover a pivot through English, or two languages captured in
    /// turn. Each costs 650–770 MB while loaded (measured, most of it the decoder's
    /// weights dequantized at load), so no more stay between uses, and none once the app
    /// has sat idle for `idleUnload`: a session across a few languages otherwise left the
    /// app at 1.2 GB for good. Loading one again takes about half a second.
    init(modelsDirectory: URL, catalog: OpusMTCatalog, residentModels: Int = 2,
         idleUnload: Duration = .seconds(180)) {
        self.modelsDirectory = modelsDirectory
        self.catalog = catalog
        // What a model let go leaves among the spare blocks is not worth keeping.
        cache = ModelCache(capacity: residentModels, idleTimeout: idleUnload) { TensorMemory.releaseSpares() }
    }

    // MARK: - Translator

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslatorAvailability {
        guard let route = catalog.route(from: source, to: target, isInstalled: isInstalled) else { return .unsupported }
        let missing = route.models.filter { !isInstalled($0) }
        return missing.isEmpty ? .ready : .needsDownload(bytes: missing.reduce(0) { $0 + $1.bytes })
    }

    /// Whether `source` → `target` goes through one of the hundred-language models, the
    /// only route for languages nothing more specific covers. Their translations are rough
    /// at best. Measured by Helsinki-NLP on Tatoeba: Persian → English through mul-en
    /// scores 7.5 BLEU (Persian "please help me" came back as "Give me a little child"),
    /// while specific models score 40–60. So the user should be told, not handed it as
    /// an ordinary translation.
    public func isRough(from source: Locale.Language, to target: Locale.Language) -> Bool {
        catalog.route(from: source, to: target, isInstalled: isInstalled)?
            .models.contains { $0.kind == .multilingual } ?? false
    }

    /// Translates line by line: the result has exactly as many lines as `text`. Lines
    /// with no letters in them (numbers, times, prices, punctuation) come back as they are.
    public func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await translate(lines: text.components(separatedBy: "\n"), from: source, to: target) { _, _ in }
            .joined(separator: "\n")
    }

    /// Translates each of `lines` on its own and returns them in order, handing each to
    /// `onLine` with its index the moment it is done, on an arbitrary thread: on a page
    /// of text the short lines land long before the long ones. Lines with no letters in
    /// them (numbers, times, prices, punctuation) come back as they are, straight away.
    public func translate(lines: [String], from source: Locale.Language, to target: Locale.Language,
                          onLine: @escaping @Sendable (Int, String) -> Void) async throws -> [String] {
        let route = try resolve(source, target)
        guard route.models.allSatisfy(isInstalled) else { throw OpusMTError.modelsNotDownloaded }
        var legs: [Leg] = []
        for (index, leg) in route.legs.enumerated() {
            let directory = directory(for: leg.model)
            let model = try await cache.model(named: leg.model.name) { try MarianModel(directory: directory) }
            // Every leg but the last writes English, which the next one reads.
            let isLast = index == route.legs.count - 1
            legs.append(Leg(model: model, languageToken: leg.languageToken,
                            source: index == 0 ? source : Locale.Language(identifier: "en"),
                            joiner: isLast ? Self.sentenceJoiner(for: target) : " "))
        }
        let stop = StopFlag()
        let work: @Sendable () throws -> [String] = { [legs] in
            try Self.translateLines(lines, through: legs, stop: stop, onLine: onLine)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inference.async {
                    continuation.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            stop.raise()
        }
    }

    // MARK: - Models on disk

    /// Downloads whatever `source` → `target` needs that is not installed yet. `progress`
    /// runs from 0 to 1 over the bytes still to fetch — both models of a pivot as one
    /// span — on an arbitrary thread, at most about a hundred times. An interrupted
    /// download continues from where it stopped on the next call.
    public func download(
        from source: Locale.Language, to target: Locale.Language,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let route = try resolve(source, target)
        let missing = route.models.filter { !isInstalled($0) }
        let reporter = ProgressReporter(total: Double(max(1, missing.reduce(0) { $0 + $1.bytes })), callback: progress)
        reporter.report(done: 0)
        var finished: Int64 = 0
        for model in missing {
            let base = finished
            try await install(model) { bytes in reporter.report(done: Double(base + bytes)) }
            finished += model.bytes
        }
        reporter.finish()
    }

    /// The installed packs, by what they translate.
    public func installedPacks() -> [OpusMTPack] {
        catalog.models.filter(isInstalled)
            .map { OpusMTPack(model: $0, bytesOnDisk: Self.allocatedSize(of: directory(for: $0))) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// About how big a pack that writes `target` is, for saying what a download costs:
    /// the middle of the packs that would serve it.
    public func typicalPackBytes(into target: Locale.Language) -> Int64? {
        catalog.typicalBytes(into: target)
    }

    /// Deletes one installed pack, stopping a download of it if one is under way.
    public func removePack(_ pack: OpusMTPack) throws {
        downloads.withLock { $0[pack.id]?.task.cancel() }
        cache.remove(named: pack.id)
        let directory = modelsDirectory.appending(path: pack.id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Deletes every downloaded model and partial download, stopping any in progress.
    public func removeAllModels() throws {
        downloads.withLock { $0.values.forEach { $0.task.cancel() } }
        cache.removeAll()
        let manager = FileManager.default
        guard manager.fileExists(atPath: modelsDirectory.path(percentEncoded: false)) else { return }
        for item in try manager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: item)
        }
    }

    private static func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Installing

    /// The route `availability` reported: one already on the Mac where it is about as
    /// good, so a pair never fetches a second pack beside one that serves it.
    private func resolve(_ source: Locale.Language, _ target: Locale.Language) throws -> OpusMTRoute {
        guard let route = catalog.route(from: source, to: target, isInstalled: isInstalled) else {
            throw OpusMTError.unsupportedPair(source: source.minimalIdentifier, target: target.minimalIdentifier)
        }
        return route
    }

    private func directory(for model: OpusMTModel) -> URL {
        modelsDirectory.appending(path: model.name, directoryHint: .isDirectory)
    }

    private func isInstalled(_ model: OpusMTModel) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: model).appending(path: "manifest.json").path(percentEncoded: false))
    }

    /// A model being fetched, and the progress callbacks of everyone waiting for it.
    private struct Download {
        let task: Task<Void, any Error>
        let listeners: ByteListeners
    }

    /// Installs one model, joining a download of it already under way rather than
    /// starting a second; whoever joins hears its progress from where it has got to.
    private func install(_ model: OpusMTModel, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let download = downloads.withLock { running in
            if let existing = running[model.name] { return existing }
            let listeners = ByteListeners()
            let task = Task { [modelsDirectory] in
                try await Self.fetch(model, into: modelsDirectory) { listeners.send($0) }
            }
            let download = Download(task: task, listeners: listeners)
            running[model.name] = download
            return download
        }
        let listener = download.listeners.add(onBytes)
        defer {
            download.listeners.remove(listener)
            downloads.withLock { if $0[model.name]?.task == download.task { $0[model.name] = nil } }
        }
        try await withTaskCancellationHandler {
            try await download.task.value
        } onCancel: {
            download.task.cancel()
        }
    }

    /// Fetches a model's files into `.partial/<name>-<revision>/`, checks each against the
    /// catalog, then moves the directory into place with a single rename, so a model is
    /// either wholly installed or absent. What an interrupted download leaves behind is
    /// continued next time; a file that fails its check is deleted.
    private static func fetch(
        _ model: OpusMTModel, into modelsDirectory: URL, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let manager = FileManager.default
        let partialRoot = modelsDirectory.appending(path: ".partial", directoryHint: .isDirectory)
        let staging = partialRoot.appending(path: "\(model.name)-\(model.revision.prefix(12))", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        // A partial download of another revision of this model is of no further use.
        for stale in (try? manager.contentsOfDirectory(atPath: partialRoot.path(percentEncoded: false))) ?? []
        where stale.hasPrefix(model.name + "-") && stale != staging.lastPathComponent {
            try? manager.removeItem(at: partialRoot.appending(path: stale))
        }

        var completed: Int64 = 0
        for file in model.files {
            let destination = staging.appending(path: file.localName)
            let before = completed
            try await ResumableFileDownload.fetch(model.url(for: file), to: destination, expectedBytes: file.bytes) { bytes in
                onBytes(before + bytes)
            }
            try Task.checkCancellation()
            let size = (try manager.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? -1
            let intact = try size == file.bytes && (file.sha256.isEmpty || ResumableFileDownload.sha256(of: destination) == file.sha256)
            guard intact else {
                try? manager.removeItem(at: destination)
                throw OpusMTError.corruptDownload(file.localName)
            }
            completed += file.bytes
        }

        let manifest: [String: Any] = [
            "name": model.name, "repository": model.repository, "revision": model.revision,
            "files": model.files.map(\.localName),
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appending(path: "manifest.json"), options: .atomic)
        let destination = modelsDirectory.appending(path: model.name, directoryHint: .isDirectory)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: staging, to: destination)
        // rmdir rather than removeItem: it only succeeds while nothing else is downloading.
        rmdir(partialRoot.path(percentEncoded: false))
    }

    // MARK: - Translating

    private struct Leg: Sendable {
        let model: MarianModel
        let languageToken: String?
        /// The language the leg reads, which decides where its sentences end.
        let source: Locale.Language
        /// What goes between sentences translated separately: a space, or nothing in
        /// scripts written without spaces.
        let joiner: String
    }

    private static func sentenceJoiner(for language: Locale.Language) -> String {
        let unspaced: Set<String> = ["zh", "ja", "th", "lo", "km", "my", "bo"]
        return unspaced.contains(language.languageCode?.identifier ?? "") ? "" : " "
    }

    /// Every line through every leg of the route, all lines of a leg in one batch, each
    /// line handed to `onLine` once the last leg has all of its pieces. A line without a
    /// letter passes through: there is nothing to translate, and these models will
    /// happily invent words for "12:30".
    private static func translateLines(_ lines: [String], through legs: [Leg], stop: StopFlag,
                                       onLine: (Int, String) -> Void) throws -> [String] {
        // Queued behind a translation that has since been closed: nothing to do.
        if stop.isRaised { throw CancellationError() }
        var texts = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let translatable = texts.indices.filter { texts[$0].unicodeScalars.contains(where: CharacterSet.letters.contains) }
        let translating = Set(translatable)
        for line in texts.indices where !translating.contains(line) {
            onLine(line, texts[line])
        }
        for (number, leg) in legs.enumerated() {
            let isLast = number == legs.count - 1
            var pieces: [String] = []
            var owners: [Int] = []
            // Each line's pieces, which sit together in `pieces`, and how many are still out.
            var ranges: [Int: Range<Int>] = [:]
            var remaining: [Int: Int] = [:]
            for line in translatable {
                let lineChunks = chunks(of: texts[line], in: leg.source, for: leg.model, languageToken: leg.languageToken)
                ranges[line] = pieces.count..<pieces.count + lineChunks.count
                remaining[line] = lineChunks.count
                pieces += lineChunks
                owners += Array(repeating: line, count: lineChunks.count)
            }
            var translated = [String](repeating: "", count: pieces.count)
            func complete(_ line: Int) {
                texts[line] = translated[ranges[line] ?? 0..<0].filter { !$0.isEmpty }.joined(separator: leg.joiner)
                if isLast { onLine(line, texts[line]) }
            }
            for line in translatable where remaining[line] == 0 { complete(line) }
            _ = try leg.model.translate(pieces, languageToken: leg.languageToken, stop: stop) { piece, text in
                translated[piece] = text
                let line = owners[piece]
                remaining[line, default: 1] -= 1
                if remaining[line] == 0 { complete(line) }
            }
        }
        return texts
    }

    /// A line cut into its sentences, each translated on its own. The models learnt from
    /// single sentences: given several at once they tend to drop one (a Greek question
    /// between two other sentences vanished). And decoding takes a step per output token,
    /// so a paragraph goes as fast as its longest sentence rather than as its whole
    /// length: thirty sentences took 2.4 s as one line and 0.5 s cut up (M4). A sentence
    /// too long for the model on its own is cut between words.
    private static func chunks(of text: String, in language: Locale.Language, for model: MarianModel,
                               languageToken: String?) -> [String] {
        func fits(_ piece: String) -> Bool {
            model.tokenizer.encode(piece, languageToken: languageToken).count <= model.maxChunkTokens
        }
        var chunks: [String] = []
        func add(_ piece: String) {
            let piece = piece.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { chunks.append(piece) }
        }
        for sentence in Sentences.split(text, in: language) {
            if fits(sentence) {
                add(sentence)
                continue
            }
            var current = ""
            for word in Sentences.units(of: sentence, .word, in: language) {
                if !current.isEmpty, !fits(current + word) {
                    add(current)
                    current = ""
                }
                current += word
            }
            add(current)
        }
        return chunks
    }
}

/// Raised from another thread to stop a translation between decoder steps.
final class StopFlag: Sendable {
    private let raised = Atomic<Bool>(false)

    func raise() { raised.store(true, ordering: .relaxed) }
    var isRaised: Bool { raised.load(ordering: .relaxed) }
}

/// The progress callbacks of everyone waiting for one download. Whoever joins late is
/// told at once how far it has got.
private final class ByteListeners: Sendable {
    private struct State {
        var bytes: Int64 = 0
        var callbacks: [Int: @Sendable (Int64) -> Void] = [:]
        var nextID = 0
    }

    private let state = Mutex(State())

    func send(_ bytes: Int64) {
        let callbacks = state.withLock { state in
            state.bytes = bytes
            return Array(state.callbacks.values)
        }
        for callback in callbacks { callback(bytes) }
    }

    func add(_ callback: @escaping @Sendable (Int64) -> Void) -> Int {
        let (id, bytes) = state.withLock { state in
            defer { state.nextID += 1 }
            state.callbacks[state.nextID] = callback
            return (state.nextID, state.bytes)
        }
        callback(bytes)
        return id
    }

    func remove(_ id: Int) {
        state.withLock { _ = $0.callbacks.removeValue(forKey: id) }
    }
}

/// Turns byte counts into calls to the caller's progress closure: about a hundred per
/// download at most, and never going backwards.
private final class ProgressReporter: Sendable {
    private let total: Double
    private let callback: @Sendable (Double) -> Void
    private let last = Mutex<Double>(-1)

    init(total: Double, callback: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.callback = callback
    }

    func report(done: Double) {
        let fraction = min(1, max(0, done / total))
        let due = last.withLock { last in
            guard fraction >= last + 0.01 || last < 0 else { return false }
            last = fraction
            return true
        }
        if due { callback(fraction) }
    }

    func finish() {
        last.withLock { $0 = 1 }
        callback(1)
    }
}
