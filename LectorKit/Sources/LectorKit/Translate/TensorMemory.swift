import COnnxRuntime
import Darwin
import Synchronization

/// Where ONNX Runtime's tensors live: registered with the environment as its CPU
/// allocator, so every session's weights and working memory come from here.
///
/// Large blocks are mapped from the system directly and unmapped when no longer wanted.
/// Through `malloc` they weren't given back: freed large blocks wait in its cache for
/// reuse or for the kernel to reclaim them, and with every model let go the app stayed
/// 215 MB over its idle size after four languages, against 50 MB from here (measured).
///
/// The decoder frees and asks again for blocks of much the same size at every step
/// (logits, outputs), and a fresh mapping costs page faults each time: a long page took
/// 5–10% longer. So freed blocks are kept for reuse, sized in classes a quarter of a
/// power of two apart so a step a token longer still fits, up to `spareLimit`, until
/// `releaseSpares` hands them back once the models are let go. That brought it within
/// 1% of `malloc`.
enum TensorMemory {
    /// Every block starts this far before the pointer handed out, which keeps the 64-byte
    /// alignment ONNX Runtime asks for and holds the block's mapped length (0 for one from
    /// `malloc`).
    private static let header = 64
    /// From here up, blocks are mapped. Weight matrices are 1–140 MB each; what is
    /// smaller is mostly short-lived and cheaper to leave to `malloc`.
    private static let mappedFrom = 1 << 20
    private static let spareLimit = 256 << 20
    /// Freed mapped blocks by length, as addresses.
    private static let spares = Mutex<(blocks: [Int: [UInt]], bytes: Int)>(([:], 0))

    static func allocate(_ size: Int) -> UnsafeMutableRawPointer? {
        let total = size + header
        if size >= mappedFrom {
            let length = sizeClass(total)
            let spare = spares.withLock { spares -> UInt? in
                guard let address = spares.blocks[length]?.popLast() else { return nil }
                spares.bytes -= length
                return address
            }
            if let spare, let base = UnsafeMutableRawPointer(bitPattern: spare) {
                return base + header
            }
            let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            guard let base, base != MAP_FAILED else { return nil }
            base.storeBytes(of: length, as: Int.self)
            return base + header
        }
        var base: UnsafeMutableRawPointer?
        guard posix_memalign(&base, header, total) == 0, let base else { return nil }
        base.storeBytes(of: 0, as: Int.self)
        return base + header
    }

    static func free(_ pointer: UnsafeMutableRawPointer?) {
        guard let pointer else { return }
        let base = pointer - header
        let length = base.load(as: Int.self)
        guard length > 0 else { return Darwin.free(base) }
        let kept = spares.withLock { spares in
            guard spares.bytes + length <= spareLimit else { return false }
            spares.blocks[length, default: []].append(UInt(bitPattern: base))
            spares.bytes += length
            return true
        }
        if !kept { munmap(base, length) }
    }

    /// Unmaps every block kept for reuse: for when the models have been let go.
    static func releaseSpares() {
        let blocks = spares.withLock { spares in
            defer { spares = ([:], 0) }
            return spares.blocks
        }
        for (length, addresses) in blocks {
            for address in addresses {
                munmap(UnsafeMutableRawPointer(bitPattern: address), length)
            }
        }
    }

    /// `bytes` rounded up to a quarter of the power of two below it, in whole pages.
    private static func sizeClass(_ bytes: Int) -> Int {
        let step = max(Int(getpagesize()), (1 << (Int.bitWidth - 1 - bytes.leadingZeroBitCount)) / 4)
        return (bytes + step - 1) / step * step
    }

    /// The allocator, for ONNX Runtime to call. Never freed: the environment it is
    /// registered with lives as long as the process.
    nonisolated(unsafe) static let allocator: UnsafeMutablePointer<OrtAllocator> = {
        let allocator = UnsafeMutablePointer<OrtAllocator>.allocate(capacity: 1)
        allocator.initialize(to: OrtAllocator())
        allocator.pointee.version = UInt32(ORT_API_VERSION)
        allocator.pointee.Alloc = { _, size in TensorMemory.allocate(size) }
        allocator.pointee.Free = { _, pointer in TensorMemory.free(pointer) }
        allocator.pointee.Info = { _ in TensorMemory.memoryInfo }
        allocator.pointee.Reserve = { _, size in TensorMemory.allocate(size) }
        return allocator
    }()

    /// Registers `allocator` as the CPU allocator of `environment`. Sessions use it once
    /// they set `session.use_env_allocators`.
    static func register(with environment: OpaquePointer) throws {
        guard memoryInfo != nil else { throw OnnxRuntimeError(description: "CreateCpuMemoryInfo returned nothing") }
        try OnnxRuntime.check(OnnxRuntime.api.RegisterAllocator(environment, allocator))
    }

    /// Describes `allocator` as ordinary CPU memory, which is what lets the sessions'
    /// CPU kernels use it. Made once, and only read after: the C callbacks can't capture.
    nonisolated(unsafe) private static let memoryInfo: OpaquePointer? = {
        var info: OpaquePointer?
        guard (try? OnnxRuntime.check(OnnxRuntime.api.CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &info)))
            != nil else { return nil }
        return info
    }()
}
