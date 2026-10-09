import LectorKit
import Translation
import XCTest
@testable import Lector

/// Which engines a language goes to, and so when an offline pack is downloaded: unasked
/// only where nothing else can translate the pair.
@MainActor
final class TranslationJobTests: XCTestCase {
    private func engines(_ apple: LanguageAvailability.Status, _ offline: TranslatorAvailability,
                         prefetching: Bool = false) -> TranslationJob.Engines {
        TranslationJob.engines(apple: apple, offline: offline, prefetchesPacks: prefetching)
    }

    /// The download that fetched 246 MB packs for pairs Apple already translated.
    func testPairAppleTranslatesFetchesNoPackUnasked() {
        XCTAssertEqual(engines(.installed, .needsDownload(bytes: 246_000_000)),
                       .apple(prepare: false, prefetchPack: false))
        XCTAssertEqual(engines(.supported, .needsDownload(bytes: 246_000_000)),
                       .apple(prepare: true, prefetchPack: false),
                       "Apple fetches its own model, asking first")
    }

    func testDraftPacksAreFetchedWhenTheUserAskedForThem() {
        XCTAssertEqual(engines(.installed, .needsDownload(bytes: 1), prefetching: true),
                       .apple(prepare: false, prefetchPack: true))
        XCTAssertEqual(engines(.supported, .needsDownload(bytes: 1), prefetching: true),
                       .apple(prepare: true, prefetchPack: true))
    }

    func testPairOnlyAPackTranslatesIsDownloaded() {
        XCTAssertEqual(engines(.unsupported, .needsDownload(bytes: 1)), .downloadThenOffline)
        XCTAssertEqual(engines(.unsupported, .needsDownload(bytes: 1), prefetching: true), .downloadThenOffline)
    }

    /// A pack already on the Mac is used as it is; there is nothing to fetch.
    func testInstalledPackIsNeverFetchedAgain() {
        XCTAssertEqual(engines(.installed, .ready, prefetching: true), .apple(prepare: false, prefetchPack: false))
        XCTAssertEqual(engines(.supported, .ready), .offline)
        XCTAssertEqual(engines(.unsupported, .ready), .offline)
    }

    func testPairNeitherCanTranslateIsUnsupported() {
        XCTAssertEqual(engines(.unsupported, .unsupported), .unsupported)
        XCTAssertEqual(engines(.supported, .unsupported), .apple(prepare: true, prefetchPack: false))
    }

    // MARK: - What the overlay says about the capture

    private var directory: URL!

    private func makeJob() throws -> TranslationJob {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TranslationJobTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        self.directory = directory
        return TranslationJob(target: "en", offline: OpusMTTranslator(modelsDirectory: directory),
                              appleSessions: AppleSessionCache(), memory: TranslationMemory())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A page in several languages is told by all of them, the one with most text first,
    /// not by whichever language the largest paragraph is in.
    func testSourceLanguagesListsEveryLanguageMostTextFirst() async throws {
        let job = try makeJob()
        defer { job.cancel() }

        job.start(paragraphs: [
            "Enregistrer les modifications",
            "Die Sendungsverfolgung finden Sie in Ihrem Kundenkonto unter dem Menüpunkt Bestellungen.",
            "Wir versenden alle Bestellungen innerhalb von zwei Werktagen.",
        ])
        try await waitUntil { !job.sourceLanguages.isEmpty }

        XCTAssertEqual(job.sourceLanguages.map(\.languageCode), ["de", "fr"])

        job.restart(choosing: nil)
        XCTAssertEqual(job.sourceLanguages, [], "cleared until the new plan is made")
    }

    /// Persian has no translator but the many-language pack, whose Persian is barely
    /// usable; the job says so, and a new capture starts with nothing said.
    func testLanguageOnlyAManyLanguagePackTranslatesIsRough() async throws {
        let job = try makeJob()
        defer { job.cancel() }
        // Marked installed, so nothing is downloaded; the empty pack then fails to load,
        // which doesn't matter here.
        let pack = directory.appending(path: "opus-mt-mul-en")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pack.appending(path: "manifest.json"))

        job.start(paragraphs: ["لطفاً به من کمک کنید. من می‌خواهم یک بلیت قطار بخرم."])
        try await waitUntil { !job.roughSources.isEmpty }
        XCTAssertEqual(job.roughSources.map(\.languageCode), ["fa"])

        job.start(paragraphs: ["12:30"])
        XCTAssertEqual(job.roughSources, [])
    }

    /// Live translation hands in what's already painted over lines it reads again. It
    /// stays up through the new reading's start, rather than coming off until the plan
    /// is made and going back up: that's a blink over text that never changed.
    func testKnownTranslationsAreThereFromTheStart() throws {
        let job = try makeJob()
        defer { job.cancel() }

        job.start(paragraphs: ["Pues... tu tienes muchos amigos", "Y tu no tienes suficientes"],
                  known: [0: "Well... you have lots of friends"])
        XCTAssertEqual(job.translations, ["Well... you have lots of friends", nil])
    }
}
