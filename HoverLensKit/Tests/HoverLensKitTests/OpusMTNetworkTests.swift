import Synchronization
import XCTest
@testable import HoverLensKit

/// Downloads real models from Hugging Face and translates with them. Several hundred
/// megabytes on first run, so opt-in:
///
///     HOVERLENS_NETWORK_TESTS=1 swift test --package-path HoverLensKit --filter OpusMTNetworkTests
///
/// Models are kept in the temporary directory between runs; delete
/// `$TMPDIR/HoverLensOpusMTModels` to exercise the download again.
final class OpusMTNetworkTests: XCTestCase {
    private var translator: OpusMTTranslator!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["HOVERLENS_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set HOVERLENS_NETWORK_TESTS=1 to download models and translate with them")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "HoverLensOpusMTModels")
        translator = OpusMTTranslator(modelsDirectory: directory)
    }

    private func translate(_ text: String, _ source: String, _ target: String) async throws -> [String] {
        let source = Locale.Language(identifier: source), target = Locale.Language(identifier: target)
        let fractions = Fractions()
        try await translator.download(from: source, to: target) { fractions.append($0) }
        XCTAssertEqual(fractions.values, fractions.values.sorted(), "progress never goes backwards")
        XCTAssertEqual(fractions.values.last, 1)
        let availability = await translator.availability(from: source, to: target)
        XCTAssertEqual(availability, .ready)

        let start = Date()
        let translation = try await translator.translate(text, from: source, to: target)
        print("\(source.minimalIdentifier) → \(target.minimalIdentifier) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s:\n\(translation)")
        let lines = translation.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, text.components(separatedBy: "\n").count, "one line out per line in")
        return lines
    }

    func testHebrewToEnglish() async throws {
        let lines = try await translate("שלום עולם\nמה שלומך היום?", "he", "en")
        XCTAssertTrue(lines[0].localizedCaseInsensitiveContains("world"), lines[0])
        XCTAssertTrue(lines[1].localizedCaseInsensitiveContains("how are you"), lines[1])
    }

    func testArabicToEnglish() async throws {
        let lines = try await translate("كيف حالك اليوم؟\nأعلنت الحكومة عن خطة جديدة لتحسين التعليم.", "ar", "en")
        XCTAssertTrue(lines[0].localizedCaseInsensitiveContains("how are you"), lines[0])
        XCTAssertTrue(lines[1].localizedCaseInsensitiveContains("government"), lines[1])
    }

    func testEnglishToGreek() async throws {
        let lines = try await translate("Good morning, my friend.", "en", "el")
        XCTAssertTrue(lines[0].unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) }, "\(lines[0]) is not Greek")
    }

    func testEnglishToHindi() async throws {
        let lines = try await translate("Good morning, my friend.", "en", "hi")
        XCTAssertTrue(lines[0].unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }, "\(lines[0]) is not Devanagari")
    }

    /// Hebrew and Thai share no model; the route goes through English.
    func testHebrewToThaiThroughEnglish() async throws {
        let route = try XCTUnwrap(OpusMTCatalog.shared.route(from: Locale.Language(identifier: "he"),
                                                              to: Locale.Language(identifier: "th")))
        XCTAssertTrue(route.isPivot)

        let lines = try await translate("שלום עולם\nמה שלומך היום?", "he", "th")
        for line in lines {
            XCTAssertTrue(line.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }, "\(line) is not Thai")
        }
    }
}

private final class Fractions: Sendable {
    private let stored = Mutex<[Double]>([])

    func append(_ value: Double) { stored.withLock { $0.append(value) } }
    var values: [Double] { stored.withLock { $0 } }
}
