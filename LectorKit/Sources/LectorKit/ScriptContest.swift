import CoreGraphics
import Foundation

/// Works out, area by area, which script each piece of text is in, by letting the
/// script models compete over it, and keeps the winner's reading.
///
/// Area by area, because one capture can hold several scripts — a Hebrew line, a Greek
/// one and an Arabic one in the same window — and a model shown another script does not
/// return nothing: the Greek model reads French as Greek look-alikes ("νοῖτϐ 80οππΘ[η8ῃΐ"
/// for "Votre abonnement"). Each area is read on its own crop.
///
/// The right model reads its own script with near-certain confidence in its letters
/// (98–99.6%) while every wrong one scores 88–97%. Models run a few at a time, likeliest
/// first, over a few areas at a time; a script found in one area then reads the others
/// before anything else does, so a page in one script costs one batch on a sample and
/// one read per line.
final class ScriptContest: @unchecked Sendable {
    /// A piece of text to identify, usually one line.
    struct Area {
        /// In image pixels.
        let rect: CGRect
        /// The scripts it can be in, or nil for any. Text Vision read in full
        /// confidence as Arabic is in the Arabic script or one Vision takes for it.
        let scripts: Set<Script>?
        /// What Vision read there, if anything.
        let visionText: String

        /// Vision read it in Latin letters, as it reads Latin text and its nonsense for
        /// some scripts alike.
        var readAsLatin: Bool { Script.dominant(in: visionText) == .latin }
    }

    /// What one model made of one area.
    struct Reading: Sendable {
        let script: Script
        let page: TesseractPage
        /// Share of recognised letters in the model's own script.
        let nativeShare: Float
        /// Mean confidence over those letters: 0.98+ when the script is right.
        let nativeConfidence: Float
        /// Share of recognised letters that are Latin.
        let latinShare: Float
        /// Mean word confidence, which includes the dictionary. It is what exposes
        /// Latin text read as Cyrillic or Greek look-alikes (0.54–0.67): letter by
        /// letter those look certain.
        let wordConfidence: Float
        let letters: Int

        /// The right script beyond reasonable doubt. One letter alone never is: the
        /// Greek model read the rounded edge of a button as "ε" with full confidence.
        var isDecisive: Bool {
            nativeShare >= 0.5 && nativeConfidence >= 0.98 && wordConfidence >= 0.75 && letters >= 2
        }

        /// Decisive by a margin no wrong script reached on any area measured, enough
        /// for a script already found on the page to settle an area on its own.
        /// Devanagari read the Bengali "দেখুন" decisively (words 0.78); Bengali, not yet
        /// tried on it, would have scored higher.
        var isUnmistakable: Bool {
            isDecisive && wordConfidence >= 0.85
        }

        /// Plainly Latin text, which is Vision's to read. Every model whose letters
        /// don't mimic Latin ones reads Latin text as Latin, in real words.
        var isLatin: Bool {
            latinShare >= 0.8 && wordConfidence >= 0.85
        }

        /// What the model read, in its reading order.
        var text: String {
            page.lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: " ")
        }
    }

    enum Verdict {
        /// In `script`, as `reading` read it.
        case script(Script, Reading)
        /// Latin text, or nothing any model reads: Vision's reading stands.
        case vision
    }

    private let image: CGImage
    private let scale: CGFloat
    private let candidates: [Script]
    private let tesseract: TesseractRecognizer
    /// The model that settles whether text is Latin: the Hebrew one where there is
    /// one. Its letters share no shapes with Latin ones, so it reads Latin as Latin
    /// and whatever Vision took for Latin as something else: on lines of Greek,
    /// Georgian, Armenian and Amharic that Vision read in Latin letters it agreed with
    /// Vision on at most 83% of the letters, on Latin text on 88% or more but for one
    /// Vietnamese line. It is also among the quickest.
    private let latinReader: Script?
    private let batchSize = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
    /// How many undecided areas each batch of candidates is tried on.
    private let sampleSize = 4

    private let lock = NSLock()
    private var idle: [Script: [TesseractEngine]] = [:]

    /// - Parameters:
    ///   - scale: how much to enlarge areas for Tesseract, which misreads text under
    ///     about 20px a line.
    ///   - candidates: scripts to try, likeliest first.
    init(image: CGImage, scale: CGFloat, candidates: [Script], tesseract: TesseractRecognizer) {
        self.image = image
        self.scale = scale
        self.candidates = candidates
        self.tesseract = tesseract
        latinReader = candidates.contains(.hebrew) ? .hebrew : candidates.first { !$0.readsLatinAsLookalikes }
    }

    /// A verdict for each of `areas`, in reading order.
    ///
    /// Round by round, every undecided area is read in its likeliest scripts not yet
    /// tried, all in parallel:
    /// - what Vision read in Latin letters, in the Latin reader, then Greek, the
    ///   script Vision takes for Latin most often: nearly always it is Latin, which the
    ///   Latin reader confirms in one read;
    /// - text Vision read in full confidence in a script whose languages it confuses,
    ///   in that script, then in the scripts it takes for it;
    /// - anything else, in the scripts found elsewhere on the page — on most pages
    ///   that is all there is — and then a few areas at a time, in batches of the
    ///   likeliest candidates.
    func identify(_ areas: [Area]) throws -> [Verdict] {
        let crops = areas.map { crop($0.rect) }
        let options = areas.map { area in candidates.filter { area.scripts?.contains($0) ?? true } }
        var readings = [[Script: Reading]](repeating: [:], count: areas.count)
        var verdicts = [Verdict?](repeating: nil, count: areas.count)
        var found: [Script] = []

        func record(_ verdict: Verdict?, at index: Int) {
            verdicts[index] = verdict
            if case .script(let script, _) = verdict, !found.contains(script) { found.append(script) }
        }

        while true {
            try Task.checkCancellation()
            var plan: [Int: [Script]] = [:]
            var waiting: [Int] = []
            for index in verdicts.indices where verdicts[index] == nil {
                let unread = options[index].filter { readings[index][$0] == nil }
                if unread.isEmpty {
                    record(verdict(readings[index], of: areas[index], exhausted: true), at: index)
                } else if let next = next(for: areas[index], unread: unread, read: readings[index], found: found) {
                    plan[index] = next
                } else {
                    waiting.append(index)
                }
            }
            for index in waiting.prefix(sampleSize) {
                plan[index] = Array(options[index].filter { readings[index][$0] == nil }.prefix(batchSize))
            }
            guard !plan.isEmpty else { break }

            var work: [Script: [Int]] = [:]
            for (index, scripts) in plan.sorted(by: { $0.key < $1.key }) {
                for script in scripts { work[script, default: []].append(index) }
            }
            read(work.map { ($0.key, $0.value) }, crops: crops, into: &readings)
            for index in plan.keys.sorted() {
                record(verdict(readings[index], of: areas[index],
                               exhausted: options[index].allSatisfy { readings[index][$0] != nil }),
                       at: index)
            }
        }
        return verdicts.map { $0 ?? .vision }
    }

    /// The scripts to read `area` in next, or nil for the next batch of candidates.
    private func next(for area: Area, unread: [Script], read: [Script: Reading], found: [Script]) -> [Script]? {
        // A look-alike script's claim stands only once Latin has been ruled out.
        if let latinReader, unread.contains(latinReader),
           area.readAsLatin || read.values.contains(where: \.isUnmistakable) && !Self.latinChecked(read) {
            return [latinReader]
        }
        if area.readAsLatin, unread.contains(.greek) { return [.greek] }
        if area.scripts != nil, read.isEmpty {
            let own = Script.dominant(in: area.visionText)
            return [own.flatMap { unread.contains($0) ? $0 : nil } ?? unread[0]]
        }
        let known = found.filter(unread.contains)
        return known.isEmpty ? nil : known
    }

    /// For each of `areas`, the decisive reading among `scripts`, if any.
    ///
    /// For text Vision read confidently as Latin, or as nothing but digits, once a
    /// script it has no model for turns up on the page: Vision reads such scripts as
    /// confident nonsense ("DIYU" for Hebrew, "2509" for the Tamil "உதவி"). Real Latin
    /// text never reads decisively in a model of another script that does not mimic
    /// Latin letters.
    func challenge(_ areas: [CGRect], with scripts: [Script]) throws -> [Int: Reading] {
        try Task.checkCancellation()
        let crops = areas.map(crop)
        var readings = [[Script: Reading]](repeating: [:], count: areas.count)
        read(scripts.map { ($0, Array(areas.indices)) }, crops: crops, into: &readings)
        var winners: [Int: Reading] = [:]
        for (index, area) in readings.enumerated() {
            winners[index] = area.values.filter(\.isDecisive).max(by: Self.confidence)
        }
        return winners
    }

    /// The lines `reading` found in `area`, in image pixels.
    func lines(of reading: Reading, in area: CGRect) -> [OCRLine] {
        TesseractRecognizer.lines(from: reading.page, scale: scale, origin: padded(area).origin,
                                  rightToLeft: reading.script.isRightToLeft)
    }

    // MARK: - Judging

    private static func confidence(_ a: Reading, _ b: Reading) -> Bool {
        a.nativeConfidence < b.nativeConfidence
    }

    /// Greek and Cyrillic models read Latin text as look-alikes, sometimes decisively
    /// ("Тгаск уоиг раскаде" for "Track your package"), so whether text is Latin is
    /// only known once another model has seen it.
    private static func latinChecked(_ readings: [Script: Reading]) -> Bool {
        readings.keys.contains { !$0.readsLatinAsLookalikes }
    }

    /// Latin or a script, once the Latin reader or another model that reads Latin as
    /// Latin has had its say and a reading passes `decisive`; nil while neither is clear.
    ///
    /// Of a decisive reading and a Latin one, the one whose words the dictionary knows
    /// better wins: the Cyrillic model read "Track your package" decisively with words
    /// at 0.86 where read as Latin they scored 0.96, and the Kannada model read the
    /// Greek "Αρχείο" as "Apxelo" at 0.88 where the Greek model scored 0.96.
    ///
    /// Words score low in long lines of Latin text — these models' dictionaries don't
    /// know French or German — so Latin is also the Latin reader reading the same
    /// letters Vision read: the same line of German scored 0.44 as words and 100% as
    /// letters.
    private func judge(_ readings: [Script: Reading], of area: Area, by decisive: (Reading) -> Bool) -> Verdict? {
        guard Self.latinChecked(readings) else { return nil }
        let latin = readings.values.filter(\.isLatin).map(\.wordConfidence).max()
        if let best = readings.values.filter(decisive).max(by: Self.confidence), best.wordConfidence > latin ?? 0 {
            return .script(best.script, best)
        }
        if latin != nil { return .vision }
        if let reading = latinReader.flatMap({ readings[$0] }), reading.latinShare >= 0.8,
           Self.agreement(reading.text, area.visionText) >= 0.85 {
            return .vision
        }
        return nil
    }

    /// The share of letters two readings have in common, ignoring case, accents and
    /// everything but letters: 1 when they read the same.
    static func agreement(_ a: String, _ b: String) -> Float {
        func letters(_ text: String) -> [Unicode.Scalar] {
            text.applyingTransform(.stripDiacritics, reverse: false)?.lowercased().unicodeScalars
                .filter(\.properties.isAlphabetic) ?? []
        }
        let a = letters(a), b = letters(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        // Edit distance, one row at a time.
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return 1 - Float(row[b.count]) / Float(max(a.count, b.count))
    }

    /// The verdict `readings` support, or nil while more models should be tried.
    private func verdict(_ readings: [Script: Reading], of area: Area, exhausted: Bool) -> Verdict? {
        // Read in a few scripts only, a reading must be unmistakable to decide; among
        // a batch of the likeliest, decisive will do.
        let decisive: (Reading) -> Bool = exhausted || readings.count >= batchSize ? \.isDecisive : \.isUnmistakable
        if let verdict = judge(readings, of: area, by: decisive) { return verdict }
        // Icons, rules and text in a script no model reads.
        if readings.count >= batchSize, !readings.values.contains(where: { $0.letters > 0 }) { return .vision }
        guard exhausted else { return nil }

        // Nothing was decisive: pointed Hebrew (the points drag its letters to 0.97),
        // Lao and Khmer (weak dictionaries), a line read only as a raw line. A clear
        // winner over enough letters will do; two or three confident letters are what
        // wrong models make of CJK.
        let contenders = readings.values.filter { $0.nativeShare >= 0.5 }
            .sorted { $0.nativeConfidence > $1.nativeConfidence }
        guard let best = contenders.first, best.nativeConfidence >= 0.96, best.letters >= 8,
              contenders.count < 2 || best.nativeConfidence - contenders[1].nativeConfidence >= 0.01
        else { return .vision }
        return .script(best.script, best)
    }

    // MARK: - Reading

    /// An area cut out with some margin and enlarged by `scale`, and the band of the
    /// crop the area itself fills.
    private struct Crop: Sendable {
        let image: GrayImage?
        let band: ClosedRange<CGFloat>
    }

    private func padded(_ area: CGRect) -> CGRect {
        area.insetBy(dx: -area.height * 0.5, dy: -area.height * 0.35)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
    }

    private func crop(_ area: CGRect) -> Crop {
        let outer = padded(area)
        return Crop(image: GrayImage(stacking: [outer], of: image, scale: scale),
                    band: ((area.minY - outer.minY) * scale)...((area.maxY - outer.minY) * scale))
    }

    /// Reads the areas of each `(script, areas)` pair with that script's model, in
    /// parallel. Loading a model takes about as long as reading two lines of a Retina
    /// screen (120,000 pixels), so each job reads about that much: two long lines, or
    /// a whole menu of labels.
    private func read(_ work: [(Script, [Int])], crops: [Crop], into readings: inout [[Script: Reading]]) {
        let jobs = work.flatMap { script, areas -> [(Script, ArraySlice<Int>)] in
            var jobs: [(Script, ArraySlice<Int>)] = []
            var start = 0, pixels = 0
            for (position, index) in areas.enumerated() {
                pixels += crops[index].image.map { $0.width * $0.height } ?? 0
                if pixels >= 120_000 || position == areas.count - 1 {
                    jobs.append((script, areas[start...position]))
                    start = position + 1
                    pixels = 0
                }
            }
            return jobs
        }
        let results = Results(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { job in
            let (script, areas) = jobs[job]
            guard let engine = takeEngine(for: script) else { return }
            defer { giveBack(engine, for: script) }
            results[job] = areas.compactMap { index in
                read(crops[index], as: script, with: engine).map { (index, $0) }
            }
        }
        for (job, items) in results.values.enumerated() {
            for (index, reading) in items ?? [] {
                readings[index][jobs[job].0] = reading
            }
        }
    }

    /// One model's reading of one crop, judged by what it read inside the area: the
    /// margin catches slivers of the lines above and below, read as nonsense.
    private func read(_ crop: Crop, as script: Script, with engine: TesseractEngine) -> Reading? {
        guard let image = crop.image, var page = try? engine.recognize(image) else { return nil }
        func inside(_ item: TesseractWord) -> Bool { crop.band.contains(item.rect.midY) }
        func isLetter(_ item: TesseractWord) -> Bool { item.text.unicodeScalars.contains { Script.of($0) != nil } }
        // Line finding now and then throws out a whole short line ("لطفاً به من کمک کنید.",
        // "مرحباً بكم في تطبيقنا.") that the same model reads well taken as one raw line.
        if !page.symbols.contains(where: { inside($0) && isLetter($0) }),
           let line = try? engine.recognize(image, as: .line) {
            page = line
        }
        page.lines = page.lines.map { $0.filter(inside) }.filter { !$0.isEmpty }

        var letters = 0, native = 0, latin = 0
        var nativeConfidence: Float = 0
        for symbol in page.symbols where inside(symbol) {
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
            page: page,
            nativeShare: letters > 0 ? Float(native) / Float(letters) : 0,
            nativeConfidence: native > 0 ? nativeConfidence / Float(native) : 0,
            latinShare: letters > 0 ? Float(latin) / Float(letters) : 0,
            wordConfidence: words.isEmpty ? 0 : words.map(\.confidence).reduce(0, +) / Float(words.count),
            letters: letters)
    }

    // MARK: - Engines

    /// Engines load once per script and are reused across batches; each serves one
    /// thread at a time.
    private func takeEngine(for script: Script) -> TesseractEngine? {
        if let engine = lock.withLock({ idle[script]?.popLast() }) { return engine }
        return try? tesseract.engine(for: script)
    }

    private func giveBack(_ engine: TesseractEngine, for script: Script) {
        lock.withLock { idle[script, default: []].append(engine) }
    }

    /// Per-job results written from `concurrentPerform`'s threads.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [[(Int, Reading)]?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        subscript(index: Int) -> [(Int, Reading)]? {
            get { lock.withLock { slots[index] } }
            set { lock.withLock { slots[index] = newValue } }
        }

        var values: [[(Int, Reading)]?] { lock.withLock { slots } }
    }
}
