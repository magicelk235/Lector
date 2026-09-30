import Foundation

/// One downloadable Opus-MT model: an ONNX export of a Helsinki-NLP model, pinned to the
/// commit the catalog was generated from.
struct OpusMTModel: Sendable, Hashable {
    enum Kind: Int, Sendable, Comparable {
        /// One language to one language.
        case specific
        /// A language family, such as Romance or West Germanic, on one side or both.
        case group
        /// A hundred or more languages on one side. Broad, but the weakest per language.
        case multilingual

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct File: Sendable, Hashable {
        /// Path inside the repository.
        let remotePath: String
        /// Name on disk, the same for every export so the loader need not know which it has.
        let localName: String
        let bytes: Int64
        /// The Git LFS hash, for the files stored in LFS; empty for small files in Git itself.
        let sha256: String

        init(_ remotePath: String, _ localName: String, _ bytes: Int64, _ sha256: String) {
            self.remotePath = remotePath
            self.localName = localName
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    /// The Helsinki-NLP model name, e.g. `opus-mt-he-de`. Also the directory it installs to.
    let name: String
    let repository: String
    let revision: String
    let kind: Kind
    let files: [File]
    /// Language keys the model reads: ISO 639-1 codes (639-3 where there is none), with a
    /// script suffix only where it is not the language's usual one, and always for Chinese.
    let sources: Set<String>
    /// Language keys the model writes, each with the `>>xxx<<` token that selects it, or an
    /// empty string where the model writes only one language and takes no token.
    let targets: [String: String]
    let sourceGroup: String?
    let targetGroup: String?

    init(
        name: String, repository: String, revision: String, kind: Kind, files: [File],
        sources: String, targets: String, sourceGroup: String?, targetGroup: String?
    ) {
        self.name = name
        self.repository = repository
        self.revision = revision
        self.kind = kind
        self.files = files
        self.sources = Set(sources.split(separator: " ").map(String.init))
        var parsed: [String: String] = [:]
        for entry in targets.split(separator: " ") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            parsed[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        self.targets = parsed
        self.sourceGroup = sourceGroup
        self.targetGroup = targetGroup
    }

    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.remotePath)")!
    }
}

/// A way to translate one language into another: a single model, or two with English
/// between them.
struct OpusMTRoute: Sendable, Equatable {
    struct Leg: Sendable, Equatable {
        let model: OpusMTModel
        /// The `>>xxx<<` prefix the model needs to know which language to write, if any.
        let languageToken: String?
    }

    let legs: [Leg]

    var models: [OpusMTModel] { legs.map(\.model) }
    var isPivot: Bool { legs.count > 1 }
}

/// Every Opus-MT model the app can download, and the choice of which to use for a pair.
/// The table itself is generated into `OpusMTCatalog+Models.swift`.
struct OpusMTCatalog: Sendable {
    static let shared = OpusMTCatalog(models: OpusMTCatalog.models)

    let models: [OpusMTModel]
    private let pivot = "en"

    init(models: [OpusMTModel]) {
        self.models = models
    }

    /// The best route between two languages, or nil when there is none.
    ///
    /// A direct model beats a pivot of the same quality, since every pass through English
    /// loses something; a specific model beats a family model, which beats one of the
    /// hundred-language models. Among equals the smaller download wins.
    func route(from source: Locale.Language, to target: Locale.Language) -> OpusMTRoute? {
        guard let sourceKey = key(for: source, among: \.sources),
              let targetKey = key(for: target, among: { Set($0.targets.keys) }),
              sourceKey != targetKey
        else { return nil }
        return route(from: sourceKey, to: targetKey)
    }

    func route(from source: String, to target: String) -> OpusMTRoute? {
        guard source != target else { return nil }
        var candidates: [OpusMTRoute] = []
        if let direct = bestLeg(from: source, to: target) {
            candidates.append(OpusMTRoute(legs: [direct]))
        }
        if source != pivot, target != pivot,
           let first = bestLeg(from: source, to: pivot), let second = bestLeg(from: pivot, to: target) {
            candidates.append(OpusMTRoute(legs: [first, second]))
        }
        return candidates.min { Self.cost($0) < Self.cost($1) }
    }

    private static func cost(_ route: OpusMTRoute) -> (Int, Int, Int64) {
        let penalty = route.legs.reduce(0) { total, leg in
            let legPenalty = switch leg.model.kind {
            case .specific: 1
            case .group: 2
            case .multilingual: 4
            }
            return total + legPenalty
        }
        return (penalty, route.legs.count, route.models.reduce(0) { $0 + $1.bytes })
    }

    private func bestLeg(from source: String, to target: String) -> OpusMTRoute.Leg? {
        models
            .filter { $0.sources.contains(source) && $0.targets[target] != nil }
            .min { ($0.kind, $0.bytes, $0.name) < ($1.kind, $1.bytes, $1.name) }
            .map { OpusMTRoute.Leg(model: $0, languageToken: $0.targets[target].flatMap { $0.isEmpty ? nil : $0 }) }
    }

    // MARK: - Language keys

    /// Codes Foundation may hand back that Opus files under another name.
    private static let aliases = [
        "iw": "he", "in": "id", "ji": "yi", "jw": "jv", "mo": "ro",
        "no": "nb", "fil": "tl", "tgl": "tl",
    ]

    /// The catalog's key for a language on one side of a pair: its ISO 639-1 code where it
    /// has one (639-3 where not), with the script appended when it is not the language's
    /// usual one and the catalog has that form, so "sr-Latn" stays Latin but "ko-Hang"
    /// still finds Korean. Chinese always carries its script, since Simplified and
    /// Traditional are separate targets.
    private func key(for language: Locale.Language, among side: (OpusMTModel) -> Set<String>) -> String? {
        let candidates = Self.candidateKeys(for: language)
        return candidates.first { key in models.contains { side($0).contains(key) } }
    }

    private static func candidateKeys(for language: Locale.Language) -> [String] {
        guard let languageCode = language.languageCode else { return [] }
        var code = languageCode.identifier(.alpha2) ?? languageCode.identifier
        code = aliases[code.lowercased()] ?? code.lowercased()
        let script = language.script?.identifier
            ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier
        if code == "zh" {
            return [script == "Hant" ? "zh-Hant" : "zh-Hans"]
        }
        let defaultScript = Locale.Language(identifier: code).maximalIdentifier
            .split(separator: "-").dropFirst().first { $0.count == 4 }.map(String.init)
        if let script, script != defaultScript {
            return ["\(code)-\(script)", code]
        }
        return [code]
    }
}
