import XCTest
@testable import LectorKit

/// The memory ONNX Runtime's tensors live in: aligned as it asks, usable to the last
/// byte, on either side of the size where blocks start being mapped.
final class TensorMemoryTests: XCTestCase {
    func testBlocksAreAlignedAndUsable() throws {
        for size in [2, 100, 64 * 1024, (1 << 20) - 1, 1 << 20, 5 * (1 << 20) + 3, 40 << 20] {
            let block = try XCTUnwrap(TensorMemory.allocate(size), "\(size) bytes")
            XCTAssertEqual(Int(bitPattern: block) % 64, 0, "\(size) bytes")
            let bytes = block.bindMemory(to: UInt8.self, capacity: size)
            bytes[0] = 1
            bytes[size - 1] = 2
            XCTAssertEqual(bytes[0] + bytes[size - 1], 3)
            TensorMemory.free(block)
        }
        TensorMemory.releaseSpares()
    }

    /// A freed large block serves the next request of about its size, as the decoder's
    /// steps make, instead of mapping fresh pages each time.
    func testFreedLargeBlockIsReused() throws {
        let first = try XCTUnwrap(TensorMemory.allocate(3 << 20))
        TensorMemory.free(first)
        let second = try XCTUnwrap(TensorMemory.allocate((3 << 20) + 4096))
        XCTAssertEqual(first, second)
        TensorMemory.free(second)
        TensorMemory.releaseSpares()
    }
}
