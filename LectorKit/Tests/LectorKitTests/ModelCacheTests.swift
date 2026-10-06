import Synchronization
import XCTest
@testable import LectorKit

/// Which loaded models stay in memory: a few between uses, none once the app is idle,
/// and whatever was let go loads again when next asked for.
final class ModelCacheTests: XCTestCase {
    private final class Model: Sendable {
        let name: String
        init(_ name: String) { self.name = name }
    }

    private final class Loads: Sendable {
        private let counts = Mutex<[String: Int]>([:])
        func count(_ name: String) -> Int { counts.withLock { $0[name, default: 0] } }
        func loader(_ name: String) -> @Sendable () throws -> Model {
            { [self] in
                counts.withLock { $0[name, default: 0] += 1 }
                return Model(name)
            }
        }
    }

    func testKeepsOnlyTheMostRecentlyUsed() async throws {
        let cache = ModelCache<Model>(capacity: 2, idleTimeout: .seconds(60))
        let loads = Loads()
        for name in ["a", "b", "a", "c"] {
            _ = try await cache.model(named: name, load: loads.loader(name))
        }
        XCTAssertEqual(cache.loadedNames, ["a", "c"], "b was the least recently used")
        XCTAssertEqual(loads.count("a"), 1, "a was still loaded the second time")
    }

    /// Once the cache lets go and nothing else holds it, the model's memory is freed.
    func testEvictedModelIsReleasedAndLoadsAgain() async throws {
        let cache = ModelCache<Model>(capacity: 1, idleTimeout: .seconds(60))
        let loads = Loads()
        weak var first: Model?
        first = try await cache.model(named: "a", load: loads.loader("a"))
        _ = try await cache.model(named: "b", load: loads.loader("b"))
        XCTAssertNil(first, "nothing keeps an evicted model alive")

        let again = try await cache.model(named: "a", load: loads.loader("a"))
        XCTAssertEqual(again.name, "a")
        XCTAssertEqual(loads.count("a"), 2)
    }

    func testIdleCacheLetsEverythingGo() async throws {
        let cache = ModelCache<Model>(capacity: 4, idleTimeout: .milliseconds(150))
        let loads = Loads()
        weak var held: Model?
        held = try await cache.model(named: "a", load: loads.loader("a"))
        _ = try await cache.model(named: "b", load: loads.loader("b"))
        XCTAssertNotNil(held)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(cache.loadedNames, [])
        XCTAssertNil(held)

        // Used again after the unload: loaded afresh, then let go again once idle.
        let model = try await cache.model(named: "a", load: loads.loader("a"))
        XCTAssertEqual(model.name, "a")
        XCTAssertEqual(loads.count("a"), 2)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(cache.loadedNames, [])
    }

    /// Steady use keeps the idle timer from firing.
    func testUseKeepsModelsLoaded() async throws {
        let cache = ModelCache<Model>(capacity: 2, idleTimeout: .milliseconds(400))
        let loads = Loads()
        for _ in 0..<6 {
            _ = try await cache.model(named: "a", load: loads.loader("a"))
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(cache.loadedNames, ["a"])
        XCTAssertEqual(loads.count("a"), 1)
    }

    func testFailedLoadIsNotKept() async throws {
        struct Broken: Error {}
        let cache = ModelCache<Model>(capacity: 2, idleTimeout: .seconds(60))
        do {
            _ = try await cache.model(named: "a") { throw Broken() }
            XCTFail("loaded a broken model")
        } catch {}
        XCTAssertEqual(cache.loadedNames, [])
    }
}
