import Foundation
import VoxFlowCore

/// Scripted `FileTranscribing`: per-URL result or error, optional gate to hold a job mid-way.
public actor FakeFileTranscriber: FileTranscribing {
    public enum Script: Sendable { case document(TranscriptDocument), failure(FileTranscriptionError) }

    private var scripts: [URL: Script] = [:]
    private var gates: [URL: CheckedContinuation<Void, any Error>] = [:]
    private var holdURLs: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    public private(set) var calls: [URL] = []
    public var progressSteps: [Double] = [0.25, 0.5, 0.75]

    public init() {}

    public func script(_ url: URL, _ script: Script) { scripts[url] = script }
    public func setProgressSteps(_ steps: [Double]) { progressSteps = steps }
    /// Hold the next job for `url` after reporting `progressSteps`, until `release(url)` or cancellation.
    public func hold(_ url: URL) { holdURLs.insert(url) }
    public func waitUntilHeld(_ url: URL) async {
        if gates[url] != nil { return }
        await withCheckedContinuation { waiters[url, default: []].append($0) }
    }
    public func release(_ url: URL) { gates.removeValue(forKey: url)?.resume() }

    public func transcribe(_ url: URL, options: TranscriptionOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        calls.append(url)
        for step in progressSteps {
            try Task.checkCancellation()
            progress(step)
        }
        if holdURLs.remove(url) != nil { try await park(url) }
        switch scripts[url] {
        case .document(let document)?: return document
        case .failure(let error)?: throw error
        case nil: throw FileTranscriptionError.engineFailed("no script for \(url.lastPathComponent)")
        }
    }

    private func park(_ url: URL) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                gates[url] = continuation
                waiters.removeValue(forKey: url)?.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelGate(url) }
        }
    }

    private func cancelGate(_ url: URL) { gates.removeValue(forKey: url)?.resume(throwing: CancellationError()) }
}
