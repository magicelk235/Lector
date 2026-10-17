import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut in the form Carbon's hot-key API takes it.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey | shiftKey` …), not `NSEvent.ModifierFlags`.
    var modifiers: UInt32
    /// What the key prints, for display only.
    var key: String

    static let grabDefault = Shortcut(keyCode: UInt32(kVK_ANSI_2),
                                      modifiers: UInt32(cmdKey | shiftKey), key: "2")
    static let translateDefault = Shortcut(keyCode: UInt32(kVK_ANSI_1),
                                           modifiers: UInt32(cmdKey | shiftKey), key: "1")
    /// Clear of macOS's own ⌘⇧3–⌘⇧6 screenshot shortcuts.
    static let liveDefault = Shortcut(keyCode: UInt32(kVK_ANSI_9),
                                      modifiers: UInt32(cmdKey | shiftKey), key: "9")

    /// Standard macOS order: ⌃⌥⇧⌘.
    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }
}

/// What the pill beside a capture shows. Downloads and warnings always show: without
/// them a translation that's waiting, or partly missing, looks broken.
struct PillOptions: Codable, Equatable, Sendable {
    /// The keys that work over the capture: "⌘C copy", "Tab translate".
    var showsKeys = true
    /// What's translated into what: "French → Hebrew".
    var showsLanguages = true
    /// After a few seconds, only the essentials, so it doesn't compete with the text.
    var shortens = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsKeys = try container.decodeIfPresent(Bool.self, forKey: .showsKeys) ?? true
        showsLanguages = try container.decodeIfPresent(Bool.self, forKey: .showsLanguages) ?? true
        shortens = try container.decodeIfPresent(Bool.self, forKey: .shortens) ?? true
    }
}

/// A word or name an app's text should keep, or always translate the same way: a
/// character's name, a place, a game's own term. Only terms the user added are kept.
struct GlossaryTerm: Codable, Equatable, Hashable, Sendable {
    /// As it's written in the app.
    var original: String
    /// What to put in its place, or nil to keep it as it's written.
    var translation: String?
    /// The language `translation` is in: it applies only to translations into that one.
    /// Nil with a nil `translation`.
    var target: String?

    static func keep(_ original: String) -> GlossaryTerm {
        GlossaryTerm(original: original, translation: nil, target: nil)
    }
}

/// Where live translation watched in an app's window, as shares of the window's width
/// and height from its top-left corner: a game or a video scales its picture with its
/// window, so the same dialogue box is found at a new size, or full screen.
struct LiveArea: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct AppSettings: Codable, Equatable, Sendable {
    var grabShortcut: Shortcut = .grabDefault
    var translateShortcut: Shortcut = .translateDefault
    var liveShortcut: Shortcut = .liveDefault
    /// BCP-47 language code the translate hotkey translates into.
    var targetLanguage: String = AppSettings.systemLanguage
    /// The language an app's text is in, by the app's bundle identifier, picked with Tab
    /// over its translation or in Settings: what decides where detection can't tell, like
    /// a game in Japanese written mostly in kanji. No text is kept, only the choice.
    var sourceLanguages: [String: String] = [:]
    /// The languages translated into lately, the latest first, offered first in the
    /// language menus. Only the codes are kept.
    var recentTargets: [String] = []
    /// The languages translated from lately, likewise: first in an app's language picker.
    var recentSources: [String] = []
    /// Whether to download offline packs for pairs Apple translates too, for an instant
    /// draft while Apple's version comes. Off: packs then download only for pairs Apple
    /// can't translate, where they are the only way.
    var prefetchesPacks = false
    var pill = PillOptions()
    /// Each app's glossary, by bundle identifier.
    var glossaries: [String: [GlossaryTerm]] = [:]
    /// The area live translation last watched in each app, by bundle identifier: ⌘⇧9
    /// there watches it again without drawing it.
    var liveAreas: [String: LiveArea] = [:]

    static var systemLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    init() {}

    /// Field-by-field so adding a setting later keeps everything else a user chose,
    /// instead of failing the whole decode and silently resetting them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grabShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .grabShortcut) ?? .grabDefault
        translateShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .translateShortcut) ?? .translateDefault
        liveShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .liveShortcut) ?? .liveDefault
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? Self.systemLanguage
        sourceLanguages = try container.decodeIfPresent([String: String].self, forKey: .sourceLanguages) ?? [:]
        recentTargets = try container.decodeIfPresent([String].self, forKey: .recentTargets) ?? []
        recentSources = try container.decodeIfPresent([String].self, forKey: .recentSources) ?? []
        prefetchesPacks = try container.decodeIfPresent(Bool.self, forKey: .prefetchesPacks) ?? false
        pill = try container.decodeIfPresent(PillOptions.self, forKey: .pill) ?? PillOptions()
        glossaries = try container.decodeIfPresent([String: [GlossaryTerm]].self, forKey: .glossaries) ?? [:]
        liveAreas = try container.decodeIfPresent([String: LiveArea].self, forKey: .liveAreas) ?? [:]
    }

    /// Notes a translation into `target` from `source`, the language most of the text
    /// turned out to be in (nil until that's known), for the top of the language pickers.
    mutating func noteTranslation(into target: String, from source: Locale.Language?) {
        Self.note(target, in: &recentTargets)
        // As detected: a bare "zh" is Simplified, not whichever Chinese the user reads.
        if let source = source.flatMap({ Languages.target(for: $0.minimalIdentifier, preferred: []) }),
           source != target {
            Self.note(source, in: &recentSources)
        }
    }

    private static func note(_ code: String, in recent: inout [String]) {
        recent.removeAll { $0 == code }
        recent.insert(code, at: 0)
        recent = Array(recent.prefix(Languages.suggestionCount))
    }
}
