import CTesseract
import CoreGraphics
import Foundation

/// One loaded Tesseract model, wrapping the C API handle.
///
/// Not thread-safe: an engine is used by one thread at a time. Separate engines run in
/// parallel safely, which is how the script contest works.
final class TesseractEngine {
    let model: String
    private let handle: OpaquePointer

    /// Loads `model` (a `.traineddata` name without the extension) from `dataPath`.
    init(model: String, dataPath: String) throws {
        guard let handle = TessBaseAPICreate() else { throw TesseractError.initialisationFailed(model) }
        // Silences Tesseract's progress chatter ("Detected 24 diacritics") on stderr.
        TessBaseAPISetVariable(handle, "debug_file", "/dev/null")
        guard TessBaseAPIInit2(handle, dataPath, model, OEM_LSTM_ONLY) == 0 else {
            TessBaseAPIDelete(handle)
            throw TesseractError.initialisationFailed(model)
        }
        self.model = model
        self.handle = handle
    }

    deinit {
        TessBaseAPIDelete(handle)
    }

    /// Recognises `image` and returns its lines in Tesseract's reading order, with
    /// boxes in `image` pixels. Symbols are only collected when asked for: the script
    /// contest scores them, a full read does not need them.
    func recognize(_ image: GrayImage, resolution: Int32 = 144, symbols: Bool = false) throws -> TesseractPage {
        TessBaseAPISetPageSegMode(handle, PSM_AUTO)
        TessBaseAPISetImage(handle, image.pixels, Int32(image.width), Int32(image.height), 1, Int32(image.width))
        // Screen text at 2x is about 144 dpi; left unset, Tesseract assumes 70 and
        // mis-sizes its noise filters.
        TessBaseAPISetSourceResolution(handle, resolution)
        defer { TessBaseAPIClear(handle) }
        guard TessBaseAPIRecognize(handle, nil) == 0 else { throw TesseractError.recognitionFailed }

        var page = TesseractPage()
        guard let iterator = TessBaseAPIGetIterator(handle) else { return page }
        defer { TessResultIteratorDelete(iterator) }
        let position = TessResultIteratorGetPageIterator(iterator)

        repeat {
            if TessPageIteratorIsAtBeginningOf(position, RIL_TEXTLINE) != 0 || page.lines.isEmpty {
                page.lines.append([])
            }
            guard let raw = TessResultIteratorGetUTF8Text(iterator, RIL_WORD) else { continue }
            let text = String(cString: raw)
            TessDeleteText(raw)

            var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
            guard TessPageIteratorBoundingBox(position, RIL_WORD, &left, &top, &right, &bottom) != 0 else { continue }
            page.lines[page.lines.count - 1].append(TesseractWord(
                text: text,
                rect: CGRect(x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top)),
                confidence: TessResultIteratorConfidence(iterator, RIL_WORD) / 100))
        } while TessResultIteratorNext(iterator, RIL_WORD) != 0
        page.lines.removeAll { $0.isEmpty }

        if symbols, let iterator = TessBaseAPIGetIterator(handle) {
            defer { TessResultIteratorDelete(iterator) }
            repeat {
                guard let raw = TessResultIteratorGetUTF8Text(iterator, RIL_SYMBOL) else { continue }
                page.symbols.append((String(cString: raw), TessResultIteratorConfidence(iterator, RIL_SYMBOL) / 100))
                TessDeleteText(raw)
            } while TessResultIteratorNext(iterator, RIL_SYMBOL) != 0
        }
        return page
    }
}

struct TesseractWord {
    var text: String
    var rect: CGRect
    /// 0…1. Unlike Vision's, a real distribution: correct readings score 0.8–0.97.
    var confidence: Float
}

struct TesseractPage {
    /// Lines in Tesseract's reading order, each a list of words.
    var lines: [[TesseractWord]] = []
    /// Every recognised character with its confidence (0…1), when requested.
    var symbols: [(text: String, confidence: Float)] = []
}

enum TesseractError: Error, Equatable {
    case initialisationFailed(String)
    case recognitionFailed
}
