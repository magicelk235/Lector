import Accelerate
import COnnxRuntime
import Foundation

/// One Opus-MT model on disk: the ONNX encoder and decoder plus Marian's tokenizer.
///
/// Decoding is beam search over a key/value cache, several texts at once. The decoder
/// comes in either of the shapes Optimum exports: one "merged" graph that switches on
/// `use_cache_branch`, or a first-step graph paired with a with-past graph.
final class MarianModel: Sendable {
    struct Configuration: Sendable {
        let decoderStartTokenID: Int
        let eosTokenID: Int
        let padTokenID: Int
        let heads: Int
        let headDimension: Int
        let maxPositions: Int
    }

    private enum Decoder: Sendable {
        case merged(ORTSession)
        case split(first: ORTSession, withPast: ORTSession)
    }

    let tokenizer: MarianTokenizer
    let configuration: Configuration
    private let encoder: ORTSession
    private let decoder: Decoder

    /// Beam width. Four is what the models were tuned with, and on these models four
    /// rows cost barely more per step than one.
    let beamWidth: Int

    /// Rows per decoder run. Measured on an M4: a step over 4 rows takes 6 ms, over 40
    /// rows 17 ms and over 80 rows 23 ms, so batching lines is most of the speed on a
    /// screenful of text; past about 64 rows the gain flattens and memory keeps growing.
    private let maxBatchRows = 64

    init(directory: URL, beamWidth: Int = 4) throws {
        self.beamWidth = max(1, beamWidth)
        tokenizer = try MarianTokenizer(directory: directory)
        configuration = try Self.readConfiguration(directory.appending(path: "config.json"))
        encoder = try ORTSession(modelPath: directory.appending(path: "encoder.onnx").path(percentEncoded: false))
        let merged = directory.appending(path: "decoder_merged.onnx")
        if FileManager.default.fileExists(atPath: merged.path(percentEncoded: false)) {
            decoder = .merged(try ORTSession(modelPath: merged.path(percentEncoded: false)))
        } else {
            decoder = .split(
                first: try ORTSession(modelPath: directory.appending(path: "decoder.onnx").path(percentEncoded: false)),
                withPast: try ORTSession(modelPath: directory.appending(path: "decoder_with_past.onnx").path(percentEncoded: false))
            )
        }
        let pastSession: ORTSession = switch decoder {
        case .merged(let session): session
        case .split(_, let withPast): withPast
        }
        guard pastSession.inputNames.contains(where: { $0.hasPrefix("past_key_values.") }) else {
            throw OnnxRuntimeError(description: "Decoder has no key/value cache inputs")
        }
    }

    private static func readConfiguration(_ url: URL) throws -> Configuration {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw OnnxRuntimeError(description: "config.json is not an object")
        }
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        guard let start = int("decoder_start_token_id"), let eos = int("eos_token_id"),
              let pad = int("pad_token_id"), let dModel = int("d_model"),
              let heads = int("decoder_attention_heads"), heads > 0
        else { throw OnnxRuntimeError(description: "config.json lacks Marian settings") }
        return Configuration(
            decoderStartTokenID: start, eosTokenID: eos, padTokenID: pad,
            heads: heads, headDimension: dModel / heads,
            maxPositions: int("max_position_embeddings") ?? 512
        )
    }

    /// The most source tokens to give the model at once. Half its positions: a translation
    /// can run longer than its source, and whatever would fall past the last position is
    /// lost.
    var maxChunkTokens: Int { configuration.maxPositions / 2 }

    /// Translates each text independently, batching them through the model.
    func translate(_ texts: [String], languageToken: String?, stop: StopFlag? = nil) throws -> [String] {
        let sources = texts.map { text in
            let ids = tokenizer.encode(text, languageToken: languageToken)
            guard ids.count > configuration.maxPositions else { return ids }
            // Only one unbroken "word" hundreds of tokens long gets here; the model has
            // no position for the rest of it.
            return Array(ids.prefix(configuration.maxPositions - 1)) + [configuration.eosTokenID]
        }
        // Similar lengths together, so short lines are not padded out to a long one.
        let order = sources.indices.sorted { sources[$0].count < sources[$1].count }
        let perBatch = max(1, maxBatchRows / beamWidth)
        var translations = [String](repeating: "", count: texts.count)
        for start in stride(from: 0, to: order.count, by: perBatch) {
            let batch = Array(order[start..<min(start + perBatch, order.count)])
            let outputs = try generate(batch.map { sources[$0] }, stop: stop)
            for (index, output) in zip(batch, outputs) {
                translations[index] = tokenizer.decode(output)
            }
        }
        return translations
    }

    // MARK: - Generation

    /// The beam search for one source.
    private struct Search {
        var tokens: [[Int]]
        var scores: [Float]
        var finished: FinishedHypotheses
        let maxNewTokens: Int
        var result: [Int]?
    }

    /// Generated ids for each source (without the decoder start token or `</s>`).
    ///
    /// Row `b * beamWidth + k` of every tensor is beam `k` of source `b`. When a source
    /// finishes, its rows are dropped from the batch, so one long line does not keep
    /// running the finished short ones alongside it.
    func generate(_ sources: [[Int]], stop: StopFlag? = nil) throws -> [[Int]] {
        guard !sources.isEmpty else { return [] }
        let config = configuration
        let beams = beamWidth
        let length = sources.map(\.count).max() ?? 0
        var ids = [Int64](repeating: Int64(config.padTokenID), count: sources.count * length)
        var sourceMask = [Int64](repeating: 0, count: sources.count * length)
        for (row, source) in sources.enumerated() {
            for (column, id) in source.enumerated() {
                ids[row * length + column] = Int64(id)
                sourceMask[row * length + column] = 1
            }
        }
        let maskTensor = try ORTValue.int64(sourceMask, shape: [sources.count, length])
        let encoded = try encoder.run(
            [("input_ids", try .int64(ids, shape: [sources.count, length])), ("attention_mask", maskTensor)],
            outputs: ["last_hidden_state"]
        )[0]
        let rowsForSources = { (live: [Int]) in live.flatMap { Array(repeating: $0, count: beams) } }
        var live = Array(sources.indices)
        var hidden = try Self.select(rows: rowsForSources(live), of: encoded, elementSize: 4, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        var mask = try Self.select(rows: rowsForSources(live), of: maskTensor, elementSize: 8, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)

        // Every beam starts from the same token; only the first may extend it at step 0,
        // or the beams would all be copies of one another.
        var searches = sources.map { source in
            Search(
                tokens: Array(repeating: [config.decoderStartTokenID], count: beams),
                scores: [0] + Array(repeating: -.infinity, count: beams - 1),
                finished: FinishedHypotheses(capacity: beams),
                maxNewTokens: min(config.maxPositions - 1, source.count * 3 + 10)
            )
        }
        var past: [String: ORTValue] = [:]
        var step = 0
        while !live.isEmpty {
            if stop?.isRaised == true { throw CancellationError() }
            let logits = try decodeStep(
                lastTokens: live.flatMap { searches[$0].tokens.map { Int64($0.last!) } },
                step: step, hidden: hidden, mask: mask, past: &past
            )
            let vocabulary = try logits.shape().last ?? 0
            let rows = try logits.mutableData(as: Float.self)

            var origins: [Int] = []
            var stillLive: [Int] = []
            for (block, source) in live.enumerated() {
                let firstRow = block * beams
                if let beamOrigins = advance(&searches[source], rows: rows + firstRow * vocabulary,
                                             vocabulary: vocabulary, step: step) {
                    origins += beamOrigins.map { firstRow + $0 }
                    stillLive.append(source)
                }
            }
            if stillLive != live {
                // A source finished: drop its rows everywhere, the cross-attention cache
                // and encoder output included.
                let kept = live.enumerated().filter { stillLive.contains($0.element) }
                    .flatMap { block, _ in (0..<beams).map { block * beams + $0 } }
                for (name, value) in past where name.contains(".encoder.") {
                    past[name] = try Self.select(rows: kept, of: value, elementSize: 4, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
                }
                hidden = try Self.select(rows: kept, of: hidden, elementSize: 4, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
                mask = try Self.select(rows: kept, of: mask, elementSize: 8, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
            }
            if !origins.isEmpty, origins != Array(0..<origins.count) || origins.count != live.count * beams {
                // Self-attention rows follow the beams they now continue.
                for (name, value) in past where name.contains(".decoder.") {
                    past[name] = try Self.select(rows: origins, of: value, elementSize: 4, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
                }
            }
            live = stillLive
            step += 1
        }
        return searches.map { Array(($0.result ?? $0.tokens[0]).dropFirst()) }
    }

    /// One step of one source's beam search: picks the next beams from its rows of
    /// logits. Returns, for each new beam, the beam it continues; or nil once the search
    /// is over, with `search.result` set.
    private func advance(
        _ search: inout Search, rows: UnsafeMutablePointer<Float>, vocabulary: Int, step: Int
    ) -> [Int]? {
        let config = configuration
        let beams = beamWidth
        var candidates: [(beam: Int, token: Int, score: Float)] = []
        candidates.reserveCapacity(beams * beams * 2)
        for beam in 0..<beams where search.scores[beam] > -.infinity {
            let row = rows + beam * vocabulary
            row[config.padTokenID] = -.infinity
            let logNormalizer = Self.logSumExp(row, count: vocabulary)
            for (token, logit) in Self.top(2 * beams, of: row, count: vocabulary) {
                candidates.append((beam, token, search.scores[beam] + logit - logNormalizer))
            }
        }
        candidates.sort { $0.score > $1.score }

        var tokens: [[Int]] = []
        var scores: [Float] = []
        var origins: [Int] = []
        for (rank, candidate) in candidates.enumerated() {
            if candidate.token == config.eosTokenID {
                // As in transformers: an ending counts only if it ranks among the top
                // `beams` candidates; otherwise it would crowd out live beams.
                if rank < beams {
                    search.finished.add(search.tokens[candidate.beam], score: candidate.score, length: step + 1)
                }
            } else {
                tokens.append(search.tokens[candidate.beam] + [candidate.token])
                scores.append(candidate.score)
                origins.append(candidate.beam)
            }
            if tokens.count == beams { break }
        }
        let outOfSteps = step + 1 >= search.maxNewTokens
        if outOfSteps {
            for (beam, score) in scores.enumerated() {
                search.finished.add(tokens[beam], score: score, length: step + 1)
            }
        }
        guard let bestLive = scores.first, !outOfSteps,
              !search.finished.isDone(bestLiveScore: bestLive, length: step + 1)
        else {
            search.result = search.finished.best ?? tokens.first ?? search.tokens[0]
            return nil
        }
        while tokens.count < beams {
            // Too few live candidates to fill the beam: pad it with dead ones.
            tokens.append(tokens[0])
            scores.append(-.infinity)
            origins.append(origins[0])
        }
        search.tokens = tokens
        search.scores = scores
        return origins
    }

    /// Runs one decoder step and returns the logits, updating the cache in place.
    private func decodeStep(
        lastTokens: [Int64], step: Int, hidden: ORTValue, mask: ORTValue, past: inout [String: ORTValue]
    ) throws -> ORTValue {
        let rows = lastTokens.count
        let session: ORTSession
        var inputs: [(name: String, value: ORTValue)] = [
            ("input_ids", try .int64(lastTokens, shape: [rows, 1])),
            ("encoder_attention_mask", mask),
            ("encoder_hidden_states", hidden),
        ]
        switch decoder {
        case .merged(let merged):
            session = merged
            inputs.append(("use_cache_branch", try .bool(step > 0)))
            if step == 0 {
                let empty = try ORTValue(
                    shape: [rows, configuration.heads, 0, configuration.headDimension],
                    type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
                )
                for name in merged.inputNames where name.hasPrefix("past_key_values.") {
                    past[name] = empty
                }
            }
        case .split(let first, let withPast):
            session = step == 0 ? first : withPast
        }
        for name in session.inputNames where name.hasPrefix("past_key_values.") {
            guard let value = past[name] else { throw OnnxRuntimeError(description: "Missing cache input \(name)") }
            inputs.append((name, value))
        }
        inputs.removeAll { !session.inputNames.contains($0.name) }

        let outputNames = session.outputNames
        let outputs = try session.run(inputs, outputs: outputNames)
        var logits: ORTValue?
        for (name, value) in zip(outputNames, outputs) {
            if name == "logits" {
                logits = value
            } else if name.hasPrefix("present.") {
                // The cross-attention cache is computed once, from the encoder output. Later
                // steps of a merged decoder emit empty placeholders for it, to be ignored.
                if name.contains(".encoder.") && step > 0 { continue }
                past["past_key_values." + name.dropFirst("present.".count)] = value
            }
        }
        guard let logits else { throw OnnxRuntimeError(description: "Decoder produced no logits") }
        return logits
    }

    /// A tensor made of the given rows (first-dimension entries) of `value`, in order.
    private static func select(
        rows: [Int], of value: ORTValue, elementSize: Int, type: ONNXTensorElementDataType
    ) throws -> ORTValue {
        var shape = try value.shape()
        let rowBytes = shape.dropFirst().reduce(1, *) * elementSize
        shape[0] = rows.count
        let selected = try ORTValue(shape: shape, type: type)
        let source = UnsafeMutableRawPointer(try value.mutableData(as: UInt8.self))
        let destination = UnsafeMutableRawPointer(try selected.mutableData(as: UInt8.self))
        for (index, row) in rows.enumerated() where rowBytes > 0 {
            (destination + index * rowBytes).copyMemory(from: source + row * rowBytes, byteCount: rowBytes)
        }
        return selected
    }

    /// log(Σ exp(x)), ignoring the -∞ entries.
    private static func logSumExp(_ row: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var maximum: Float = 0
        vDSP_maxv(row, 1, &maximum, vDSP_Length(count))
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { scratch.deallocate() }
        var negativeMax = -maximum
        vDSP_vsadd(row, 1, &negativeMax, scratch, 1, vDSP_Length(count))
        var n = Int32(count)
        vvexpf(scratch, scratch, &n)
        var sum: Float = 0
        vDSP_sve(scratch, 1, &sum, vDSP_Length(count))
        return maximum + log(sum)
    }

    /// The `k` largest entries, best first.
    private static func top(_ k: Int, of row: UnsafeMutablePointer<Float>, count: Int) -> [(Int, Float)] {
        var best: [(Int, Float)] = []
        best.reserveCapacity(k + 1)
        for index in 0..<count {
            let value = row[index]
            if best.count == k, value <= best[k - 1].1 { continue }
            let position = best.firstIndex { value > $0.1 } ?? best.count
            best.insert((index, value), at: position)
            if best.count > k { best.removeLast() }
        }
        return best
    }
}

/// The best finished translations so far, scored by average log-probability per token.
private struct FinishedHypotheses {
    let capacity: Int
    private(set) var entries: [(tokens: [Int], score: Float)] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func add(_ tokens: [Int], score: Float, length: Int) {
        let normalized = score / Float(max(1, length))
        guard entries.count < capacity || normalized > entries[entries.count - 1].score else { return }
        let position = entries.firstIndex { normalized > $0.score } ?? entries.count
        entries.insert((tokens, normalized), at: position)
        if entries.count > capacity { entries.removeLast() }
    }

    /// Whether no live beam can still beat the worst kept translation.
    func isDone(bestLiveScore: Float, length: Int) -> Bool {
        guard entries.count == capacity, let worst = entries.last else { return false }
        return worst.score >= bestLiveScore / Float(max(1, length))
    }

    var best: [Int]? { entries.first?.tokens }
}
