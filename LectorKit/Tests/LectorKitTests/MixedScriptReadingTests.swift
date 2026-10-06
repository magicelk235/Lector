import AppKit
import ImageIO
import XCTest
@testable import LectorKit

/// Reads captures that mix scripts, and short labels Vision overlooks in a large
/// capture: text drawn in-test the way a Retina screen shows it (15pt at 2x), and a
/// Safari screenshot.
final class MixedScriptReadingTests: XCTestCase {
    private func fixture(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// `lines` one per paragraph, black on white, in the system font with its
    /// fallbacks for other scripts.
    private func render(_ lines: [String], pointSize: CGFloat = 15) throws -> CGImage {
        let scale: CGFloat = 2, width: CGFloat = 520, margin: CGFloat = 16
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = .natural
            style.paragraphSpacing = pointSize * 0.6
            text.append(NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""), attributes: [
                .font: NSFont.systemFont(ofSize: pointSize), .foregroundColor: NSColor.black, .paragraphStyle: style,
            ]))
        }
        let height = ceil(text.boundingRect(with: CGSize(width: width, height: 10_000),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int((width + margin * 2) * scale), height: Int((height + margin * 2) * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(with: CGRect(x: margin, y: margin, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(context.makeImage())
    }

    private func read(_ lines: [String], pointSize: CGFloat = 15) async throws -> RecognizedText {
        try await ScreenTextReader().read(render(lines, pointSize: pointSize))
    }

    // MARK: - Several scripts in one capture

    /// A model that won one line must not read the others: the Greek model reads
    /// French as Greek look-alikes.
    func testLatinLinesBesideAGreekLineStayLatin() async throws {
        let text = try await read(["Votre abonnement sera renouvelé automatiquement le 3 mars.",
                                   "Καλημέρα! Πού είναι ο σταθμός του μετρό;",
                                   "Enregistrer"])
        XCTAssertEqual(text.lines.map { Set(Script.histogram(of: $0.text).keys) }, [[.latin], [.greek], [.latin]], text.text)
        XCTAssertTrue(text.lines[0].text.hasPrefix("Votre abonnement"), text.text)
        XCTAssertEqual(text.lines[2].text, "Enregistrer")
    }

    func testEachScriptOnAMixedPageIsReadInItsOwnScript() async throws {
        let text = try await read(["Welcome back! Your account is ready.",
                                   "שלום! זה טקסט שכבר כתוב בעברית.",
                                   "Καλημέρα! Πού είναι ο σταθμός του μετρό;",
                                   "مرحباً بكم في تطبيقنا.",
                                   "Save changes"])
        XCTAssertEqual(text.lines.map { Script.dominant(in: $0.text) }, [.latin, .hebrew, .greek, .arabic, .latin], text.text)
        XCTAssertTrue(text.lines[1].text.contains("שכבר כתוב בעברית"), text.text)
        XCTAssertTrue(text.lines[2].text.contains("Καλημέρα"), text.text)
        XCTAssertTrue(text.lines[3].text.contains("تطبيقنا"), text.text)
    }

    /// A Safari page: a French card with two blue buttons beside a Greek box and a
    /// Hebrew one. Every line is read in its own script, and the buttons' rounded
    /// edges, which the Greek model read as "ε", are not read as letters.
    func testScreenshotOfBoxesInThreeScriptsReadsEachLineAndNothingElse() async throws {
        let text = try await ScreenTextReader().read(fixture("safari-mixed-boxes"))
        let lines = text.lines.map(\.text)
        XCTAssertEqual(lines.count, 9, text.text)
        XCTAssertTrue(lines.allSatisfy { Script.histogram(of: $0).values.reduce(0, +) >= 2 }, text.text)
        for line in ["Paramètres du compte", "Enregistrer", "Annuler"] {
            XCTAssertTrue(lines.contains(line), "\(line) in \(text.text)")
        }
        XCTAssertEqual(lines.filter { Script.dominant(in: $0) == .greek }.count, 2, text.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Καλημέρα! Πού") }, text.text)
        XCTAssertTrue(lines.contains { $0.contains("שכבר כתוב בעברית") }, text.text)
    }

    /// One letter alone is never enough to call a script: the Greek model read the
    /// rounded left edge of the "Enregistrer" button as "ε" with full confidence.
    func testOneLetterAloneIsNotTakenForAScript() async throws {
        let image = try fixture("safari-mixed-boxes")
        let contest = ScriptContest(image: image, scale: 1, candidates: [.greek, .hebrew, .armenian],
                                    tesseract: TesseractRecognizer())
        let edge = CGRect(x: 56, y: 284, width: 12, height: 52)
        let verdicts = try contest.identify([ScriptContest.Area(rect: edge, scripts: nil, visionText: "")])
        guard case .vision = try XCTUnwrap(verdicts.first) else {
            return XCTFail("the edge of a button was taken for a letter")
        }
    }

    /// Vision reads scripts it has no model for as confident Latin nonsense ("DIYU"
    /// for Hebrew on macOS 15). Once the page shows that script elsewhere, the line
    /// must be read again in it.
    func testConfidentLatinNonsenseForAnotherScriptIsReplaced() async throws {
        let image = try render(["שלום! זה טקסט שכבר כתוב בעברית.", "אנחנו שמחים לבשר לכם שההזמנה נשלחה."])
        let pixels = try XCTUnwrap(GrayImage(image))
        let first = try XCTUnwrap(InkLines.find(in: pixels, textHeight: 30).first).rect
        let nonsense = VisionReading(
            lines: [OCRLine(words: [OCRWord(text: "DIYU", rect: first, separator: "")], rect: first, confidence: 1)],
            textRegions: [])
        let lines = try RecognitionBackend.read(image, vision: nonsense, pixels: pixels, tesseract: TesseractRecognizer())
        let text = ReadingOrder.assemble(lines).text
        XCTAssertFalse(text.contains("DIYU"), text)
        XCTAssertTrue(text.contains("שכבר כתוב בעברית"), text)
        XCTAssertTrue(text.contains("שמחים לבשר"), text)
    }

    // MARK: - Text Vision overlooks

    /// Every label read, and read as the script it is in: of these Vision found one in
    /// the whole capture.
    private func assertEveryLabelRead(_ labels: [String], as script: Script,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let text = try await read(labels)
        XCTAssertEqual(text.lines.count, labels.count, text.text, file: file, line: line)
        XCTAssertTrue(text.lines.allSatisfy { Set(Script.histogram(of: $0.text).keys) == [script] }, text.text,
                      file: file, line: line)
    }

    func testShortKanjiLabelsAreAllRead() async throws {
        try await assertEveryLabelRead(["設定", "保存", "削除", "検索", "終了"], as: .han)
    }

    func testShortKoreanLabelsAreAllRead() async throws {
        try await assertEveryLabelRead(["파일", "편집", "보기", "설정", "저장"], as: .hangul)
    }

    /// Never handed to a script model: the Bengali model read "文件" as "সদ".
    func testShortChineseLabelsAreAllRead() async throws {
        try await assertEveryLabelRead(["文件", "编辑", "视图", "窗口", "帮助"], as: .han)
    }

    func testShortArabicLabelsAreAllRead() async throws {
        try await assertEveryLabelRead(["ملف", "تحرير", "عرض", "نافذة", "مساعدة"], as: .arabic)
    }

    func testKanjiHeadingAboveAJapaneseParagraphIsRead() async throws {
        let text = try await read(["設定", "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。"], pointSize: 18)
        XCTAssertEqual(text.lines.first?.text, "設定", text.text)
        XCTAssertTrue(text.lines.dropFirst().first?.text.hasPrefix("吾輩は猫である") == true, text.text)
    }

    /// Vision drops the full-width spaces, but they set the items apart.
    func testLabelsSetApartByFullWidthSpacesAreSeparateLines() async throws {
        let text = try await read(["設定\u{3000}保存\u{3000}削除\u{3000}検索"], pointSize: 18)
        XCTAssertEqual(text.lines.map(\.text), ["設定", "保存", "削除", "検索"])
    }

    /// The points may be read or dropped; the letters must be right.
    func testPointedHebrewIsRead() async throws {
        let text = try await read(["בְּרֵאשִׁית בָּרָא אֱלֹהִים אֵת הַשָּׁמַיִם וְאֵת הָאָרֶץ."])
        let letters = String(String.UnicodeScalarView(text.text.unicodeScalars.filter {
            (0x05D0...0x05EA).contains($0.value) || $0 == " "
        }))
        XCTAssertEqual(letters, "בראשית ברא אלהים את השמים ואת הארץ", text.text)
    }

    /// Vision reads Persian as Arabic, writing "ج" for "چ"; the Arabic script model
    /// reads it right.
    func testPersianIsReadWithPersianLetters() async throws {
        let text = try await read(["سلام، حال شما چطور است؟ من می‌خواهم یک بلیت قطار برای فردا صبح به تهران بخرم."])
        XCTAssertTrue(text.text.contains("چطور"), text.text)
        XCTAssertTrue(text.text.contains("یک"), text.text)
    }
}
