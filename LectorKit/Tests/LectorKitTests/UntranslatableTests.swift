import XCTest
@testable import LectorKit

/// Text on screen that a translator would only damage: it comes back as it is.
final class UntranslatableTests: XCTestCase {
    private func kind(_ text: String) -> Untranslatable.Kind? {
        Untranslatable.kind(of: text)
    }

    func testNumbersTimesAndPricesAreKept() {
        for text in ["18:45", "$4.99", "3.8% + 40¢", "12/03/2026", "+972 52-123-4567", "—", "2801"] {
            XCTAssertEqual(kind(text), .number, text)
        }
    }

    /// A letter or two stuck to a number is a value, not a word: "4K", "v2.4.1".
    func testValuesWithALetterAreKept() {
        for text in ["4K", "v2.4.1", "1080p", "#3", "F5"] {
            XCTAssertEqual(kind(text), .number, text)
        }
    }

    /// A unit that is a word still reads better translated.
    func testNumbersWithWordsAreTranslated() {
        for text in ["14 pt", "5 min read", "Version 2.4.1 (412)", "Level 3"] {
            XCTAssertNil(kind(text), text)
        }
    }

    /// A game's status bar: stat names, each with its value. The OCR'd one has a stray
    /// mark between the stats.
    func testGameStatsAreKept() {
        for text in ["HP 120/120  MP 45/60", "HP 120/120 _ MP 45/60", "Lv 12", "ATK 340", "DEF: 85", "EXP 1500/3000"] {
            XCTAssertEqual(kind(text), .number, text)
        }
    }

    /// Words with a number on a game screen are still words.
    func testGameWordsWithNumbersAreTranslated() {
        for text in ["Day 3", "TOP 10", "Gold 300", "Wave 5", "HP potion", "Level 12 unlocked"] {
            XCTAssertNil(kind(text), text)
        }
    }

    func testKeyboardShortcutsAreKept() {
        for text in ["⌘⇧1", "⌥⌘Esc", "⇧⌘[", "⌘C, ⌘V", "Ctrl+C", "Cmd+Shift+2", "Alt+F4", "Ctrl-Alt-Del", "Shift+Tab"] {
            XCTAssertEqual(kind(text), .shortcut, text)
        }
    }

    /// A key named inside a sentence or a prompt is part of something to translate.
    func testPromptsNamingAKeyAreTranslated() {
        for text in ["[E] Continue", "Press ⌘C to copy", "Shift happens", "Tab"] {
            XCTAssertNil(kind(text), text)
        }
    }

    func testCodeIsKept() {
        for text in [
            "git commit -m \"fix overlay\"",
            "let x = foo(bar)",
            "print(\"hello\")",
            "npm install --save react",
            "cd ~/Projects/lector",
            "func translate(_ text: String) -> String {",
            "SELECT * FROM users WHERE id = 1;",
            "if (a == b) { return; }",
            "const value = await fetch(url);",
            "import Foundation",
            "#include <stdio.h>",
            "user_name",
            "getElementById",
        ] {
            XCTAssertEqual(kind(text), .code, text)
        }
    }

    /// Prose with brackets, symbols or a flag in it is still prose.
    func testProseWithSymbolsIsTranslated() {
        for text in [
            "Public paid tiers (e.g., $20/mo for 3.8% + 40¢)",
            "Use the --verbose flag to see more.",
            "Open the door and take the left corridor.",
            "By Dana Levi · 5 min read · Updated 09:42",
            "Select file(s) to upload",
            "Go to Settings -> Privacy",
            "let me know when you're free",
            "DELETE ACCOUNT",
            "x = 3 is the answer",
            "Rock & Roll",
            "C'est la vie",
            "Save",
            "iPhone",
            "macOS",
        ] {
            XCTAssertNil(kind(text), text)
        }
    }

    func testAddressesAreKept() {
        for text in ["https://lector.app/help", "www.apple.com", "lector.app/help", "support@lector.app",
                     "/usr/local/bin", "~/Library/Application Support", "C:\\Program Files", "notes.txt"] {
            XCTAssertEqual(kind(text), .address, text)
        }
    }

    func testAbbreviationsAreNotAddresses() {
        for text in ["e.g.", "i.e.", "U.S.A.", "Mr. Smith"] {
            XCTAssertNil(kind(text), text)
        }
    }
}
