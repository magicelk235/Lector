import XCTest
@testable import HoverLensKit

/// Which models a language pair is translated through, and what `availability` says about
/// it, all without a network.
final class OpusMTRoutingTests: XCTestCase {
    private func model(
        _ name: String, _ kind: OpusMTModel.Kind = .specific, sources: String, targets: String, bytes: Int64 = 100
    ) -> OpusMTModel {
        OpusMTModel(
            name: name, repository: "test/\(name)", revision: String(repeating: "0", count: 40), kind: kind,
            files: [.init("onnx/encoder_model_quantized.onnx", "encoder.onnx", bytes, "")],
            sources: sources, targets: targets, sourceGroup: nil, targetGroup: nil
        )
    }

    private lazy var catalog = OpusMTCatalog(models: [
        model("opus-mt-he-en", sources: "he", targets: "en", bytes: 110),
        model("opus-mt-en-de", sources: "en", targets: "de", bytes: 120),
        model("opus-mt-ar-de", sources: "ar", targets: "de", bytes: 130),
        model("opus-mt-ar-en", sources: "ar", targets: "en", bytes: 140),
        model("opus-mt-ko-en", sources: "ko", targets: "en", bytes: 145),
        model("opus-mt-nl-en", sources: "nl", targets: "en", bytes: 125),
        model("opus-mt-gmw-gmw", .group, sources: "de en nl", targets: "de=>>deu<< en=>>eng<< nl=>>nld<<", bytes: 150),
        model("opus-mt-mul-en", .multilingual, sources: "fa he sw th zh-Hans zh-Hant", targets: "en", bytes: 160),
        model("opus-mt-en-mul", .multilingual, sources: "en", targets: "fa=>>pes<< he=>>heb<< sw=>>swh<< zh-Hant=>>cmn_Hant<<", bytes: 170),
    ])

    private func route(_ source: String, _ target: String) -> [String]? {
        catalog.route(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))?
            .models.map(\.name)
    }

    func testDirectModelIsPreferredToPivotingThroughEnglish() {
        XCTAssertEqual(route("ar", "de"), ["opus-mt-ar-de"])
    }

    func testPairWithoutDirectModelPivotsThroughEnglish() {
        XCTAssertEqual(route("he", "de"), ["opus-mt-he-en", "opus-mt-en-de"])
    }

    func testSpecificModelIsPreferredToMultilingualOne() {
        XCTAssertEqual(route("he", "en"), ["opus-mt-he-en"])
    }

    /// One pass through a family model loses less than two passes through English, even
    /// when both of those would be specific models.
    func testFamilyModelIsPreferredToPivot() {
        XCTAssertEqual(route("nl", "de"), ["opus-mt-gmw-gmw"])
    }

    func testMultilingualModelsCoverWhatNothingElseDoes() {
        XCTAssertEqual(route("sw", "fa"), ["opus-mt-mul-en", "opus-mt-en-mul"])
    }

    func testMultiTargetModelIsSteeredWithItsLanguageToken() throws {
        let legs = try XCTUnwrap(catalog.route(from: Locale.Language(identifier: "de"),
                                               to: Locale.Language(identifier: "he"))).legs
        XCTAssertEqual(legs.map(\.model.name), ["opus-mt-gmw-gmw", "opus-mt-en-mul"])
        XCTAssertEqual(legs.map(\.languageToken), [">>eng<<", ">>heb<<"])
    }

    func testSingleTargetModelTakesNoToken() throws {
        let legs = try XCTUnwrap(catalog.route(from: Locale.Language(identifier: "he"),
                                               to: Locale.Language(identifier: "en"))).legs
        XCTAssertEqual(legs.map(\.languageToken), [nil])
    }

    func testPairNoModelCoversIsUnsupported() {
        XCTAssertNil(route("ja", "en"))
        XCTAssertNil(route("de", "th"), "Thai is only ever a source")
        XCTAssertNil(route("he", "he"))
    }

    func testLegacyAndRegionalCodesFindTheirLanguage() {
        XCTAssertEqual(route("iw", "en"), ["opus-mt-he-en"], "iw is the old code for Hebrew")
        XCTAssertEqual(route("en", "zh-TW"), ["opus-mt-en-mul"], "Taiwan writes Traditional Chinese")
        XCTAssertNil(route("en", "zh-CN"), "Simplified is a different target from Traditional")
    }

    /// Korean written only in Hangul is ordinary Korean, though its script tag differs
    /// from Korean's default (Hangul with Hanja).
    func testScriptNoModelIsTaggedWithFallsBackToTheLanguage() {
        XCTAssertEqual(route("ko-Hang", "en"), ["opus-mt-ko-en"])
    }

    // MARK: - Availability

    private func translator() throws -> (OpusMTTranslator, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpusMTRoutingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (OpusMTTranslator(modelsDirectory: directory, catalog: catalog), directory)
    }

    private func install(_ name: String, in directory: URL) throws {
        let model = directory.appending(path: name)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appending(path: "manifest.json"))
    }

    func testAvailabilityCountsEveryModelStillToDownload() async throws {
        let (translator, _) = try translator()

        let availability = await translator.availability(from: Locale.Language(identifier: "he"),
                                                         to: Locale.Language(identifier: "de"))

        XCTAssertEqual(availability, .needsDownload(bytes: 110 + 120))
    }

    func testAvailabilityCountsOnlyTheMissingHalfOfAPivot() async throws {
        let (translator, directory) = try translator()
        try install("opus-mt-he-en", in: directory)

        let availability = await translator.availability(from: Locale.Language(identifier: "he"),
                                                         to: Locale.Language(identifier: "de"))

        XCTAssertEqual(availability, .needsDownload(bytes: 120))
    }

    func testPairIsReadyOnceEveryModelIsInstalled() async throws {
        let (translator, directory) = try translator()
        try install("opus-mt-he-en", in: directory)
        try install("opus-mt-en-de", in: directory)

        let availability = await translator.availability(from: Locale.Language(identifier: "he"),
                                                         to: Locale.Language(identifier: "de"))

        XCTAssertEqual(availability, .ready)
        XCTAssertEqual(translator.installedPairs().count, 2)
    }

    /// A download that stopped part-way leaves files but no manifest; that is not a model.
    func testModelWithoutManifestIsNotInstalled() async throws {
        let (translator, directory) = try translator()
        let partial = directory.appending(path: "opus-mt-he-en")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: partial.appending(path: "encoder.onnx"))

        let availability = await translator.availability(from: Locale.Language(identifier: "he"),
                                                         to: Locale.Language(identifier: "en"))

        XCTAssertEqual(availability, .needsDownload(bytes: 110))
    }

    func testUnsupportedPairIsReportedAsSuch() async throws {
        let (translator, _) = try translator()

        let availability = await translator.availability(from: Locale.Language(identifier: "ja"),
                                                         to: Locale.Language(identifier: "en"))

        XCTAssertEqual(availability, .unsupported)
    }

    func testTranslatingBeforeDownloadingSaysSo() async throws {
        let (translator, _) = try translator()

        do {
            _ = try await translator.translate("שלום", from: Locale.Language(identifier: "he"),
                                               to: Locale.Language(identifier: "en"))
            XCTFail("translated without a model")
        } catch {
            XCTAssertEqual(error as? OpusMTError, .modelsNotDownloaded)
        }
    }

    func testRemovingModelsLeavesNothingInstalled() async throws {
        let (translator, directory) = try translator()
        try install("opus-mt-he-en", in: directory)

        try translator.removeAllModels()

        XCTAssertEqual(translator.installedPairs(), [])
        let availability = await translator.availability(from: Locale.Language(identifier: "he"),
                                                         to: Locale.Language(identifier: "en"))
        XCTAssertEqual(availability, .needsDownload(bytes: 110))
    }
}
