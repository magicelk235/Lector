import Foundation

/// Whether a translator can translate a language pair right now.
public enum TranslatorAvailability: Sendable, Equatable {
    case ready
    /// Supported once about this many bytes of models are downloaded.
    case needsDownload(bytes: Int64)
    case unsupported
}

/// Something that translates text between languages. Multi-line text keeps its line
/// breaks: each line comes back as one line.
public protocol Translator: Sendable {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslatorAvailability
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
}
