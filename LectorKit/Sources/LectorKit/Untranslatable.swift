import Foundation

/// Screen text a translator can only damage — a time, a shortcut, a line of code, a
/// web address — recognised so it is shown as it is.
///
/// Translators don't leave these alone. Measured on Apple's: `git commit -m "fix
/// overlay"` came back with the message translated, and the offline models invent
/// words for "12:30". Each rule is narrow on purpose: a paragraph wrongly kept is left
/// untranslated, which is worse than a paragraph needlessly sent through.
public enum Untranslatable {
    public enum Kind: Sendable, Equatable {
        /// No words: numbers, times, prices, a value like "4K" or "v2.4.1", a game's stats.
        case number
        /// Keyboard shortcuts only: "⌘⇧1", "Ctrl+C".
        case shortcut
        /// A line of code or a shell command.
        case code
        /// A web or email address, or a file path.
        case address
    }

    public static func kind(of text: String) -> Kind? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isShortcut(text) { return .shortcut }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if isNumber(text) || isStats(tokens) { return .number }
        if isAddress(text) { return .address }
        if isCode(text, tokens: tokens) { return .code }
        return nil
    }

    // MARK: - Numbers

    /// No letters at all, or digits with at most two letters attached to them — and
    /// no word of letters alone, so "14 pt" and "Level 3" are still translated.
    private static func isNumber(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        guard letters > 0 else { return true }
        guard letters <= 2, text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else { return false }
        return !text.split(whereSeparator: \.isWhitespace).contains { token in
            token.unicodeScalars.contains(where: CharacterSet.letters.contains)
                && !token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
        }
    }

    /// What a game's status bar names its numbers by.
    private static let statNames: Set<String> = [
        "hp", "mp", "sp", "ap", "xp", "exp", "lv", "lvl", "atk", "def", "matk", "mdef", "str", "dex", "agi", "vit",
        "int", "wis", "luk", "lck", "spd", "dmg", "crit",
    ]

    /// A game's status bar — "HP 120/120  MP 45/60", "Lv 12", "ATK 340": stat names, each
    /// followed by its value, with nothing between them but marks. Not "HP potion" or
    /// "TOP 10", which are words.
    private static func isStats(_ tokens: [String]) -> Bool {
        var named = false, waiting = false
        for token in tokens {
            let name = token.prefix(while: \.isLetter)
            let rest = token.dropFirst(name.count)
            guard !rest.contains(where: \.isLetter) else { return false }
            if !name.isEmpty {
                guard !waiting, statNames.contains(name.lowercased()) else { return false }
                named = true
                waiting = !rest.contains(where: \.isNumber)
            } else if rest.contains(where: \.isNumber) {
                guard named else { return false }
                waiting = false
            }
        }
        return named && !waiting
    }

    // MARK: - Shortcuts

    private static let modifierSymbols: Set<Character> = ["⌘", "⌥", "⌃", "⇧", "⇪"]
    private static let keySymbols: Set<Character> = ["↩", "⏎", "⌫", "⌦", "⎋", "⇥", "⇤", "␣", "⇞", "⇟", "↖", "↘",
                                                     "←", "→", "↑", "↓", "⏏", "⌤"]
    private static let modifierNames: Set<String> = ["ctrl", "control", "cmd", "command", "alt", "option", "opt",
                                                     "shift", "win", "super", "meta", "fn"]
    private static let keyNames: Set<String> = ["esc", "escape", "tab", "space", "return", "enter", "delete", "del",
                                                "backspace", "home", "end", "pgup", "pgdn", "pageup", "pagedown",
                                                "up", "down", "left", "right", "ins", "insert"]

    /// Every piece is a shortcut — "⌘C, ⌘V" — and there is at least one.
    private static func isShortcut(_ text: String) -> Bool {
        let pieces = text.split { $0.isWhitespace || $0 == "," || $0 == "/" }.map(String.init)
        return !pieces.isEmpty && pieces.allSatisfy { isSymbolShortcut($0) || isNamedShortcut($0) }
    }

    /// Modifier symbols, then one key: "⌥⌘Esc", "⇧⌘[".
    private static func isSymbolShortcut(_ piece: String) -> Bool {
        let key = piece.drop { modifierSymbols.contains($0) }
        guard key.count < piece.count else { return false }
        return isKey(String(key))
    }

    /// Modifier names joined to a key with "+" or "-": "Ctrl+C", "Ctrl-Alt-Del".
    private static func isNamedShortcut(_ piece: String) -> Bool {
        let parts = piece.split(omittingEmptySubsequences: false) { $0 == "+" || $0 == "-" }.map(String.init)
        guard parts.count >= 2, let key = parts.last else { return false }
        return parts.dropLast().allSatisfy { modifierNames.contains($0.lowercased()) }
            && (isKey(key) || modifierNames.contains(key.lowercased()))
    }

    private static func isKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        if key.count == 1 { return !first.isWhitespace }
        if key.allSatisfy(keySymbols.contains) { return true }
        let lowered = key.lowercased()
        if keyNames.contains(lowered) { return true }
        // F1–F20.
        if lowered.first == "f", let number = Int(lowered.dropFirst()), (1...20).contains(number) { return true }
        return false
    }

    // MARK: - Addresses

    private static let addressPatterns: [NSRegularExpression] = [
        "^[A-Za-z][A-Za-z0-9+.-]*://\\S+$", // scheme://…
        "^www\\.\\S+$",
        "^[^\\s@]+@[^\\s@]+\\.[A-Za-z]{2,}$", // email
        "^[A-Za-z]:\\\\", // C:\…
        // A domain or file name: dotted labels ending in one with a letter, e.g.
        // "lector.app/help", "notes.txt" — but not "e.g." or "U.S.A.".
        "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z][A-Za-z0-9-]+(/\\S*)?$",
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func isAddress(_ text: String) -> Bool {
        if matches(text, addressPatterns) { return true }
        // A path: from the root, home or here, with no spaces or more than one folder.
        guard text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") else {
            return false
        }
        return !text.contains(where: \.isWhitespace) || text.filter { $0 == "/" }.count >= 2
    }

    // MARK: - Code

    /// Sequences that occur in code and almost never in prose.
    private static let operators = ["{", "}", "==", "!=", "+=", "-=", ":=", "&&", "</", "/>"]
    /// Each of these turns up in prose now and then ("file(s)", "x = 3", "Settings ->
    /// Privacy"); two together, or one on a line that is a single token, don't.
    private static let codeSignals: [NSRegularExpression] = [
        "[A-Za-z_][A-Za-z0-9_.]*\\((?!e?s\\))", // a call: foo(, os.path.join( — not "file(s)"
        "[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*\\S", // an assignment: x = …
        "[;{]$",
        "->|=>|::|\\|\\|",
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let preprocessor: Set<String> = ["#include", "#import", "#define"]
    private static let declarations: Set<String> = ["let", "var", "const"]
    private static let commands: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "brew", "cd", "ls", "sudo", "swift", "python", "python3", "pip",
        "pip3", "node", "cargo", "go", "docker", "kubectl", "make", "curl", "wget", "ssh", "scp", "rm", "cp", "mv",
        "mkdir", "cat", "echo", "grep", "chmod", "chown", "export", "xcodebuild", "xcrun", "defaults", "open",
        "killall", "launchctl", "tar", "unzip", "ruby", "gem", "bundle", "rails", "java", "javac", "gcc", "clang",
    ]

    private static func isCode(_ text: String, tokens: [String]) -> Bool {
        guard let first = tokens.first else { return false }
        if operators.contains(where: text.contains) { return true }
        let signals = codeSignals.filter { matches(text, [$0]) }.count
        if tokens.count == 1 { return signals > 0 || matches(first, identifierPatterns) }
        if signals >= 2 || preprocessor.contains(first) { return true }
        // `let x = …`, `const y: Int` — not "let me know".
        if declarations.contains(first), tokens.count >= 3, matches(tokens[1], [identifier]),
           tokens[2] == "=" || tokens[1].hasSuffix(":") {
            return true
        }
        // `import Foundation`, `import os.path`.
        if first == "import", tokens.count == 2, matches(tokens[1], [identifier]) { return true }
        // A shell command: a known command with a flag or a path after it.
        if commands.contains(first) {
            return tokens.dropFirst().contains { token in
                token.hasPrefix("--") || (token.hasPrefix("-") && token.dropFirst().first?.isLetter == true)
                    || token.contains("/")
            }
        }
        return false
    }

    private static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_.]*:?$")

    /// `snake_case` or `camelCaseWithHumps`. One hump isn't enough: "iPhone", "macOS".
    private static let identifierPatterns: [NSRegularExpression] = [
        "^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+$",
        "^[a-z]{2,}([A-Z][a-z0-9]+){2,}$",
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func matches(_ text: String, _ patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
