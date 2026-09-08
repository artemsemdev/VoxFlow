import Foundation
import VoxFlowCore

/// Pure mapping from `TranscriptionOptions` to the values handed to whisper.cpp; testable without a model.
struct WhisperParameters: Equatable {
    static let maxThreads = 16
    /// Metal does the heavy lifting; more CPU threads than this only burn power (spike, 2026-09-08).
    static let defaultThreadCap = 8

    let language: String?
    let threadCount: Int
    let initialPrompt: String?
    let noSpeechThreshold: Float

    init(options: TranscriptionOptions, availableCores: Int) {
        language = options.language
        let requested = options.threadCount ?? min(availableCores, Self.defaultThreadCap)
        threadCount = min(max(requested, 1), Self.maxThreads)
        initialPrompt = options.initialPrompt
        noSpeechThreshold = Float(options.noSpeechThreshold)
    }
}
