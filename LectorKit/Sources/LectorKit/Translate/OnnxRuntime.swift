import COnnxRuntime
import Foundation

/// A thin Swift layer over ONNX Runtime's C API: just the calls the Marian models need.
///
/// The C API rather than Microsoft's Objective-C bindings because the merged decoder takes
/// a `bool` tensor (`use_cache_branch`), which the Objective-C tensor types cannot express.
struct OnnxRuntimeError: Error, CustomStringConvertible {
    let description: String
}

enum OnnxRuntime {
    /// The function table: static memory inside the linked library, readable from any
    /// thread.
    static let api: OrtApi = {
        guard let api = HLOrtApi() else {
            fatalError("The linked ONNX Runtime does not provide API version \(ORT_API_VERSION)")
        }
        return api.pointee
    }()

    static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
        api.ReleaseStatus(status)
        throw OnnxRuntimeError(description: message)
    }

    /// One environment and one thread pool for the whole process. Every session opts out
    /// of a pool of its own, so a pivot through two models does not start two sets of
    /// threads.
    static let environment: Result<Environment, OnnxRuntimeError> = {
        do {
            return .success(try Environment())
        } catch let error as OnnxRuntimeError {
            return .failure(error)
        } catch {
            return .failure(OnnxRuntimeError(description: "\(error)"))
        }
    }()

    /// An `OrtEnv`, created once and never released: ONNX Runtime requires it to outlive
    /// every session, and a model can be loaded again at any time.
    final class Environment: @unchecked Sendable {
        let handle: OpaquePointer

        fileprivate init() throws {
            var threading: OpaquePointer?
            try check(api.CreateThreadingOptions(&threading))
            defer { api.ReleaseThreadingOptions(threading) }
            try check(api.SetGlobalIntraOpNumThreads(threading, Int32(Self.threadCount)))
            // Spinning keeps cores busy for a while after every call. This app idles far
            // more than it translates, so waking the pool is the cheaper side of that.
            try check(api.SetGlobalSpinControl(threading, 0))
            var environment: OpaquePointer?
            try check(api.CreateEnvWithGlobalThreadPools(ORT_LOGGING_LEVEL_ERROR, "Lector", threading, &environment))
            guard let environment else { throw OnnxRuntimeError(description: "CreateEnv returned nothing") }
            handle = environment
            try TensorMemory.register(with: environment)
        }

        /// The performance cores. Handing part of a small matrix multiply to an
        /// efficiency core makes every step wait for the slowest thread.
        private static var threadCount: Int {
            var cores: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
                cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
            }
            return max(1, min(Int(cores), 8))
        }
    }
}

/// An owned `OrtValue`. Tensors are allocated by ONNX Runtime, so the memory lives exactly
/// as long as this object does. Not shared between threads.
final class ORTValue {
    let handle: OpaquePointer

    init(owning handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        OnnxRuntime.api.ReleaseValue(handle)
    }

    /// A tensor with uninitialised contents. These are the decoder's own per-step tensors,
    /// left to ONNX Runtime's default allocator: through `TensorMemory` a long page took
    /// 2–3% longer for no memory measurably given back.
    convenience init(shape: [Int], type: ONNXTensorElementDataType) throws {
        let api = OnnxRuntime.api
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try OnnxRuntime.check(api.GetAllocatorWithDefaultOptions(&allocator))
        let dimensions = shape.map(Int64.init)
        var value: OpaquePointer?
        try OnnxRuntime.check(api.CreateTensorAsOrtValue(allocator, dimensions, dimensions.count, type, &value))
        guard let value else { throw OnnxRuntimeError(description: "CreateTensor returned nothing") }
        self.init(owning: value)
    }

    static func int64(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let tensor = try ORTValue(shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        try tensor.write(values)
        return tensor
    }

    static func bool(_ value: Bool) throws -> ORTValue {
        let tensor = try ORTValue(shape: [1], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL)
        try tensor.write([value])
        return tensor
    }

    private func write<T>(_ values: [T]) throws {
        let destination = try mutableData(as: T.self)
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            destination.update(from: base, count: buffer.count)
        }
    }

    func mutableData<T>(as type: T.Type) throws -> UnsafeMutablePointer<T> {
        var raw: UnsafeMutableRawPointer?
        try OnnxRuntime.check(OnnxRuntime.api.GetTensorMutableData(handle, &raw))
        guard let raw else {
            // Only an empty tensor has no storage, and nothing is read from one.
            return UnsafeMutablePointer<T>(bitPattern: MemoryLayout<T>.alignment)!
        }
        return raw.assumingMemoryBound(to: T.self)
    }

    func shape() throws -> [Int] {
        let api = OnnxRuntime.api
        var info: OpaquePointer?
        try OnnxRuntime.check(api.GetTensorTypeAndShape(handle, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var count = 0
        try OnnxRuntime.check(api.GetDimensionsCount(info, &count))
        var dimensions = [Int64](repeating: 0, count: count)
        try OnnxRuntime.check(api.GetDimensions(info, &dimensions, count))
        return dimensions.map(Int.init)
    }
}

/// A loaded ONNX model. ONNX Runtime documents `Run` as safe to call concurrently on one
/// session, which is what makes sharing it between threads sound.
final class ORTSession: @unchecked Sendable {
    private let handle: OpaquePointer
    let inputNames: [String]
    let outputNames: [String]
    /// C copies of every name, made once so a decoding step does not allocate them.
    private let cNames: [String: UnsafeMutablePointer<CChar>]

    /// `dequantizeAtLoad` trades memory for speed in a model run many times per call:
    /// see below.
    init(modelPath: String, dequantizeAtLoad: Bool = false) throws {
        let api = OnnxRuntime.api
        let environment = try OnnxRuntime.environment.get()
        var options: OpaquePointer?
        try OnnxRuntime.check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try OnnxRuntime.check(api.DisablePerSessionThreads(options))
        // Weights and working memory from `TensorMemory`, which gives them back to the
        // system once the session is released.
        try OnnxRuntime.check(api.AddSessionConfigEntry(options, "session.use_env_allocators", "1"))
        try OnnxRuntime.check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        // The Opus-MT exports keep their weights quantized behind DequantizeLinear nodes,
        // which constant folding leaves alone while ONNX Runtime's QDQ optimisations are
        // on (it keeps the pairs for fusion). So every decoder step dequantized the whole
        // 67k × 512 shared embedding again before the output projection: a quarter to
        // two fifths of a translation, measured on an M4. With QDQ fusion off it is
        // dequantized once, at load, for about 300 MB more per model (440 → 780 MB for
        // de-en, measured). The dynamically quantized matmuls are unaffected. The encoder
        // runs once per batch and isn't worth the memory.
        if dequantizeAtLoad {
            try OnnxRuntime.check(api.AddSessionConfigEntry(options, "session.disable_quant_qdq", "1"))
        }

        var session: OpaquePointer?
        try OnnxRuntime.check(api.CreateSession(environment.handle, modelPath, options, &session))
        guard let session else { throw OnnxRuntimeError(description: "CreateSession returned nothing") }
        handle = session

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try OnnxRuntime.check(api.GetAllocatorWithDefaultOptions(&allocator))
        func names(
            count: (OpaquePointer?, UnsafeMutablePointer<Int>?) -> OpaquePointer?,
            name: (OpaquePointer?, Int, UnsafeMutablePointer<OrtAllocator>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer?
        ) throws -> [String] {
            var total = 0
            try OnnxRuntime.check(count(session, &total))
            return try (0..<total).map { index in
                var raw: UnsafeMutablePointer<CChar>?
                try OnnxRuntime.check(name(session, index, allocator, &raw))
                defer { _ = api.AllocatorFree(allocator, raw) }
                return raw.map { String(cString: $0) } ?? ""
            }
        }
        inputNames = try names(count: api.SessionGetInputCount, name: api.SessionGetInputName)
        outputNames = try names(count: api.SessionGetOutputCount, name: api.SessionGetOutputName)
        var cNames: [String: UnsafeMutablePointer<CChar>] = [:]
        for name in inputNames + outputNames where cNames[name] == nil {
            cNames[name] = strdup(name)
        }
        self.cNames = cNames
    }

    deinit {
        OnnxRuntime.api.ReleaseSession(handle)
        cNames.values.forEach { free($0) }
    }

    /// Runs the model and returns the named outputs, in the order asked for.
    func run(_ inputs: [(name: String, value: ORTValue)], outputs: [String]) throws -> [ORTValue] {
        let inputNames = try inputs.map { input -> UnsafePointer<CChar>? in
            guard let pointer = cNames[input.name] else { throw OnnxRuntimeError(description: "Model has no input \(input.name)") }
            return UnsafePointer(pointer)
        }
        let outputNames = try outputs.map { name -> UnsafePointer<CChar>? in
            guard let pointer = cNames[name] else { throw OnnxRuntimeError(description: "Model has no output \(name)") }
            return UnsafePointer(pointer)
        }
        let inputValues: [OpaquePointer?] = inputs.map { $0.value.handle }
        var results = [OpaquePointer?](repeating: nil, count: outputs.count)
        let status = OnnxRuntime.api.Run(handle, nil, inputNames, inputValues, inputs.count, outputNames, outputs.count, &results)
        // Own whatever came back before checking, so a failure part-way leaks nothing.
        let owned = results.map { $0.map(ORTValue.init(owning:)) }
        try withExtendedLifetime(inputs) { try OnnxRuntime.check(status) }
        return try owned.enumerated().map { index, value in
            guard let value else { throw OnnxRuntimeError(description: "Model produced no \(outputs[index])") }
            return value
        }
    }
}
