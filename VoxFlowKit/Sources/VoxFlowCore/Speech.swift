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
    /// Tail of the text recognized so far, so whisper conditions the next window on it (phase 3 windows).
    public var promptContext: String?

    public init(language: String? = nil, vocabulary: [String] = [], threadCount: Int? = nil,
                noSpeechThreshold: Double = 0.6, promptContext: String? = nil) {
        self.language = language
        self.vocabulary = vocabulary
        self.threadCount = threadCount
        self.noSpeechThreshold = noSpeechThreshold
        self.promptContext = promptContext
    }

    /// I2: whisper's initial-prompt budget is small (~`n_text_ctx/2` tokens); `promptContext` (the
    /// phase-3 window continuation) goes first and is truncated to its last 200 characters so it
    /// always survives, then `vocabulary` words are appended in order up to a 400-character budget
    /// — a word that would push the vocabulary section past that budget is dropped, along with every
    /// word after it, rather than truncating mid-word.
    public var initialPrompt: String? {
        let contextTail = 200
        let vocabularyBudget = 400

        let context = promptContext.map { String($0.suffix(contextTail)) }.flatMap { $0.isEmpty ? nil : $0 }

        var vocabularySection = ""
        for word in vocabulary {
            let candidate = vocabularySection.isEmpty ? word : "\(vocabularySection), \(word)"
            guard candidate.count <= vocabularyBudget else { break }
            vocabularySection = candidate
        }

        let parts = [context, vocabularySection.isEmpty ? nil : vocabularySection].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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
    /// after the loop. Decided in ADR-003: consumers check `Task.isCancelled` after the loop.
    func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error>
}
