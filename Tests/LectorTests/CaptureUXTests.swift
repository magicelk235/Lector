import Carbon.HIToolbox
import CoreGraphics
import LectorKit
import SwiftUI
import XCTest
@testable import Lector

/// Lines of words, one rect per word; `spaced: false` writes a line's words without
/// spaces between them, as CJK text is.
private func capture(_ lines: [[String]], spaced: Bool = true) -> RecognizedText {
    var words: [RecognizedWord] = []
    var built: [RecognizedLine] = []
    for (index, line) in lines.enumerated() {
        let start = words.count
        for (offset, word) in line.enumerated() {
            words.append(RecognizedWord(text: word, rect: CGRect(x: CGFloat(offset) * 48, y: CGFloat(index) * 24,
                                                                width: 40, height: 20),
                                        lineIndex: index))
        }
        let rect = CGRect(x: 0, y: CGFloat(index) * 24, width: CGFloat(line.count) * 48, height: 20)
        built.append(RecognizedLine(text: line.joined(separator: spaced ? " " : ""), rect: rect,
                                    wordRange: start..<words.count))
    }
    return RecognizedText(words: words, lines: built)
}

final class CopiedTextTests: XCTestCase {
    func testWrappedParagraphCopiesAsOneLine() {
        let text = capture([["Vous", "pouvez"], ["l'annuler", "à", "tout"], ["moment."], ["Merci."]])
        let copied = CopiedText.text(ofWords: 0...6, in: text, paragraphs: [0..<3, 3..<4])
        XCTAssertEqual(copied, "Vous pouvez l'annuler à tout moment.\nMerci.")
    }

    func testPartOfAParagraphJoinsAcrossTheWrap() {
        let text = capture([["Vous", "pouvez"], ["l'annuler", "à", "tout"]])
        XCTAssertEqual(CopiedText.text(ofWords: 1...2, in: text, paragraphs: [0..<2]), "pouvez l'annuler")
    }

    func testWordBrokenByAHyphenIsMadeWhole() {
        let text = capture([["the", "trans-"], ["lation", "works"]])
        XCTAssertEqual(CopiedText.text(ofWords: 0...3, in: text, paragraphs: [0..<2]), "the translation works")
    }

    func testSpacelessScriptJoinsWithoutASpace() {
        let text = capture([["我们", "的"], ["应用", "程序"]], spaced: false)
        XCTAssertEqual(CopiedText.text(ofWords: 0...3, in: text, paragraphs: [0..<2]), "我们的应用程序")
    }

    func testLinesOutsideAnyParagraphKeepTheirBreaks() {
        let menu = capture([["New", "Window"], ["Open"], ["Close"]])
        XCTAssertEqual(CopiedText.text(ofWords: 0...3, in: menu, paragraphs: []), "New Window\nOpen\nClose")
    }
}

final class ToastDurationTests: XCTestCase {
    func testLongerMessagesStayLonger() {
        let short = Toast.duration(for: "Copied", kind: .confirmation)
        let long = Toast.duration(for: "Couldn't translate this text because the language pack failed.", kind: .confirmation)
        XCTAssertGreaterThanOrEqual(short, 1.2)
        XCTAssertGreaterThan(long, short + 2)
    }

    func testNoticesStayAtLeastThreeSeconds() {
        XCTAssertGreaterThanOrEqual(Toast.duration(for: "Oops", kind: .notice), 3)
    }

    func testNothingStaysForever() {
        XCTAssertLessThanOrEqual(Toast.duration(for: String(repeating: "word ", count: 200), kind: .notice), 10)
    }
}

final class CapturePillPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
    private let pill = CGSize(width: 300, height: 30)

    func testSitsJustBelowTheCaptureCentredWhenThereIsRoom() {
        let capture = CGRect(x: 100, y: 100, width: 400, height: 200)
        let placed = CapturePill.frame(size: pill, beside: capture, within: screen, avoiding: [])
        XCTAssertFalse(placed.inside)
        XCTAssertEqual(placed.frame.minY, capture.maxY + CapturePill.gap)
        XCTAssertEqual(placed.frame.midX, capture.midX)
    }

    func testGoesAboveWhenTheCaptureReachesTheBottom() {
        let capture = CGRect(x: 100, y: 500, width: 400, height: 370)
        let placed = CapturePill.frame(size: pill, beside: capture, within: screen, avoiding: [])
        XCTAssertFalse(placed.inside)
        XCTAssertLessThanOrEqual(placed.frame.maxY, capture.minY)
    }

    func testStaysOnScreenNearTheRightEdge() {
        let capture = CGRect(x: 1300, y: 100, width: 120, height: 60)
        let placed = CapturePill.frame(size: pill, beside: capture, within: screen, avoiding: [])
        XCTAssertTrue(screen.contains(placed.frame))
    }

    func testInsideAFullScreenCaptureItTakesTheEmptiestCorner() {
        let capture = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Text everywhere along the bottom-left, nothing at the bottom right.
        let words = [CGRect(x: 0, y: 820, width: 700, height: 40), CGRect(x: 0, y: 30, width: 1440, height: 60)]
        let placed = CapturePill.frame(size: pill, beside: capture, within: screen, avoiding: words)
        XCTAssertTrue(placed.inside)
        XCTAssertFalse(words.contains { $0.intersects(placed.frame) })
        XCTAssertTrue(screen.contains(placed.frame))
    }
}

final class PillOptionsTests: XCTestCase {
    func testHidingEverythingStillShowsADownload() {
        var options = PillOptions()
        options.showsKeys = false
        options.showsLanguages = false
        let downloading = CaptureHint(status: .downloading("Czech → Hebrew", progress: 0.4),
                                      keys: CaptureHint.translating(showingOriginal: false))
        let trimmed = downloading.trimmed(by: options)
        XCTAssertEqual(trimmed.status, .downloading("Czech → Hebrew", progress: 0.4))
        XCTAssertTrue(trimmed.keys.isEmpty)
        XCTAssertTrue(CaptureHint.picking.trimmed(by: options).isEmpty)
    }

    func testSettingsSavedBeforeThePillOptionsKeepTheirDefaults() throws {
        let saved = Data(#"{"targetLanguage":"he","prefetchesPacks":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        XCTAssertEqual(settings.targetLanguage, "he")
        XCTAssertEqual(settings.pill, PillOptions())
    }
}

final class CaptureHintTests: XCTestCase {
    func testDownloadProgressIsTheSameMoment() {
        let keys = CaptureHint.translating(showingOriginal: false)
        let early = CaptureHint(status: .downloading("Czech → Hebrew", progress: 0.1), keys: keys)
        let later = CaptureHint(status: .downloading("Czech → Hebrew", progress: 0.6), keys: keys)
        let done = CaptureHint(status: .translating(from: "Czech", into: "Hebrew"), keys: keys)
        XCTAssertTrue(early.isSameMoment(as: later))
        XCTAssertFalse(later.isSameMoment(as: done))
    }

    func testSourcesNameTheTwoWithMostTextAndCountTheRest() {
        XCTAssertNil(CaptureHint.sources([]))
        XCTAssertEqual(CaptureHint.sources(["French"]), "French")
        XCTAssertEqual(CaptureHint.sources(["French", "Japanese"]), "French, Japanese")
        XCTAssertEqual(CaptureHint.sources(["French", "Japanese", "Greek", "Thai", "Korean", "German", "Polish"]),
                       "French, Japanese +5")
    }
}

final class SourceCyclingTests: XCTestCase {
    private let fr = Locale.Language(identifier: "fr")
    private let nl = Locale.Language(identifier: "nl")
    private let ca = Locale.Language(identifier: "ca")

    private func next(_ current: Int, _ choices: [Locale.Language?], backwards: Bool = false,
                      shown: String?, detected: String?) -> Int? {
        TranslationOverlayWindow.nextChoice(after: current, in: choices, backwards: backwards,
                                            shown: shown.map { Locale.Language(identifier: $0) },
                                            detected: detected.map { Locale.Language(identifier: $0) })
    }

    func testFirstTabSkipsTheLanguageAlreadyShown() {
        // Detected French, shown French: the next candidate, not French again.
        XCTAssertEqual(next(0, [nil, fr, nl, ca], shown: "fr", detected: "fr"), 2)
    }

    func testRememberedLanguageOnScreenIsSkippedToo() {
        // Dutch remembered for the app and shown: Tab goes to the likeliest other one.
        XCTAssertEqual(next(0, [nil, fr, nl, ca], shown: "nl", detected: "nl"), 1)
    }

    func testAfterTheLastComesDetectingAgainUnlessItShowsTheSame() {
        XCTAssertEqual(next(3, [nil, fr, nl, ca], shown: "ca", detected: "fr"), 0)
        XCTAssertEqual(next(3, [nil, fr, nl, ca], shown: "fr", detected: "fr"), 2)
    }

    func testShiftTabGoesBack() {
        XCTAssertEqual(next(2, [nil, fr, nl, ca], backwards: true, shown: "nl", detected: "fr"), 1)
    }

    func testNothingElseToOffer() {
        XCTAssertNil(next(0, [nil, fr], shown: "fr", detected: "fr"))
        XCTAssertNil(next(0, [nil], shown: "fr", detected: "fr"))
    }

    func testSimplifiedAndTraditionalChineseAreDifferentChoices() {
        let hans = Locale.Language(identifier: "zh-Hans"), hant = Locale.Language(identifier: "zh-Hant")
        // Shown as Simplified: Tab goes to Traditional rather than skipping it as "the same".
        XCTAssertEqual(next(0, [nil, hans, hant], shown: "zh-Hans", detected: "zh-Hans"), 2)
    }
}

final class MenuShortcutTests: XCTestCase {
    func testConfiguredShortcutShowsAsAMenuShortcut() {
        let shortcut = Shortcut.grabDefault.menuShortcut
        XCTAssertEqual(shortcut?.key, KeyEquivalent("2"))
        XCTAssertEqual(shortcut?.modifiers, [.command, .shift])
    }

    func testFunctionAndSpecialKeys() {
        let f5 = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey), key: "F5").menuShortcut
        XCTAssertEqual(f5?.key, KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)))
        XCTAssertEqual(f5?.modifiers, [.option])
        let space = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), key: "Space").menuShortcut
        XCTAssertEqual(space?.key, .space)
    }

    func testUnknownKeyHasNoMenuShortcut() {
        XCTAssertNil(Shortcut(keyCode: 999, modifiers: UInt32(cmdKey), key: "#999").menuShortcut)
    }
}

final class LikelyTargetsTests: XCTestCase {
    func testCurrentThenRecentThenPreferredThenTheRegionsEachOnce() {
        let likely = Languages.likelyTargets(current: "fr", recent: ["ja", "fr", "he"],
                                             preferred: ["he-IL", "en-GB", "en-US"], regional: ["he", "ar", "en"])
        XCTAssertEqual(likely, ["fr", "ja", "he", "en", "ar"])
    }

    func testAtMostSix() {
        let likely = Languages.likelyTargets(current: "en", recent: ["ja", "ko"], preferred: ["de-DE", "fr-FR"],
                                             regional: ["it", "es"])
        XCTAssertEqual(likely, ["en", "ja", "ko", "de", "fr", "it"])
    }

    func testOnlyLanguagesLectorTranslatesInto() {
        let likely = Languages.likelyTargets(current: "en", recent: ["xx"], preferred: ["en-US", "gsw-CH"],
                                             regional: ["rm", "de"])
        XCTAssertEqual(likely, ["en", "de"])
    }

    func testARegionSuggestsItsMainLanguageFirst() {
        let israel = Languages.spoken(in: Locale.Region("IL"))
        XCTAssertEqual(israel.first, "he")
        XCTAssertTrue(israel.contains("ar"))
        let switzerland = Languages.spoken(in: Locale.Region("CH"))
        XCTAssertEqual(switzerland.first, "de")
        XCTAssertTrue(switzerland.contains("fr") && switzerland.contains("it"))
        // Not Romansh or Swiss German, which Lector can't translate into.
        XCTAssertTrue(switzerland.allSatisfy(Languages.targets.contains))
        XCTAssertEqual(Languages.spoken(in: Locale.Region("TW")).first, "zh-Hant")
        XCTAssertEqual(Languages.spoken(in: nil), [])
    }

    func testAnAppsLanguageComesFirstThenRecentSourcesButNeverTheTarget() {
        let likely = Languages.likelySources(current: "zh-Hant", recent: ["ja", "he", "fr"], target: "he",
                                             preferred: ["en-US", "he-IL"], regional: ["he", "ar", "en"])
        XCTAssertEqual(likely, ["zh-Hant", "ja", "fr", "en", "ar"])
        // Picked with Tab, a language Lector can't translate from still shows as it is.
        XCTAssertEqual(Languages.likelySources(current: "bo", recent: [], target: "en", preferred: [], regional: []),
                       ["bo"])
    }
}

final class LanguageHistoryTests: XCTestCase {
    func testTranslationsAreNotedLatestFirstEachOnce() {
        var settings = AppSettings()
        settings.noteTranslation(into: "he", from: Locale.Language(identifier: "ja"))
        settings.noteTranslation(into: "en", from: Locale.Language(identifier: "zh-Hant"))
        settings.noteTranslation(into: "he", from: Locale.Language(identifier: "zh-Hans"))
        // Already in the language it would go into: nothing was translated from it.
        settings.noteTranslation(into: "he", from: Locale.Language(identifier: "he"))
        // Live translation, before its language is known.
        settings.noteTranslation(into: "fr", from: nil)
        XCTAssertEqual(settings.recentTargets, ["fr", "he", "en"])
        XCTAssertEqual(settings.recentSources, ["zh-Hans", "zh-Hant", "ja"])
    }

    func testOnlyAsManyAreKeptAsTheMenusSuggest() {
        var settings = AppSettings()
        for code in ["de", "fr", "it", "es", "pt", "nl", "sv", "da"] {
            settings.noteTranslation(into: code, from: nil)
        }
        XCTAssertEqual(settings.recentTargets, ["da", "sv", "nl", "pt", "es", "it"])
    }

    func testSettingsSavedBeforeTheHistoryKeepEverythingElse() throws {
        let saved = Data(#"{"targetLanguage":"he","sourceLanguages":{"com.example.game":"ja"},"prefetchesPacks":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        XCTAssertEqual(settings.targetLanguage, "he")
        XCTAssertEqual(settings.sourceLanguages, ["com.example.game": "ja"])
        XCTAssertTrue(settings.prefetchesPacks)
        XCTAssertEqual(settings.recentTargets, [])
        XCTAssertEqual(settings.recentSources, [])
    }
}

final class ChineseTargetTests: XCTestCase {
    func testSimplifiedAndTraditionalAreSeparateTargets() {
        XCTAssertTrue(Languages.targets.contains("zh-Hans"))
        XCTAssertTrue(Languages.targets.contains("zh-Hant"))
        XCTAssertFalse(Languages.targets.contains("zh"))
        XCTAssertNotEqual(Languages.name("zh-Hans"), Languages.name("zh-Hant"))
    }

    func testRegionsAndScriptsMapToTheirTarget() {
        XCTAssertEqual(Languages.target(for: "zh-TW", preferred: []), "zh-Hant")
        XCTAssertEqual(Languages.target(for: "zh-HK", preferred: []), "zh-Hant")
        XCTAssertEqual(Languages.target(for: "zh-Hans-CN", preferred: []), "zh-Hans")
        XCTAssertEqual(Languages.target(for: "zh-Hant", preferred: []), "zh-Hant")
        XCTAssertEqual(Languages.target(for: "he-IL", preferred: []), "he")
        XCTAssertNil(Languages.target(for: "xx", preferred: []))
    }

    func testBareChineseSettingTakesTheScriptTheUserReads() {
        XCTAssertEqual(Languages.target(for: "zh", preferred: ["en-US", "zh-Hant-TW"]), "zh-Hant")
        XCTAssertEqual(Languages.target(for: "zh", preferred: ["en-US"]), "zh-Hans")
    }

    func testTargetLanguageIsNamedWithItsScript() {
        XCTAssertEqual(Languages.name(Locale.Language(identifier: "zh-Hant")), Languages.name("zh-Hant"))
        XCTAssertEqual(Languages.name(Locale.Language(identifier: "he")), Languages.name("he"))
    }

    func testLikelyTargetsKeepTheScript() {
        XCTAssertEqual(Languages.likelyTargets(current: "zh-Hant", preferred: ["en-US", "zh-Hans-CN"], regional: []),
                       ["zh-Hant", "en", "zh-Hans"])
    }
}
