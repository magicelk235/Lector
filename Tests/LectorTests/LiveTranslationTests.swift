import AppKit
import CoreGraphics
import LectorKit
import XCTest
@testable import Lector

/// A frame as the grid of cell brightnesses the watcher compares.
private func frame(_ value: UInt8 = 200, changing cells: [Int: UInt8] = [:]) -> FrameSignature {
    var grid = [UInt8](repeating: value, count: FrameSignature.columns * 4)
    for (cell, brightness) in cells { grid[cell] = brightness }
    return FrameSignature(cells: grid, rows: 4)
}

final class FrameSignatureTests: XCTestCase {
    /// A word appearing in one corner of a region moves its cell's brightness by far
    /// more than the threshold.
    func testTextChangeShowsInItsCell() throws {
        let blank = try signature(of: image(width: 960, height: 160) { _ in })
        let written = try signature(of: image(width: 960, height: 160) { context in
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 20, y: 120, width: 60, height: 14)) // a word's worth of ink
        })
        XCTAssertGreaterThan(written.changedCells(from: blank), 0)
        XCTAssertEqual(blank.changedCells(from: blank), 0)
    }

    /// A one-level flicker, as compression or a cursor shadow leaves, is not a change.
    func testFaintNoiseIsNotAChange() {
        XCTAssertEqual(frame(200).changedCells(from: frame(201, changing: [3: 202])), 0)
    }

    private func image(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return pixels
    }

    private func signature(of pixels: CVPixelBuffer) throws -> FrameSignature {
        try XCTUnwrap(FrameSignature(pixels))
    }
}

final class ChangeDetectorTests: XCTestCase {
    func testFirstFrameIsReadAtOnce() {
        var detector = ChangeDetector()
        XCTAssertEqual(detector.observe(frame(), at: 0), .read)
    }

    /// Nothing on screen changes: frames are compared and nothing is read, however many.
    func testStillScreenIsNeverReadAgain() {
        var detector = ChangeDetector()
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0.1, textChanged: true)
        for step in 1...50 {
            XCTAssertEqual(detector.observe(frame(), at: 0.1 + Double(step) * 0.2), .idle)
        }
        XCTAssertEqual(detector.tick(at: 20), .idle)
    }

    /// New text is read once the picture has held still for a moment — after the fade,
    /// not in the middle of it.
    func testChangeIsReadOnceItSettles() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0, textChanged: true)
        XCTAssertEqual(detector.observe(frame(changing: [5: 40]), at: 1.0), .wait(until: 1.25))
        XCTAssertEqual(detector.observe(frame(changing: [5: 30]), at: 1.1), .wait(until: 1.35))
        XCTAssertEqual(detector.tick(at: 1.36), .read)
    }

    /// Video behind subtitles never holds still: it is read after the most it waits.
    func testPictureThatNeverSettlesIsReadAfterAWhile() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0, textChanged: true)
        var time = 1.0, decision = ChangeDetector.Decision.idle, step = 0
        while time < 3, decision != .read {
            step += 1
            decision = detector.observe(frame(changing: [7: UInt8(step % 3 * 40)]), at: time)
            time += 0.1
        }
        XCTAssertEqual(decision, .read)
        XCTAssertEqual(time, 2.1, accuracy: 0.01)
    }

    /// A caret blinking back to how it looked when last read cancels the change.
    func testReturningToTheLastReadPictureIsNoChange() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0, textChanged: true)
        XCTAssertNotEqual(detector.observe(frame(changing: [9: 20]), at: 1), .idle)
        XCTAssertEqual(detector.observe(frame(), at: 1.1), .idle)
        XCTAssertEqual(detector.tick(at: 5), .idle)
    }

    /// Moving pictures that keep coming back to the same text are read less and less
    /// often, down to a floor, until the text changes again.
    func testUnchangedTextOverMovingPicturesIsReadLessOften() {
        var detector = ChangeDetector(settle: 0.25, patience: 1, slowest: 2)
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0, textChanged: true)
        var time = 0.0, step = 0
        /// Video frames until the next reading: never still, never what was read.
        func untilRead() -> Double {
            let start = time
            for _ in 0..<200 {
                time += 0.05
                step += 1
                if detector.observe(frame(changing: [11: UInt8(step % 4 * 30)]), at: time) == .read { break }
            }
            return time - start
        }
        var waits: [Double] = []
        for _ in 0..<6 {
            waits.append(untilRead())
            detector.didRead(frame(), at: time, textChanged: false)
        }
        XCTAssertEqual(waits.first ?? 0, 1.0, accuracy: 0.11)
        XCTAssertEqual(waits.last ?? 0, 2.0, accuracy: 0.11)
        for (earlier, later) in zip(waits, waits.dropFirst()) {
            XCTAssertGreaterThan(later, earlier - 0.06, "\(waits)") // never sooner, a frame's jitter aside
        }

        // The text changes: back to reading as often as at first.
        detector.didRead(frame(), at: time, textChanged: true)
        XCTAssertEqual(untilRead(), 1.0, accuracy: 0.11)
    }

    /// What changed while a frame was being read is still pending afterwards.
    func testChangeDuringAReadIsReadNext() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        _ = detector.observe(frame(), at: 0)
        _ = detector.observe(frame(changing: [2: 0]), at: 0.05) // arrives mid-read
        detector.didRead(frame(), at: 0.1, textChanged: true)
        XCTAssertEqual(detector.tick(at: 0.4), .read)
    }

    /// Text changing on a still screen: until it's read again, the detector says where
    /// the screen no longer shows what was read.
    func testChangeOnAStillPictureIsUnreadWhereItChanged() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0.1, textChanged: true)
        XCTAssertEqual(detector.unread.cells, [])
        let changed = frame(changing: [5: 40, 6: 40])
        _ = detector.observe(changed, at: 3)
        XCTAssertEqual(detector.unread.cells, [5, 6])
        detector.didRead(changed, at: 3.4, textChanged: true)
        XCTAssertEqual(detector.unread.cells, [])
    }

    /// Text changing again while the last change was being read is unread as soon as
    /// that reading is in.
    func testChangeDuringAReadingOfAStillPictureIsUnreadAfterIt() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        _ = detector.observe(frame(), at: 0)
        detector.didRead(frame(), at: 0.1, textChanged: true)
        let first = frame(changing: [5: 40])
        _ = detector.observe(first, at: 3)
        XCTAssertEqual(detector.tick(at: 3.3), .read)
        _ = detector.observe(frame(changing: [5: 40, 9: 90]), at: 3.4)
        detector.didRead(first, at: 3.5, textChanged: true)
        XCTAssertEqual(detector.unread.cells, [9])
    }

    /// Video behind subtitles changes every frame, text or not: nothing is called
    /// unread before it's read, or the translation would never stay up.
    func testMovingPictureLeavesNothingUnread() {
        var detector = ChangeDetector(settle: 0.25, patience: 1)
        var time = 0.0
        _ = detector.observe(frame(), at: time)
        detector.didRead(frame(), at: 0.05, textChanged: true)
        for step in 1...40 {
            time += 1.0 / 6
            let video = frame(changing: [7: UInt8(step % 3 * 40), 30: UInt8(step % 2 * 60)])
            if detector.observe(video, at: time) == .read {
                detector.didRead(video, at: time + 0.1, textChanged: false)
            }
            XCTAssertEqual(detector.unread.cells, [], "at \(time)")
        }
    }
}

final class RegionWatcherTests: XCTestCase {
    /// Lector is left out of the watched picture even when none of its windows is on
    /// screen as the watch starts — the panel over the region not drawn yet, the menu
    /// bar hidden over a full-screen video — or it reads its own translation back.
    @MainActor
    func testLectorIsLeftOutOfThePictureWithNothingOnScreen() async throws {
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        defer { window.close() }
        let own: [Int32]
        do {
            own = try await RegionWatcher.capturable(display: CGMainDisplayID()).own.map(\.processID)
        } catch {
            throw XCTSkip("Screen Recording isn't granted to the test runner: \(error)")
        }
        XCTAssertEqual(own, [ProcessInfo.processInfo.processIdentifier])
    }
}

final class LiveDiffTests: XCTestCase {
    private let shown = [
        LiveDiff.Shown(text: "We can't stay in Port Avalon much longer.", rect: CGRect(x: 0, y: 0, width: 400, height: 30),
                       translation: "אנחנו לא יכולים להישאר בפורט אוולן הרבה יותר זמן."),
        LiveDiff.Shown(text: "Yes", rect: CGRect(x: 0, y: 40, width: 40, height: 30), translation: "כן"),
    ]

    /// The same text is shown again wherever it moved to: a scroll isn't new text.
    func testSameTextIsReusedWhereverItIs() {
        let reused = LiveDiff.reuse([("We can't stay in  Port Avalon much longer.", CGRect(x: 0, y: 300, width: 400, height: 30))],
                                    from: shown)
        XCTAssertEqual(reused, ["אנחנו לא יכולים להישאר בפורט אוולן הרבה יותר זמן."])
    }

    /// The reader misreading a letter of a subtitle that didn't change, over moving
    /// video, isn't a new line to translate.
    func testNearlyTheSameTextInTheSamePlaceIsReused() {
        let reused = LiveDiff.reuse([("We can't stay in Port Ava1on much longer.", CGRect(x: 2, y: 1, width: 400, height: 30))],
                                    from: shown)
        XCTAssertEqual(reused, ["אנחנו לא יכולים להישאר בפורט אוולן הרבה יותר זמן."])
    }

    func testNearlyTheSameTextElsewhereIsTranslated() {
        let reused = LiveDiff.reuse([("We can't stay in Port Ava1on much longer.", CGRect(x: 0, y: 200, width: 400, height: 30))],
                                    from: shown)
        XCTAssertEqual(reused, [nil])
    }

    /// Short lines differ by a letter for real: "Yes" and "Yet" are different lines.
    func testShortTextIsOnlyReusedWhenIdentical() {
        let reused = LiveDiff.reuse([("Yet", CGRect(x: 0, y: 40, width: 40, height: 30))], from: shown)
        XCTAssertEqual(reused, [nil])
    }

    func testNewTextIsTranslated() {
        let reused = LiveDiff.reuse([("Meet me at the old lighthouse.", CGRect(x: 0, y: 0, width: 400, height: 30))],
                                    from: shown)
        XCTAssertEqual(reused, [nil])
    }

    /// Read again over moving video, a speaker's name gains a stray mark and a subtitle
    /// one wrong kana: the same lines, not new ones to translate. Measured on a Final
    /// Fantasy VII cutscene, read every second or two.
    func testShortLineMisreadByALetterInTheSamePlaceIsReused() {
        let shown = [
            LiveDiff.Shown(text: "アナウンス", rect: CGRect(x: 120, y: 10, width: 160, height: 30), translation: "הודעה"),
            LiveDiff.Shown(text: "こちらは神羅カンパニー危機対策本部です", rect: CGRect(x: 140, y: 50, width: 600, height: 30),
                           translation: "כאן מטה החירום של חברת שינרה"),
        ]
        let reused = LiveDiff.reuse([("アナウンスり", CGRect(x: 120, y: 11, width: 170, height: 30)),
                                     ("さちらは神羅カンパニー危機対策本部です", CGRect(x: 141, y: 50, width: 600, height: 30))],
                                    from: shown)
        XCTAssertEqual(reused, ["הודעה", "כאן מטה החירום של חברת שינרה"])
    }

    /// Ellipses and middle dots come back as a different run of dots each time.
    func testPunctuationReadDifferentlyIsTheSameLine() {
        let shown = [LiveDiff.Shown(text: "どうぞ……。", rect: CGRect(x: 0, y: 0, width: 200, height: 30), translation: "בבקשה...")]
        XCTAssertEqual(LiveDiff.reuse([("どうぞ・・・・。", CGRect(x: 0, y: 0, width: 210, height: 30))], from: shown),
                       ["בבקשה..."])
    }

    /// The next subtitle in the same spot, alike only in how it starts, is new.
    func testDifferentShortLineInTheSamePlaceIsTranslated() {
        let shown = [LiveDiff.Shown(text: "Sale el lunes", rect: CGRect(x: 0, y: 0, width: 200, height: 30), translation: "יוצא ביום שני")]
        XCTAssertEqual(LiveDiff.reuse([("Sale el martes", CGRect(x: 0, y: 0, width: 210, height: 30))], from: shown), [nil])
    }

    /// Over moving video the reader can misread a long line by several letters at
    /// once. It's translated again, but what was up stays up until the new one lands,
    /// rather than the original flashing back for the half second that takes.
    func testBadlyMisreadLineKeepsItsTranslationUntilTheNewOneLands() {
        let shown = [LiveDiff.Shown(text: "現在も断続前な爆発があり火災が発生しています", rect: CGRect(x: 40, y: 40, width: 700, height: 30),
                                    translation: "עדיין יש פיצוצים לסירוגין ושריפות")]
        let lines = [("現在も4断続的な募発があり火災が発生しています", CGRect(x: 40, y: 41, width: 700, height: 30))]
        XCTAssertEqual(LiveDiff.reuse(lines, from: shown), [nil])
        XCTAssertEqual(LiveDiff.standIns(lines, from: shown), ["עדיין יש פיצוצים לסירוגין ושריפות"])
    }

    /// The next subtitle in the same place is another line: nothing stands in for it.
    func testNewLineInTheSamePlaceHasNoStandIn() {
        let shown = [LiveDiff.Shown(text: "壱番魔晄炉が何者かの攻撃を受け爆破されました", rect: CGRect(x: 40, y: 40, width: 700, height: 30),
                                    translation: "כור המאקו הראשון הותקף ופוצץ")]
        XCTAssertEqual(LiveDiff.standIns([("現在も断続的な爆発があり火災が発生しています", CGRect(x: 40, y: 40, width: 700, height: 30))],
                                         from: shown), [nil])
    }

    /// A dialogue box read again over its animated background: the same three lines,
    /// one misread by a kana, one with its dots read differently. Nothing on it is new,
    /// however the reader would group the lines this time.
    func testSameLinesReadAgainAreTheSameReading() {
        let before = [("時の番人", CGRect(x: 20, y: 0, width: 120, height: 30)),
                      ("「さあわたしのしりうることはここまで。", CGRect(x: 20, y: 40, width: 700, height: 30)),
                      ("過去へとたびだつじゅんびができたら時のオーブのまえへどうぞ……。", CGRect(x: 30, y: 80, width: 900, height: 30))]
        let after = [("時の番人", CGRect(x: 20, y: 1, width: 120, height: 30)),
                     ("「さあわたしのしりうることはここまで。", CGRect(x: 21, y: 40, width: 700, height: 30)),
                     ("過去へとたびだつじゅんびができたら時のオーブのまえへどうぞ・・・。", CGRect(x: 30, y: 80, width: 905, height: 30))]
        XCTAssertTrue(LiveDiff.sameReading(after, as: before))
    }

    func testANewLineMakesANewReading() {
        let before = [("アナウンス", CGRect(x: 20, y: 0, width: 120, height: 30)),
                      ("壱番魔晄炉が何者かの攻撃を受け爆破されました", CGRect(x: 40, y: 40, width: 700, height: 30))]
        let changed = [("アナウンス", CGRect(x: 20, y: 0, width: 120, height: 30)),
                       ("現在も断続的な爆発があり火災が発生しています", CGRect(x: 40, y: 40, width: 700, height: 30))]
        XCTAssertFalse(LiveDiff.sameReading(changed, as: before))
        XCTAssertFalse(LiveDiff.sameReading(Array(before.prefix(1)), as: before), "a line went")
        XCTAssertFalse(LiveDiff.sameReading(before, as: Array(before.prefix(1))), "a line came")
    }

    /// A frame 960 by 80 pixels: 48 by 4 cells of 20. A line of translation sits over
    /// the second and third rows.
    private let line = CGRect(x: 40, y: 22, width: 260, height: 30)
    private let size = CGSize(width: 960, height: 80)

    /// The next subtitle is longer: it runs on past the old one's end. The old
    /// translation comes off at once, though the spot it covers looks the same.
    func testTranslationComesOffALineThatChangedBesideIt() {
        var runOn: [Int: UInt8] = [:]
        for column in 15..<30 {
            runOn[48 + column] = 120
            runOn[96 + column] = 120
        }
        let unread = frame(changing: runOn).changes(from: frame())
        XCTAssertEqual(LiveDiff.paintable(["אני רוצה קפה, תודה."], over: [line], unread: unread, in: size), [nil])
    }

    func testTranslationStaysWhenTheChangeIsElsewhere() {
        let unread = frame(changing: [150: 30, 151: 30]).changes(from: frame())
        XCTAssertEqual(LiveDiff.paintable(["אני רוצה קפה, תודה."], over: [line], unread: unread, in: size),
                       ["אני רוצה קפה, תודה."])
    }

    /// A subtitle drawn around loosely takes in the bottom of the video above it. Its
    /// translation is set a little taller than the line it covers and reaches into the
    /// grid's top row, where the video moves: that isn't the subtitle changing. Measured:
    /// a 1982 by 196 region, 48 by 5 cells, translation painted from y 27 to 127.
    func testTranslationStaysWhenOnlyARowItBarelyReachesChanges() {
        let videoEdge = FrameArea(columns: 48, rows: 5, cells: Set(0..<48))
        let painted = CGRect(x: 600, y: 27, width: 800, height: 100)
        XCTAssertEqual(LiveDiff.paintable(["למה לא?"], over: [painted], unread: videoEdge,
                                          in: CGSize(width: 1982, height: 196)), ["למה לא?"])
    }
}

final class LiveReadingTests: XCTestCase {
    /// One word per line, in the order given.
    private func reading(_ lines: [(String, CGRect)]) -> RecognizedText {
        RecognizedText(words: lines.enumerated().map { RecognizedWord(text: $1.0, rect: $1.1, lineIndex: $0) },
                       lines: lines.enumerated().map { RecognizedLine(text: $1.0, rect: $1.1, wordRange: $0..<($0 + 1)) })
    }

    /// Dragon Quest sets its dialogue in phrases a space apart, with the readings of
    /// kanji in small kana above them. The reader returns each phrase as a line of its
    /// own, in no reliable order, and the readings as lines too: translated like that,
    /// "さあ わたしの しりうることは ここまで。" came out as four unrelated words.
    func testSpacedPhrasesOfARowAreOneLineAndKanjiReadingsAreDropped() {
        let text = reading([
            ("時の番人", CGRect(x: 40, y: 0, width: 150, height: 34)),
            ("「さあ", CGRect(x: 30, y: 50, width: 80, height: 40)),
            ("過去へと", CGRect(x: 50, y: 112, width: 140, height: 40)),
            ("わたしの", CGRect(x: 150, y: 50, width: 140, height: 40)),
            ("しりうることは", CGRect(x: 330, y: 51, width: 230, height: 40)),
            ("ここまで。", CGRect(x: 600, y: 50, width: 160, height: 40)),
            ("かこ", CGRect(x: 62, y: 95, width: 40, height: 16)),
            ("たびだつ", CGRect(x: 230, y: 112, width: 140, height: 40)),
        ])
        XCTAssertEqual(LiveReading.cleaned(text).lines.map(\.text),
                       ["時の番人", "「さあわたしのしりうることはここまで。", "過去へとたびだつ"])
    }

    /// Words of a script with spaces side by side are separate labels: a menu bar.
    func testLabelsSideBySideStayApart() {
        let text = reading([("File", CGRect(x: 0, y: 0, width: 40, height: 20)),
                            ("Edit", CGRect(x: 70, y: 0, width: 40, height: 20)),
                            ("設定", CGRect(x: 0, y: 40, width: 60, height: 30)),
                            ("削除", CGRect(x: 200, y: 40, width: 60, height: 30))])
        XCTAssertEqual(LiveReading.cleaned(text).lines.map(\.text), ["File", "Edit", "設定", "削除"])
    }

    /// A video player's clock under the subtitles: nothing to translate, and as it
    /// ticks every reading would look new.
    func testLinesWithoutLettersAreDropped() {
        let text = reading([("01:04", CGRect(x: 0, y: 0, width: 60, height: 20)),
                            ("Sale el lunes", CGRect(x: 100, y: 40, width: 200, height: 30)),
                            ("02:00", CGRect(x: 400, y: 0, width: 60, height: 20))])
        let cleaned = LiveReading.cleaned(text)
        XCTAssertEqual(cleaned.lines.map(\.text), ["Sale el lunes"])
        XCTAssertEqual(cleaned.words.map(\.lineIndex), [0])
    }
}
