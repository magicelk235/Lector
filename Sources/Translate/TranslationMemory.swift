import Foundation

/// Translations made since launch, held in memory only and never written anywhere, so
/// a paragraph seen again shows at once instead of being translated again: the same
/// screen captured twice, a subtitle line that comes back, live translation reading a
/// region that only scrolled.
@MainActor
final class TranslationMemory {
    struct Entry: Equatable {
        let text: String
        /// The best this Mac can do for the pair. A draft is shown at once but is still
        /// sent on for the final version.
        let isFinal: Bool
    }

    private var entries: [String: (entry: Entry, used: Int)] = [:]
    private var clock = 0
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    func lookup(_ text: String, from source: Locale.Language, to target: Locale.Language) -> Entry? {
        let key = Self.key(text, source, target)
        guard let found = entries[key] else { return nil }
        clock += 1
        entries[key] = (found.entry, clock)
        return found.entry
    }

    /// A draft never replaces a final translation of the same text.
    func remember(_ translation: String, isFinal: Bool, for text: String,
                  from source: Locale.Language, to target: Locale.Language) {
        let key = Self.key(text, source, target)
        if let existing = entries[key], existing.entry.isFinal, !isFinal { return }
        clock += 1
        entries[key] = (Entry(text: translation, isFinal: isFinal), clock)
        if entries.count > capacity { evictOldest() }
    }

    /// The least recently used tenth, at once, so this runs once per hundreds of entries.
    private func evictOldest() {
        for (key, _) in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(max(1, capacity / 10)) {
            entries[key] = nil
        }
    }

    /// By language rather than full identifier, so "fr" and "fr-FR" share entries, but
    /// Chinese keeps its script: Simplified and Traditional are read as separate languages.
    private static func key(_ text: String, _ source: Locale.Language, _ target: Locale.Language) -> String {
        var language = source.languageCode?.identifier ?? source.minimalIdentifier
        if language == "zh" {
            language += "-" + (source.script?.identifier
                ?? Locale.Language(identifier: source.maximalIdentifier).script?.identifier ?? "")
        }
        return "\(language)>\(target.minimalIdentifier)\u{1}" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
