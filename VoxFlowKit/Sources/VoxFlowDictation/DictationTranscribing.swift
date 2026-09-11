import Foundation
import VoxFlowCore

public enum DictationEvent: Sendable, Equatable {
    case language(LanguageDetection)
    /// All text recognized so far (not a delta).
    case partialText(String)
}

public struct DictationResult: Sendable, Equatable {
    public var text: String
    /// Engine output before any cleanup. Identical to `text` until `StyledTranscriber` (phase 4a) styles it.
    public var rawText: String
    public var segments: [TranscriptSegment]
    public var language: LanguageDetection?
    public var duration: TimeInterval
    public var lowConfidence: Bool
    /// The resolved `TextStyle.rawValue` (phase 4a), set by `StyledTranscriber`; `nil` on a base
    /// transcriber's own result (before styling runs) or in a test fixture that never sets it.
    public var style: String?
    /// Swift Character offset of the snippet `cursor` placeholder within the final `text`.
    public var cursorOffset: Int?
    /// How many filler occurrences were removed producing `text` from `rawText`.
    public var fillersRemoved: Int

    public init(text: String, rawText: String, segments: [TranscriptSegment], language: LanguageDetection?,
                duration: TimeInterval, lowConfidence: Bool, style: String? = nil, cursorOffset: Int? = nil, fillersRemoved: Int = 0) {
        self.text = text
        self.rawText = rawText
        self.segments = segments
        self.language = language
        self.duration = duration
        self.lowConfidence = lowConfidence
        self.style = style
        self.cursorOffset = cursorOffset
        self.fillersRemoved = fillersRemoved
    }

    public var wordCount: Int { text.wordCount }
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
