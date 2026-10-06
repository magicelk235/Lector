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
/// What works is letting the script models compete, line by line, over the text Vision
/// left unread or read with doubt: the model for the right script reads it with
/// near-certain confidence in its own letters (98–99.6% per character) while every
/// wrong model scores 88–97%. See `ScriptContest`. Everything Vision read well stays
/// Vision's: a wrong-script model reads Latin text as look-alike nonsense, so letting a
/// script that won somewhere on the page read the whole page turned French into Greek.
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

    /// Vision reports 0.3, 0.5 or 1. Lines at 0.3 were nonsense in every case measured,
    /// except CJK: short labels such as "設定" or "終了" are read right at 0.3.
    static let minimumVisionConfidence: Float = 0.4

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

    // MARK: - When it is not

    /// The lines of `image` once every one of them is settled, when Vision's
    /// `reading` of it is not enough on its own.
    ///
    /// 1. Vision takes a second look at what it left unread, and at CJK it read in too
    ///    much doubt to keep, cut out with a margin: it misses small isolated words in
    ///    a large capture, CJK labels above all, and reads them in a crop.
    /// 2. What is still unsettled — text Vision cannot read or read in doubt, lines in
    ///    a script whose languages it confuses — goes to the script contest, area by
    ///    area. Areas may hold different scripts; none of them can take over a line
    ///    Vision read well, unless a script it cannot read turns up right beside it.
    static func read(_ image: CGImage, vision: VisionReading, pixels: GrayImage?,
                     tesseract: TesseractRecognizer) throws -> [OCRLine] {
        let measured = medianHeight(vision.lines.map(\.rect) + vision.textRegions)
        let ink = pixels.map { InkLines.find(in: $0, textHeight: measured ?? 24) } ?? []
        let textHeight = measured ?? medianHeight(ink.map(\.rect)) ?? 24
        let reading = try secondLook(at: image, after: vision, ink: ink, textHeight: textHeight)

        // What the second look added is only settled if CJK, which it is for: in a
        // crop, Vision also reads the Greek "Το πακέτο σας έχει σταλεί." as
        // "To nakéto das éxel otalEi." in full confidence.
        var settled = reading.lines.filter { isSettled($0) && (vision.lines.contains($0) || isCJK($0.text)) }
        var areas: [(rect: CGRect, vision: [OCRLine])] = reading.lines.filter { !settled.contains($0) }.map {
            (extent(of: $0.rect, in: ink), [$0])
        }
        for rect in unreadAreas(reading, ink: ink, textHeight: textHeight)
        where !areas.contains(where: { overlaps($0.rect, rect) }) {
            areas.append((rect, []))
        }
        guard !areas.isEmpty else { return settled }
        areas.sort { $0.rect.minY < $1.rect.minY }

        let contest = ScriptContest(
            image: image, scale: tesseractScale(forTextHeight: textHeight),
            candidates: candidates(for: areas.map { $0.vision.map(\.text).joined(separator: " ") },
                                   available: tesseract.hasModel(for:)),
            tesseract: tesseract)
        let verdicts = try contest.identify(areas.map { area in
            ScriptContest.Area(rect: area.rect, scripts: possibleScripts(given: area.vision),
                               visionText: area.vision.map(\.text).joined(separator: " "))
        })

        var assigned: [Int: (script: Script, lines: [OCRLine], decisive: Bool)] = [:]
        for (index, verdict) in verdicts.enumerated() {
            guard case .script(let script, let reading) = verdict else { continue }
            assigned[index] = (script, contest.lines(of: reading, in: areas[index].rect), reading.isDecisive)
        }

        let visionWords = reading.lines.flatMap(\.words).filter { isLatin($0.text) }
        var lines: [OCRLine] = []
        var modelRead: [CGRect] = []

        // A script Vision cannot read turned up: Latin lines and lines of nothing but
        // digits beside it may be Vision's nonsense for it — "DIYU" for Hebrew, "2509"
        // for the Tamil "உதவி". Each line found that way leads on to the next.
        var found = assigned.values.filter { !visionReads($0.script) }.flatMap { area in
            area.lines.map { (script: area.script, rect: $0.rect) }
        }
        var suspects = settled.indices.filter { Script.histogram(of: settled[$0].text).keys.allSatisfy { $0 == .latin } }
        var replaced = Set<Int>()
        while !found.isEmpty {
            let next = suspects.filter { index in found.contains { abut($0.rect, settled[index].rect, lineHeight: textHeight) } }
            guard !next.isEmpty else { break }
            suspects.removeAll(where: next.contains)
            let scripts = Set(found.map(\.script)).sorted { $0.rawValue < $1.rawValue }
            let extents = next.map { extent(of: settled[$0].rect, in: ink) }
            found = []
            for (position, reading) in try contest.challenge(extents, with: scripts) {
                let replacement = contest.lines(of: reading, in: extents[position])
                lines += replacement.map { patchLatinWords($0, from: visionWords) }
                modelRead += replacement.map(\.rect)
                found += replacement.map { (reading.script, $0.rect) }
                replaced.insert(next[position])
            }
        }
        settled = settled.indices.filter { !replaced.contains($0) }.map { settled[$0] }

        // Where Vision read a line itself, in a script and language it reads, its
        // reading is the better one.
        let preferVision = Set(assigned.values.map(\.script).filter { script in
            visionReads(script) && visionReadsLanguage(of: assigned.values.filter { $0.script == script && $0.decisive }
                .flatMap(\.lines).map(\.text).joined(separator: "\n"), in: script)
        })
        for (index, area) in areas.enumerated() {
            let visionLines = area.vision.filter { $0.confidence >= minimumVisionConfidence }
            if let (script, read, _) = assigned[index], !(preferVision.contains(script) && !visionLines.isEmpty) {
                // Latin words inside are Vision's: "iPhone" came back from the Hebrew
                // model as "eחסhק".
                lines += read.map { patchLatinWords($0, from: visionWords) }
                modelRead += read.map(\.rect)
            } else {
                lines += visionLines
            }
        }
        // A name Vision read on its own inside a line a script model read whole
        // ("iPhone 15" in a Hebrew sentence) would be there twice.
        return lines + settled.filter { line in !modelRead.contains { overlaps($0, line.rect) } }
    }

    /// Whether `text`, a script model's decisive reading in `script`, is in a language
    /// Vision reads — Arabic rather than Persian, Russian rather than Serbian — so that
    /// Vision's reading of it is the better one. With nothing decisive to go on, it is.
    ///
    /// Vision reads Persian and Urdu as Arabic, writing the nearest letter Arabic has
    /// ("چ" → "ج"). Their own letters show what the text is, but not "ک" and "ی",
    /// which the Arabic model also writes for Arabic's "ك" and "ي", nor a single
    /// stray: the same model once read the Arabic "بأن" as "پان".
    static func visionReadsLanguage(of text: String, in script: Script) -> Bool {
        guard !text.isEmpty else { return true }
        if script == .arabic {
            return text.unicodeScalars.filter(lettersArabicLacks.contains).count < 2
        }
        return LanguageDetector.language(of: text)?.languageCode.map { visionSupported.contains($0.identifier) } == true
    }

    /// Letters of the Arabic script that Arabic does not use, and the zero-width
    /// non-joiner Persian writes inside words ("می‌خواهم"): Persian پ چ ژ گ, Urdu ٹ ڈ
    /// ڑ ں ے ۓ, Pashto ټ ډ ړ ږ ښ ګ ڼ ې ۍ, Kurdish ڕ ڵ ۆ ێ, Uyghur ۇ ۈ ۋ.
    static let lettersArabicLacks: Set<Unicode.Scalar> = Set(
        "پچژگٹڈڑںےۓټډړږښګڼېۍڕڵۆێۇۈۋ\u{200C}".unicodeScalars)

    /// `vision` with what Vision reads on a second look at `image`: at text it left
    /// unread, cut out with a margin, since it misses small isolated words in a large
    /// capture, and at CJK it read in too much doubt to keep ("1除" for "削除"). A line
    /// merely in doubt it reads no differently a second time, and every line without
    /// CJK it read in too much doubt, on 99 test captures, was its nonsense for a
    /// script it can't read, which the script contest reads.
    static func secondLook(at image: CGImage, after vision: VisionReading, ink: [InkLine],
                           textHeight: CGFloat) throws -> VisionReading {
        let size = CGSize(width: image.width, height: image.height)
        var reading = vision
        var unseen = unreadAreas(reading, ink: ink, textHeight: textHeight) + reading.lines.filter { line in
            line.confidence < minimumVisionConfidence && Script.histogram(of: line.text).keys.contains(where: \.isCJK)
        }.map(\.rect)
        // Cut out, small text is read enlarged, to the size Tesseract wants too.
        let scale = tesseractScale(forTextHeight: textHeight)
        // Which words of a crop Vision reads is erratic — of four labels it may read
        // one — so where a crop was read in part, what it left gets another, tighter
        // look. Where it read nothing, it will read nothing again.
        for _ in 0..<2 where !unseen.isEmpty {
            var progressed: [CGRect] = []
            for region in secondLookRegions(unseen, textHeight: textHeight, imageSize: size) {
                try Task.checkCancellation()
                let before = reading.lines
                reading.absorb(try TextRecognizer().read(image, in: region, scale: scale))
                if reading.lines != before { progressed.append(region) }
            }
            unseen = unreadAreas(reading, ink: ink, textHeight: textHeight).filter { area in
                progressed.contains { $0.intersects(area) }
            }
        }
        return reading
    }

    /// Whether `a` and `b` are close enough to be one block of text: within a line
    /// and a half of each other both down and across.
    static func abut(_ a: CGRect, _ b: CGRect, lineHeight: CGFloat) -> Bool {
        max(a.minY - b.maxY, b.minY - a.maxY) < lineHeight * 1.5
            && max(a.minX - b.maxX, b.minX - a.maxX) < lineHeight * 1.5
    }

    /// Lines Vision reads as well as anything can: in full confidence in a script it
    /// reads unmistakably, or CJK at all.
    static func isSettled(_ line: OCRLine) -> Bool {
        if isCJK(line.text) {
            // A lone character at 0.3 is as likely an icon read as "口".
            return line.confidence >= minimumVisionConfidence || Script.histogram(of: line.text).values.reduce(0, +) >= 2
        }
        return line.confidence >= 1
            && Script.histogram(of: line.text).keys.allSatisfy { visionReads($0) && !confusable.contains($0) }
    }

    /// Text in CJK scripts and nothing else, which no bundled model reads: Vision's
    /// reading of it, however doubtful, is the only one there is. Of 28 scripts Vision
    /// cannot read, none came back as CJK alone, though it mixes a CJK character into
    /// its nonsense now and then ("そ7H" for the Amharic "እገዛ").
    static func isCJK(_ text: String) -> Bool {
        let scripts = Script.histogram(of: text).keys
        return !scripts.isEmpty && scripts.allSatisfy(\.isCJK)
    }

    /// The scripts a line Vision read in `lines` can be in, nil for any. Read in full
    /// confidence in a script Vision reads, it is that script or one Vision takes for
    /// it (Bengali for Devanagari, Persian for Arabic); in doubt or in Latin letters,
    /// it could be anything.
    static func possibleScripts(given lines: [OCRLine]) -> Set<Script>? {
        guard !lines.isEmpty, lines.allSatisfy({ $0.confidence >= 1 }),
              let script = Script.dominant(in: lines.map(\.text).joined()),
              script != .latin, visionReads(script)
        else { return nil }
        return Set(hints(forVisionScript: script))
    }

    /// `rect`, a line Vision read, fitted to the ink on its rows: its box for a line it
    /// read as nonsense can cover half of it, and its box for a line can take in a
    /// slice of the next.
    static func extent(of rect: CGRect, in ink: [InkLine]) -> CGRect {
        var span = CGRect.null
        for line in ink where line.rect.intersects(rect) {
            for run in line.runs where rect.minY <= run.midY && run.midY <= rect.maxY {
                span = span.union(run)
            }
        }
        return span.isNull ? rect : span
    }

    /// Text Vision read no words of: ink its lines leave out — it also stops short,
    /// "検" of "検索" — and regions its detector found that its lines don't cover.
    static func unreadAreas(_ reading: VisionReading, ink: [InkLine], textHeight: CGFloat) -> [CGRect] {
        var areas = ink.compactMap { $0.uncovered(by: reading.lines.map(\.rect), minimumHeight: textHeight * 0.4) }
        for region in reading.textRegions where !areas.contains(where: { overlaps($0, region) }) {
            let covered = reading.lines.reduce(0) { $0 + region.intersection($1.rect).area }
            if covered < region.area * 0.5 { areas.append(region) }
        }
        return areas
    }

    /// Where to show Vision again what it left unread or doubted: the areas grouped
    /// where they sit close — a column of menu labels, a line apart, is read best as a
    /// column — with a line's margin around them. A group nearly as big as the image
    /// is left out: Vision has just seen that.
    static func secondLookRegions(_ areas: [CGRect], textHeight: CGFloat, imageSize: CGSize) -> [CGRect] {
        var groups: [CGRect] = []
        for area in areas.sorted(by: { $0.minY < $1.minY }) {
            var group = area
            while let index = groups.firstIndex(where: {
                $0.insetBy(dx: -textHeight, dy: -textHeight * 1.5).intersects(group)
            }) {
                group = group.union(groups.remove(at: index))
            }
            groups.append(group)
        }
        let bounds = CGRect(origin: .zero, size: imageSize)
        return Array(groups.map { $0.insetBy(dx: -textHeight, dy: -textHeight).intersection(bounds) }
            .filter { $0.area <= bounds.area * 0.5 }
            .prefix(8))
    }

    /// The median height of `rects`, nil for none.
    static func medianHeight(_ rects: [CGRect]) -> CGFloat? {
        let heights = rects.map(\.height).sorted()
        return heights.isEmpty ? nil : heights[heights.count / 2]
    }

    /// How much to enlarge text for Tesseract, which misreads text under about 20px a
    /// line. Retina screen text is 26–40px and read as it is; text from a
    /// standard-resolution screen is half that.
    static func tesseractScale(forTextHeight height: CGFloat) -> CGFloat {
        height < 12 ? 3 : height < 20 ? 2 : 1
    }

    // MARK: - Which scripts to try

    /// Scripts to try, likeliest first: the user's own languages, then the scripts
    /// Vision tends to mistake the texts it saw for, most common first, then
    /// everything else.
    static func candidates(for visionTexts: [String],
                           preferredLanguages: [String] = Locale.preferredLanguages,
                           available: (Script) -> Bool) -> [Script] {
        let preferred = preferredLanguages.compactMap { identifier -> Script? in
            let language = Locale.Language(identifier: identifier)
            let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
            return script.flatMap { Script(iso15924: $0.identifier) }
        }
        var counts: [Script?: Int] = [:]
        for text in visionTexts { counts[Script.dominant(in: text), default: 0] += 1 }
        let hints = counts.sorted { $0.value > $1.value || ($0.value == $1.value && ($0.key?.rawValue ?? "") < ($1.key?.rawValue ?? "")) }
            .flatMap { hints(forVisionScript: $0.key) }
        // Roughly by number of readers, for when nothing else points anywhere.
        let rest: [Script] = [.arabic, .cyrillic, .devanagari, .bengali, .hebrew, .greek, .tamil, .telugu,
                              .gujarati, .kannada, .malayalam, .gurmukhi, .thai, .myanmar, .khmer, .lao,
                              .sinhala, .oriya, .georgian, .armenian, .ethiopic, .tibetan, .thaana, .syriac,
                              .cherokee, .canadianAboriginal]
        var seen = Set<Script>()
        return (preferred + hints + rest).filter { available($0) && seen.insert($0).inserted }
    }

    /// What text Vision read as `script` (nil: read nothing) tends to be in.
    private static func hints(forVisionScript script: Script?) -> [Script] {
        switch script {
        case .devanagari: [.devanagari, .bengali, .gujarati, .gurmukhi, .tibetan, .oriya]
        case .thai: [.thai, .lao, .khmer, .myanmar, .kannada, .sinhala]
        case .arabic: [.arabic, .syriac, .thaana]
        case .cyrillic: [.cyrillic, .greek, .cherokee]
        case .latin: [.greek, .hebrew, .armenian, .georgian, .ethiopic, .cyrillic, .cherokee, .canadianAboriginal, .oriya]
        case nil: [.hebrew, .tamil, .telugu, .malayalam, .sinhala, .syriac, .thaana, .arabic]
        default: []
        }
    }

    // MARK: - Combining

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

extension VisionReading {
    /// Folds in a second look at part of the image. A line read there replaces what
    /// the first look made of the same text when it is read with more confidence, or
    /// goes further: the first look also stops short ("検" for "検索"). CJK read in two
    /// pieces, one per look ("終", then "了"), is joined up.
    mutating func absorb(_ other: VisionReading) {
        for line in other.lines {
            let clashing = lines.indices.filter { RecognitionBackend.overlaps(lines[$0].rect, line.rect) }
            if clashing.isEmpty, let piece = lines.firstIndex(where: { Self.adjoin($0, line) }) {
                lines[piece] = Self.join(lines[piece], line)
                continue
            }
            let better = clashing.allSatisfy { index in
                let old = lines[index]
                let extends = line.text.count > old.text.count && line.text.contains(old.text)
                    && (line.confidence >= RecognitionBackend.minimumVisionConfidence
                        || RecognitionBackend.isCJK(line.text))
                return line.confidence > old.confidence || extends
            }
            guard better else { continue }
            for index in clashing.reversed() { lines.remove(at: index) }
            lines.append(line)
        }
        for region in other.textRegions where !textRegions.contains(where: { RecognitionBackend.overlaps($0, region) }) {
            textRegions.append(region)
        }
    }

    /// Two CJK lines side by side on one row with no more than half a character
    /// between them: pieces of one word.
    private static func adjoin(_ a: OCRLine, _ b: OCRLine) -> Bool {
        guard RecognitionBackend.isCJK(a.text), RecognitionBackend.isCJK(b.text) else { return false }
        let height = max(a.rect.height, b.rect.height)
        let shared = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
        let gap = max(b.rect.minX - a.rect.maxX, a.rect.minX - b.rect.maxX)
        return shared >= min(a.rect.height, b.rect.height) * 0.6 && gap <= height * 0.5
    }

    private static func join(_ a: OCRLine, _ b: OCRLine) -> OCRLine {
        let (left, right) = a.rect.minX <= b.rect.minX ? (a, b) : (b, a)
        var words = right.words
        words[0].separator = RecognizedText.separator(between: left.words.last?.text ?? "", and: words[0].text)
        return OCRLine(words: left.words + words, rect: left.rect.union(right.rect),
                       confidence: min(left.confidence, right.confidence))
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
