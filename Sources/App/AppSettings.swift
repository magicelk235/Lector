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

struct AppSettings: Codable, Equatable, Sendable {
    var grabShortcut: Shortcut = .grabDefault
    var translateShortcut: Shortcut = .translateDefault
    /// BCP-47 language code the translate hotkey translates into.
    var targetLanguage: String = AppSettings.systemLanguage

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
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? Self.systemLanguage
    }
}
