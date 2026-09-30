import CryptoKit
import Foundation
import Synchronization

/// Fetches one file over HTTP into a local path, continuing from whatever part of it is
/// already there.
///
/// A delegate-driven data task rather than `URLSession.download`, because a download task
/// only resumes from an opaque blob that dies with the process, while an interrupted model
/// download should pick up where it stopped the next time the user asks, even after a
/// relaunch. Bytes go straight to disk, so a 100 MB model never sits in memory.
final class ResumableFileDownload: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var handle: FileHandle?
        var received: Int64 = 0
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void
    private let state = Mutex(State())

    /// `onBytes` hears how many bytes of the file are on disk after each chunk, starting
    /// with whatever an earlier attempt left behind.
    private init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    static func fetch(
        _ url: URL, to destination: URL, expectedBytes: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let manager = FileManager.default
        var existing = (try? manager.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? 0
        if existing > expectedBytes {
            try? manager.removeItem(at: destination)
            existing = 0
        }
        if existing == expectedBytes {
            onBytes(existing)
            return
        }
        if existing == 0 {
            manager.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        }

        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let download = ResumableFileDownload(destination: destination, onBytes: onBytes)
        download.state.withLock { $0.received = existing }
        onBytes(existing)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                download.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let accepted: Bool = state.withLock { state in
            do {
                let handle = try FileHandle(forWritingTo: destination)
                switch status {
                case 206:
                    // The server honoured the range: carry on from the end.
                    try handle.seekToEnd()
                case 200:
                    // A full body, whether or not a range was asked for: start over.
                    try handle.truncate(atOffset: 0)
                    state.received = 0
                default:
                    try? handle.close()
                    state.failure = OpusMTError.downloadFailed("HTTP \(status) for \(response.url?.lastPathComponent ?? "file")")
                    return false
                }
                state.handle = handle
                return true
            } catch {
                state.failure = error
                return false
            }
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let received: Int64? = state.withLock { state in
            guard let handle = state.handle, state.failure == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
                state.received += Int64(data.count)
                return state.received
            } catch {
                state.failure = error
                dataTask.cancel()
                return nil
            }
        }
        if let received { onBytes(received) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure): (CheckedContinuation<Void, any Error>?, (any Error)?) = state.withLock { state in
            try? state.handle?.synchronize()
            try? state.handle?.close()
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            let cancelled = (error as? URLError)?.code == .cancelled
            return (continuation, state.failure ?? (cancelled ? CancellationError() : error))
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }

    /// The SHA-256 of a file, read in chunks so a large model is never loaded whole.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
