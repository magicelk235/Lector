import CoreGraphics
import Foundation
import Vision

/// Decides which engine reads what, and combines their results.
///
/// Vision reads first and alone decides Latin and CJK text, which it reads best. For
/// anything else the question is which script is on screen, and Vision cannot answer
/// it: pointed at a script it has no model for it does not return nothing, it returns
/// confident nonsense — Hebrew comes back as Latin letters ("DIYU"), Bengali as
/// Devanagari with full confidence, Khmer and Lao as Thai. So "Vision found
/// something" is no signal, and neither is Tesseract's orientation-and-script
/// detector, which knows 17 scripts and misidentified or gave up on half the test
/// screens (Georgian as Arabic, Gujarati as Cyrillic, most short crops "too few
/// characters").
///
/// What works is letting the script models compete: each reads a small sample, and
/// the model for the right script reads it with near-certain confidence in its own
/// letters (98–99.6% per character) while every wrong model scores 88–97%.
enum RecognitionBackend {
    /// Language codes Vision can read on this machine, such as "en" or "ja". The list
    /// grows with the OS — macOS 26 added Hindi — so it is asked for, not assumed.
    static let visionSupported: Set<String> = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let languages = (try? request.supportedRecognitionLanguages()) ?? []
        return Set(languages.compactMap { $0.split(separator: "-").first.map(String.init) })
    }()

    static func visionReads(_ script: Script) -> Bool {
        script.visionLanguages.contains(where: visionSupported.contains)
    }

    /// Scripts where even a confident Vision reading may be of a different script or
    /// language: Vision reads Bengali, Gujarati and Tibetan as Devanagari with full
    /// confidence, and flattens Persian and Urdu letters into Arabic ones.
    static let confusable: Set<Script> = [.devanagari, .arabic]

    // MARK: - When Vision is enough

    /// True when Vision's reading can be returned as it is: every line read with full
    /// confidence, in scripts Vision reads unambiguously, and no text left unread.
    static func visionSuffices(_ reading: VisionReading) -> Bool {
        guard !reading.lines.isEmpty, reading.lines.allSatisfy({ $0.confidence >= 1 }) else { return false }
        let scripts = Script.histogram(of: reading.lines.map(\.text).joined()).keys
        return scripts.allSatisfy { visionReads($0) && !confusable.contains($0) }
            && uncoveredRegions(reading).isEmpty
    }

    /// Text areas Vision detected but did not read — usually a script it cannot read
    /// sitting beside one it can.
    static func uncoveredRegions(_ reading: VisionReading) -> [CGRect] {
        reading.textRegions.filter { region in
            let covered = reading.lines.reduce(0) { $0 + region.intersection($1.rect).area }
            return covered < region.area * 0.5
        }
    }

    // MARK: - Which script

    /// Up to `limit` padded regions worth sampling to identify the script: text Vision
    /// left unread first, then lines it read with doubt or in a confusable script.
    /// Confidently read Latin and CJK lines are only sampled when there is nothing
    /// else, since they would only teach the contest that Latin is Latin.
    static func sampleRegions(_ reading: VisionReading, imageSize: CGSize, limit: Int = 4) -> [CGRect] {
        let doubtful = reading.lines.filter { line in
            line.confidence < 1 || Script.histogram(of: line.text).keys.contains {
                !visionReads($0) || confusable.contains($0)
            }
        }
        var pool = uncoveredRegions(reading) + doubtful.map(\.rect)
        if pool.isEmpty { pool = reading.lines.map(\.rect) }

        let bounds = CGRect(origin: .zero, size: imageSize)
        var chosen: [CGRect] = []
        for region in pool where !chosen.contains(where: { overlaps($0, region) }) {
            let padded = region.insetBy(dx: -region.height * 0.5, dy: -region.height * 0.35).intersection(bounds)
            // Long lines are cut: a few words identify a script as well as a page does.
            chosen.append(CGRect(x: padded.minX, y: padded.minY,
                                 width: min(padded.width, max(padded.height * 30, 600)), height: padded.height))
            if chosen.count == limit { break }
        }
        return chosen
    }

    /// Scripts to try, likeliest first: the user's own languages, then the scripts
    /// Vision tends to mistake the text it saw for, then everything else.
    static func candidates(visionText: String,
                           preferredLanguages: [String] = Locale.preferredLanguages,
                           available: (Script) -> Bool) -> [Script] {
        let preferred = preferredLanguages.compactMap { identifier -> Script? in
            let language = Locale.Language(identifier: identifier)
            let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
            return script.flatMap { Script(iso15924: $0.identifier) }
        }
        let hints: [Script] = switch Script.dominant(in: visionText) {
        case .devanagari: [.devanagari, .bengali, .gujarati, .gurmukhi, .tibetan, .oriya]
        case .thai: [.thai, .lao, .khmer, .myanmar, .kannada, .sinhala]
        case .arabic: [.arabic, .syriac, .thaana]
        case .cyrillic: [.cyrillic, .greek, .cherokee]
        case .latin: [.greek, .hebrew, .armenian, .georgian, .ethiopic, .cyrillic, .cherokee, .canadianAboriginal, .oriya]
        case nil: [.hebrew, .tamil, .telugu, .malayalam, .sinhala, .syriac, .thaana, .arabic]
        default: []
        }
        // Roughly by number of readers, for when nothing else points anywhere.
        let rest: [Script] = [.arabic, .cyrillic, .devanagari, .bengali, .hebrew, .greek, .tamil, .telugu,
                              .gujarati, .kannada, .malayalam, .gurmukhi, .thai, .myanmar, .khmer, .lao,
                              .sinhala, .oriya, .georgian, .armenian, .ethiopic, .tibetan, .thaana, .syriac,
                              .cherokee, .canadianAboriginal]
        var seen = Set<Script>()
        return (preferred + hints + rest).filter { available($0) && seen.insert($0).inserted }
    }

    /// How one script model read the sample.
    struct Reading {
        let script: Script
        let engine: TesseractEngine
        /// Share of recognised letters in the model's own script.
        let nativeShare: Float
        /// Mean confidence over those letters: 0.98+ when the script is right.
        let nativeConfidence: Float
        /// Share of recognised letters that are Latin. Every model reads Latin text as
        /// Latin, so this is how Latin text shows up.
        let latinShare: Float
        /// Mean word confidence, which includes the dictionary. It is what exposes
        /// Latin text read as Cyrillic or Greek look-alikes (0.54–0.67): letter by
        /// letter those look certain.
        let wordConfidence: Float
        let hasLetters: Bool

        /// The right script beyond reasonable doubt, so no other model need run.
        var isDecisive: Bool {
            nativeShare >= 0.5 && nativeConfidence >= 0.98 && wordConfidence >= 0.75
        }

        /// Plainly Latin text, which is Vision's to read.
        var isLatin: Bool {
            latinShare >= 0.8 && wordConfidence >= 0.85
        }
    }

    /// The script `sample` is written in and a model loaded for it, or nil when the
    /// text is Latin, CJK, or nothing any bundled model reads.
    ///
    /// Models run a few at a time and stop as soon as one is decisive, so the usual
    /// case — the user's own script, or the one Vision's nonsense points at — costs a
    /// single batch. Reading an unusual script can take every model (~0.5s).
    static func identifyScript(in sample: GrayImage, candidates: [Script],
                               tesseract: TesseractRecognizer) -> (script: Script, engine: TesseractEngine)? {
        let batchSize = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        var readings: [Reading] = []
        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
            let results = Results(count: batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                results[index] = read(sample, as: batch[index], tesseract: tesseract)
            }
            let batchReadings = results.values.compactMap { $0 }
            readings += batchReadings

            if let decisive = batchReadings.filter(\.isDecisive).max(by: { $0.nativeConfidence < $1.nativeConfidence }) {
                return (decisive.script, decisive.engine)
            }
            if readings.contains(where: \.isLatin) || !readings.contains(where: \.hasLetters) {
                return nil
            }
        }

        guard let best = readings
            .filter({ $0.nativeShare >= 0.5 && $0.nativeConfidence >= 0.96 })
            .max(by: { $0.nativeConfidence < $1.nativeConfidence })
        else { return nil }
        return (best.script, best.engine)
    }

    private static func read(_ sample: GrayImage, as script: Script, tesseract: TesseractRecognizer) -> Reading? {
        guard let engine = try? tesseract.engine(for: script),
              let page = try? engine.recognize(sample, symbols: true)
        else { return nil }

        var letters = 0, native = 0, latin = 0
        var nativeConfidence: Float = 0
        for symbol in page.symbols {
            guard let letterScript = symbol.text.unicodeScalars.lazy.compactMap(Script.of).first else { continue }
            letters += 1
            if letterScript == script {
                native += 1
                nativeConfidence += symbol.confidence
            } else if letterScript == .latin {
                latin += 1
            }
        }
        let words = page.lines.joined()
        return Reading(
            script: script,
            engine: engine,
            nativeShare: letters > 0 ? Float(native) / Float(letters) : 0,
            nativeConfidence: native > 0 ? nativeConfidence / Float(native) : 0,
            latinShare: letters > 0 ? Float(latin) / Float(letters) : 0,
            wordConfidence: words.isEmpty ? 0 : words.map(\.confidence).reduce(0, +) / Float(words.count),
            hasLetters: letters > 0)
    }

    /// Per-slot results written from `concurrentPerform`'s threads.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Reading?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        subscript(index: Int) -> Reading? {
            get { lock.withLock { slots[index] } }
            set { lock.withLock { slots[index] = newValue } }
        }

        var values: [Reading?] { lock.withLock { slots } }
    }

    // MARK: - Combining

    /// Tesseract's lines where they are in `script`, Vision's everywhere else.
    ///
    /// Vision keeps Latin lines on a mixed page, and Latin words inside a Tesseract
    /// line are replaced by Vision's reading of them, which is better ("iPhone" came
    /// back from the Hebrew model as "eחסhק"). Where Vision reads `script` itself and
    /// the text is in a language it supports — Arabic rather than Persian, Russian
    /// rather than Serbian — Vision's reading wins.
    static func merge(tesseract: [OCRLine], vision: [OCRLine], script: Script) -> [OCRLine] {
        let preferVision = visionReads(script)
            && LanguageDetector.language(of: tesseract.map(\.text).joined(separator: "\n"))?
                .languageCode.map { visionSupported.contains($0.identifier) } == true

        let visionWords = vision.flatMap(\.words).filter { isLatin($0.text) }
        var kept: [OCRLine] = []
        for line in tesseract {
            let scripts = Script.histogram(of: line.text)
            let letters = scripts.values.reduce(0, +)
            let inScript = (scripts[script] ?? 0) > 0 && Float(scripts[script] ?? 0) >= Float(letters) * 0.3
            let visionHasIt = vision.contains { overlaps($0.rect, line.rect) }

            if inScript && !preferVision {
                kept.append(patchLatinWords(line, from: visionWords))
            } else if !visionHasIt && line.confidence >= minimumLineConfidence {
                kept.append(line)
            }
        }
        let visionLines = vision.filter { line in
            line.confidence >= minimumVisionConfidence && !kept.contains { overlaps($0.rect, line.rect) }
        }
        return kept + visionLines
    }

    /// Vision reports 0.3, 0.5 or 1. Lines at 0.3 were nonsense in every case measured.
    static let minimumVisionConfidence: Float = 0.4

    /// Below this a Tesseract line that Vision did not also see is mostly noise from
    /// icons and borders.
    static let minimumLineConfidence: Float = 0.5

    private static func patchLatinWords(_ line: OCRLine, from visionWords: [OCRWord]) -> OCRLine {
        var used = Set<Int>()
        var words: [OCRWord] = []
        for word in line.words {
            guard word.text.unicodeScalars.contains(where: { Script.of($0) == .latin }) else {
                words.append(word)
                continue
            }
            let replacements = visionWords.indices
                .filter { !used.contains($0) && overlaps(visionWords[$0].rect, word.rect) }
                .sorted { visionWords[$0].rect.minX < visionWords[$1].rect.minX }
            guard !replacements.isEmpty else {
                words.append(word)
                continue
            }
            for (position, index) in replacements.enumerated() {
                used.insert(index)
                words.append(OCRWord(text: visionWords[index].text, rect: visionWords[index].rect,
                                     separator: position == 0 ? word.separator : " "))
            }
        }
        return OCRLine(words: words, rect: line.rect, confidence: line.confidence)
    }

    /// Latin letters and nothing from any other script.
    private static func isLatin(_ text: String) -> Bool {
        Set(Script.histogram(of: text).keys) == [.latin]
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.intersection(b).area >= min(a.area, b.area) * 0.5
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
