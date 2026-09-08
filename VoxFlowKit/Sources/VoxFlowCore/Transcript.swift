import Foundation

/// One timed piece of recognized speech. `start`/`end` are seconds from the beginning of the audio.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Average token probability 0…1 when the engine reports it.
    public var confidence: Double?

    /// Returns nil when `end` precedes `start`.
    public init?(start: TimeInterval, end: TimeInterval, text: String, confidence: Double? = nil) {
        guard end >= start else { return nil }
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }

    public var duration: TimeInterval { end - start }
}

/// The recognized text of one recording, as ordered segments.
public struct Transcript: Sendable, Equatable, Codable {
    public var segments: [TranscriptSegment]
    /// ISO 639-1 code of the detected or requested language, when known.
    public var language: String?

    public init(segments: [TranscriptSegment], language: String? = nil) {
        self.segments = segments
        self.language = language
    }

    public var duration: TimeInterval { segments.last?.end ?? 0 }

    public var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Segment texts trimmed and joined with single spaces.
    public var plainText: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
