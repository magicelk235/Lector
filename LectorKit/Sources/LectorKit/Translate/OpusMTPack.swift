import Foundation

/// An installed offline language pack, described for people: what it translates, which
/// languages that covers when it's more than one, and what it takes up on disk.
public struct OpusMTPack: Sendable, Identifiable, Hashable {
    /// The model's name, e.g. `opus-mt-ROMANCE-en`.
    public let id: String
    /// What it translates, e.g. "Hebrew → English", "Romance languages → English".
    public let title: String
    /// The languages it reads, most widely used first, when it reads more than one.
    public let sourceLanguages: [String]
    /// The languages it writes, likewise.
    public let targetLanguages: [String]
    public let bytesOnDisk: Int64

    init(model: OpusMTModel, bytesOnDisk: Int64) {
        id = model.name
        self.bytesOnDisk = bytesOnDisk
        let sources = Self.languages(model.sources)
        let targets = Self.languages(model.targets.keys)
        sourceLanguages = sources.count > 1 ? sources : []
        targetLanguages = targets.count > 1 ? targets : []
        title = "\(Self.side(sources, group: model.sourceGroup, family: Self.family(model, side: 0))) → "
            + Self.side(targets, group: model.targetGroup, family: Self.family(model, side: 1))
    }

    /// "Spanish, French, Italian, Portuguese, Romanian and 19 more": the languages a
    /// many-language pack reads, or writes when it reads only one; nil for a pack
    /// between two languages.
    public var coverage: String? {
        let names = sourceLanguages.isEmpty ? targetLanguages : sourceLanguages
        guard !names.isEmpty else { return nil }
        let shown = 5
        guard names.count > shown + 1 else { return ListFormatter.localizedString(byJoining: names) }
        return names.prefix(shown).joined(separator: ", ") + " and \(names.count - shown) more"
    }

    /// One side of the title: the language, the family the model card names, or the
    /// family its name gives, or failing all of those its first few languages.
    private static func side(_ names: [String], group: String?, family: String?) -> String {
        if names.count == 1 { return names[0] }
        if let group { return group.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression) }
        if let family { return family }
        return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
    }

    /// Opus spells a family in capitals in the model's name (`opus-mt-ROMANCE-en`), where
    /// the card names none.
    private static func family(_ model: OpusMTModel, side: Int) -> String? {
        let codes = model.name.replacingOccurrences(of: "opus-mt-", with: "").split(separator: "-")
        guard codes.count == 2, codes[side].count > 3, codes[side] == codes[side].uppercased() else { return nil }
        return String(codes[side].prefix(1)) + codes[side].dropFirst().lowercased() + " languages"
    }

    /// The names of the languages behind catalog keys, each once (Simplified and
    /// Traditional Chinese are both Chinese), the user's own languages first, then the
    /// most widely used, then the rest alphabetically. Keys Foundation has no name for
    /// are left out.
    private static func languages(_ keys: some Collection<String>) -> [String] {
        let codes = Set(keys.map { String($0.split(separator: "-")[0]) })
        let preferred = Locale.preferredLanguages.compactMap { Locale.Language(identifier: $0).languageCode?.identifier }
        func rank(_ code: String) -> Int {
            if let index = preferred.firstIndex(of: code) { return index - preferred.count }
            return widelyUsed.firstIndex(of: code) ?? widelyUsed.count
        }
        let named = codes.compactMap { code in Locale.current.localizedString(forLanguageCode: code).map { (code, $0) } }
        let ordered = named.sorted { lhs, rhs in
            (rank(lhs.0), lhs.1) < (rank(rhs.0), rhs.1)
        }
        var seen = Set<String>()
        return ordered.map(\.1).filter { seen.insert($0).inserted }
    }

    /// Roughly by how many people read them, so a family pack leads with the languages
    /// someone is likeliest to be looking for.
    private static let widelyUsed = [
        "en", "zh", "es", "hi", "ar", "fr", "pt", "ru", "bn", "ja", "de", "id", "ur", "it", "tr", "ko", "vi",
        "fa", "pl", "uk", "nl", "th", "ro", "el", "cs", "sv", "hu", "he", "ca", "da", "fi", "nb", "sk", "bg",
        "hr", "sr", "lt", "lv", "et", "sl", "gl", "is", "af", "ms", "tl", "sw",
    ]
}
