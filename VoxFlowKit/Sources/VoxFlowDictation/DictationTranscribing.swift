import Foundation
import VoxFlowCore

public enum DictationEvent: Sendable, Equatable {
    case language(LanguageDetection)
    /// All text recognized so far (not a delta).
    case partialText(String)
}

public struct DictationResult: Sendable, Equatable {
    public var text: String
    /// Engine output before any cleanup. Identical to `text` until phase 5 adds styles.
    public var rawText: String
    public var segments: [TranscriptSegment]
    public var language: LanguageDetection?
    public var duration: TimeInterval
    public var lowConfidence: Bool

    public init(text: String, rawText: String, segments: [TranscriptSegment], language: LanguageDetection?,
                duration: TimeInterval, lowConfidence: Bool) {
        self.text = text
        self.rawText = rawText
        self.segments = segments
        self.language = language
        self.duration = duration
        self.lowConfidence = lowConfidence
    }

    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    public static let empty = DictationResult(text: "", rawText: "", segments: [], language: nil, duration: 0, lowConfidence: false)
}

public enum DictationError: Error, Equatable, Sendable {
    case cancelled
    case engineFailed(String)
}

/// Turns a live chunk feed into text. Returns when the feed ends; throws `.cancelled` when the task is cancelled.
public protocol DictationTranscribing: Sendable {
    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult
}
