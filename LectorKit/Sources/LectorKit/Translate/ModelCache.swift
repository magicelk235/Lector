import Foundation
import Synchronization

/// Loaded models by name, least recently used first.
///
/// Each Opus-MT model holds a few hundred megabytes, so at most `capacity` are kept
/// between uses, and all of them are let go once nothing has asked for one for
/// `idleTimeout`. Letting go only stops keeping a model: a translation that still holds
/// one finishes with it, and the next one to ask loads it again.
final class ModelCache<Model: Sendable>: Sendable {
    private struct Entry {
        let name: String
        let task: Task<Model, any Error>
    }

    private struct State {
        var entries: [Entry] = []
        var lastUse = ContinuousClock.now
        var watchingIdle = false
    }

    private let capacity: Int
    private let idleTimeout: Duration
    private let state = Mutex(State())
    /// Runs each time the cache has let go of models, once it has dropped them.
    private let onRelease: @Sendable () -> Void

    init(capacity: Int, idleTimeout: Duration, onRelease: @escaping @Sendable () -> Void = {}) {
        self.capacity = max(1, capacity)
        self.idleTimeout = idleTimeout
        self.onRelease = onRelease
    }

    /// The model called `name`, loaded with `load` unless it is loaded already or being
    /// loaded for someone else.
    func model(named name: String, load: @escaping @Sendable () throws -> Model) async throws -> Model {
        // An evicted model is dropped once the lock is let go, since freeing one takes a
        // while and nothing else needs to wait for it.
        let (task, startWatching, evicted) = state.withLock { state in
            state.lastUse = .now
            let startWatching = !state.watchingIdle
            state.watchingIdle = true
            if let index = state.entries.firstIndex(where: { $0.name == name }) {
                let entry = state.entries.remove(at: index)
                state.entries.append(entry)
                return (entry.task, startWatching, Entry?.none)
            }
            let task = Task.detached(priority: .userInitiated) { try load() }
            state.entries.append(Entry(name: name, task: task))
            let evicted = state.entries.count > capacity ? state.entries.removeFirst() : nil
            return (task, startWatching, evicted)
        }
        if evicted != nil {
            _ = consume evicted
            onRelease()
        }
        if startWatching {
            Task.detached(priority: .utility) { await self.unloadWhenIdle() }
        }
        do {
            return try await task.value
        } catch {
            state.withLock { $0.entries.removeAll { $0.task == task } }
            throw error
        }
    }

    /// What is loaded, least recently used first.
    var loadedNames: [String] {
        state.withLock { $0.entries.map(\.name) }
    }

    func remove(named name: String) {
        let removed = state.withLock { state in
            defer { state.entries.removeAll { $0.name == name } }
            return state.entries.filter { $0.name == name }
        }
        _ = consume removed
        onRelease()
    }

    func removeAll() {
        let removed = state.withLock { state in
            defer { state.entries = [] }
            return state.entries
        }
        _ = consume removed
        onRelease()
    }

    /// Sleeps until `idleTimeout` has passed since the last use, then lets everything go.
    /// One of these runs at a time, and only while something has been used since the
    /// last time it emptied the cache, so an idle app has no timer at all.
    private func unloadWhenIdle() async {
        while true {
            let (wait, removed): (Duration?, [Entry]) = state.withLock { state in
                let idle = ContinuousClock.now - state.lastUse
                guard idle < idleTimeout else {
                    defer { state.entries = [] }
                    state.watchingIdle = false
                    return (nil, state.entries)
                }
                return (idleTimeout - idle, [])
            }
            guard let wait else {
                _ = consume removed
                return onRelease()
            }
            try? await Task.sleep(for: wait)
        }
    }
}
