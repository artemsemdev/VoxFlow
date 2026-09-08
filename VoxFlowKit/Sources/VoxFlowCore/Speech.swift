import Foundation

/// Result of language auto-detection. Below `lowConfidenceThreshold` the UI shows "EN?" (design 3e).
public struct LanguageDetection: Sendable, Equatable {
    public static let lowConfidenceThreshold = 0.6

    public var code: String
    public var confidence: Double

    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }

    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

/// Per-run knobs for a `SpeechEngine`.
public struct TranscriptionOptions: Sendable, Equatable {
    /// ISO 639-1 code, or nil to auto-detect.
    public var language: String?
    /// Dictionary words the engine should be biased towards (becomes the initial prompt).
    public var vocabulary: [String]
    /// nil lets the engine pick.
    public var threadCount: Int?
    /// Segments whose no-speech probability exceeds this are dropped.
    public var noSpeechThreshold: Double

    public init(language: String? = nil, vocabulary: [String] = [], threadCount: Int? = nil, noSpeechThreshold: Double = 0.6) {
        self.language = language
        self.vocabulary = vocabulary
        self.threadCount = threadCount
        self.noSpeechThreshold = noSpeechThreshold
    }

    public var initialPrompt: String? {
        vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")
    }
}

/// Events streamed while transcribing.
public enum SegmentEvent: Sendable, Equatable {
    /// A finalized segment, in order.
    case segment(TranscriptSegment)
    /// Fraction of the audio processed, 0...1.
    case progress(Double)
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(code: Int32)
    case cancelled
}

/// A speech-to-text backend. Implementations own their model in memory; one transcription at a time.
public protocol SpeechEngine: Sendable {
    func load(modelAt url: URL) async throws
    func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection
    /// Streams final segments and progress; finishes when the audio is consumed.
    /// One run at a time per engine: concurrent calls queue behind each other.
    /// Cancellation: if the consuming task is already cancelled when iteration starts, the stream
    /// throws `SpeechEngineError.cancelled`. If it is cancelled mid-run, the engine aborts promptly
    /// but `AsyncThrowingStream` may end the iteration without an error — check `Task.isCancelled`
    /// after the loop. Tracked in issue #125.
    func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error>
}
