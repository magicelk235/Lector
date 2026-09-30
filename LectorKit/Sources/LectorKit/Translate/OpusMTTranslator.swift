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
            "No offline translation model covers \(source) to \(target)."
        case .modelsNotDownloaded:
            "The translation model for this language pair has not been downloaded."
        case .downloadFailed(let detail):
            "The translation model could not be downloaded: \(detail)"
        case .corruptDownload(let file):
            "The downloaded translation model was damaged (\(file)). Try downloading it again."
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
    private let cache = ModelCache(capacity: 4)
    /// One translation runs at a time: models share ONNX Runtime's thread pool, so two
    /// at once would each take twice as long and finish no sooner.
    private let inference = DispatchQueue(label: "Lector.OpusMT.inference", qos: .userInitiated)
    private let downloads = Mutex<[String: Task<Void, any Error>]>([:])

    public convenience init(modelsDirectory: URL) {
        self.init(modelsDirectory: modelsDirectory, catalog: .shared)
    }

    init(modelsDirectory: URL, catalog: OpusMTCatalog) {
        self.modelsDirectory = modelsDirectory
        self.catalog = catalog
    }

    // MARK: - Translator

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslatorAvailability {
        guard let route = catalog.route(from: source, to: target) else { return .unsupported }
        let missing = route.models.filter { !isInstalled($0) }
        return missing.isEmpty ? .ready : .needsDownload(bytes: missing.reduce(0) { $0 + $1.bytes })
    }

    /// Translates line by line: the result has exactly as many lines as `text`. Lines
    /// with no letters in them (numbers, times, prices, punctuation) come back as they are.
    public func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        let route = try resolve(source, target)
        guard route.models.allSatisfy(isInstalled) else { throw OpusMTError.modelsNotDownloaded }
        var legs: [Leg] = []
        for (index, leg) in route.legs.enumerated() {
            let model = try await cache.model(leg.model, in: directory(for: leg.model))
            // Every leg but the last writes English.
            let joiner = index == route.legs.count - 1 ? Self.sentenceJoiner(for: target) : " "
            legs.append(Leg(model: model, languageToken: leg.languageToken, joiner: joiner))
        }
        let stop = StopFlag()
        let work: @Sendable () throws -> String = { [legs] in
            try Self.translateLines(text.components(separatedBy: "\n"), through: legs, stop: stop)
                .joined(separator: "\n")
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
    /// runs from 0 to 1 over the bytes still to fetch, on an arbitrary thread. An
    /// interrupted download continues from where it stopped on the next call.
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

    /// The installed models, described by what they translate, e.g. "Hebrew → English".
    public func installedPairs() -> [String] {
        catalog.models.filter(isInstalled).map(Self.describe).sorted()
    }

    /// Deletes every downloaded model and partial download, stopping any in progress.
    public func removeAllModels() throws {
        downloads.withLock { $0.values.forEach { $0.cancel() } }
        cache.removeAll()
        let manager = FileManager.default
        guard manager.fileExists(atPath: modelsDirectory.path(percentEncoded: false)) else { return }
        for item in try manager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: item)
        }
    }

    // MARK: - Installing

    private func resolve(_ source: Locale.Language, _ target: Locale.Language) throws -> OpusMTRoute {
        guard let route = catalog.route(from: source, to: target) else {
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

    /// Installs one model, joining a download of it already under way rather than
    /// starting a second.
    private func install(_ model: OpusMTModel, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let task = downloads.withLock { running in
            if let existing = running[model.name] { return existing }
            let task = Task { [modelsDirectory] in
                try await Self.fetch(model, into: modelsDirectory, onBytes: onBytes)
            }
            running[model.name] = task
            return task
        }
        defer { downloads.withLock { if $0[model.name] == task { $0[model.name] = nil } } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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

    private static func describe(_ model: OpusMTModel) -> String {
        func side(_ keys: some Collection<String>, group: String?) -> String {
            if keys.count == 1, let key = keys.first {
                return Locale.current.localizedString(forIdentifier: key) ?? key
            }
            return group ?? "\(keys.count) languages"
        }
        return "\(side(model.sources, group: model.sourceGroup)) → \(side(model.targets.keys, group: model.targetGroup))"
    }

    // MARK: - Translating

    private struct Leg: Sendable {
        let model: MarianModel
        let languageToken: String?
        /// What goes between sentences translated separately: a space, or nothing in
        /// scripts written without spaces.
        let joiner: String
    }

    private static func sentenceJoiner(for language: Locale.Language) -> String {
        let unspaced: Set<String> = ["zh", "ja", "th", "lo", "km", "my", "bo"]
        return unspaced.contains(language.languageCode?.identifier ?? "") ? "" : " "
    }

    /// Every line through every leg of the route, all lines of a leg in one batch. A line
    /// without a letter passes through: there is nothing to translate, and these models
    /// will happily invent words for "12:30".
    private static func translateLines(_ lines: [String], through legs: [Leg], stop: StopFlag) throws -> [String] {
        var texts = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let translatable = texts.indices.filter { texts[$0].unicodeScalars.contains(where: CharacterSet.letters.contains) }
        for leg in legs {
            var pieces: [String] = []
            var owners: [Int] = []
            for line in translatable {
                for chunk in chunks(of: texts[line], for: leg.model, languageToken: leg.languageToken) {
                    pieces.append(chunk)
                    owners.append(line)
                }
            }
            let translated = try leg.model.translate(pieces, languageToken: leg.languageToken, stop: stop)
            var joined: [Int: [String]] = [:]
            for (line, piece) in zip(owners, translated) where !piece.isEmpty {
                joined[line, default: []].append(piece)
            }
            for line in translatable {
                texts[line] = joined[line, default: []].joined(separator: leg.joiner)
            }
        }
        return texts
    }

    /// A line too long for the model in one piece, split into sentences and packed back
    /// together up to the limit. A sentence that is too long on its own is cut between
    /// words.
    private static func chunks(of text: String, for model: MarianModel, languageToken: String?) -> [String] {
        func fits(_ piece: String) -> Bool {
            model.tokenizer.encode(piece, languageToken: languageToken).count <= model.maxChunkTokens
        }
        guard !fits(text) else { return [text] }

        var pieces: [String] = []
        for sentence in units(of: text, .sentence) {
            if fits(sentence) {
                pieces.append(sentence)
                continue
            }
            var current = ""
            for word in units(of: sentence, .word) {
                if !current.isEmpty, !fits(current + word) {
                    pieces.append(current)
                    current = ""
                }
                current += word
            }
            if !current.isEmpty { pieces.append(current) }
        }

        var chunks: [String] = []
        for piece in pieces.map({ $0.trimmingCharacters(in: .whitespaces) }) where !piece.isEmpty {
            if let last = chunks.last, fits(last + " " + piece) {
                chunks[chunks.count - 1] = last + " " + piece
            } else {
                chunks.append(piece)
            }
        }
        return chunks
    }

    /// `text` cut at the boundaries of `unit`, with whatever lies between two units
    /// (spaces, punctuation) kept on the first, so the pieces join back into `text`.
    private static func units(of text: String, _ unit: NLTokenUnit) -> [String] {
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard !ranges.isEmpty else { return [text] }
        return ranges.indices.map { index in
            let start = index == 0 ? text.startIndex : ranges[index].lowerBound
            let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            return String(text[start..<end])
        }
    }
}

/// Raised from another thread to stop a translation between decoder steps.
final class StopFlag: Sendable {
    private let raised = Atomic<Bool>(false)

    func raise() { raised.store(true, ordering: .relaxed) }
    var isRaised: Bool { raised.load(ordering: .relaxed) }
}

/// Loaded models, least recently used first. Each holds a few hundred megabytes, so only
/// a handful are kept.
private final class ModelCache: Sendable {
    private struct Entry {
        let name: String
        let task: Task<MarianModel, any Error>
    }

    private let capacity: Int
    private let entries = Mutex<[Entry]>([])

    init(capacity: Int) {
        self.capacity = capacity
    }

    func model(_ model: OpusMTModel, in directory: URL) async throws -> MarianModel {
        let task = entries.withLock { entries in
            if let index = entries.firstIndex(where: { $0.name == model.name }) {
                let entry = entries.remove(at: index)
                entries.append(entry)
                return entry.task
            }
            let task = Task.detached(priority: .userInitiated) { try MarianModel(directory: directory) }
            entries.append(Entry(name: model.name, task: task))
            if entries.count > capacity { entries.removeFirst() }
            return task
        }
        do {
            return try await task.value
        } catch {
            entries.withLock { $0.removeAll { $0.task == task } }
            throw error
        }
    }

    func removeAll() {
        entries.withLock { $0.removeAll() }
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
