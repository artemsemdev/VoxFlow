import Foundation

/// A stable range into a transcript's UTF-16 representation. UTF-16 offsets can be persisted and
/// reconstructed without storing a second copy of the user's words.
public struct RawTextSpan: Sendable, Equatable, Hashable, Codable {
    public var location: Int
    public var length: Int

    public init?(location: Int, length: Int) {
        guard location >= 0, length > 0 else { return nil }
        self.location = location
        self.length = length
    }

    public func range(in text: String) -> Range<String.Index>? {
        let count = text.utf16.count
        guard location >= 0, length > 0, location <= count, length <= count - location else { return nil }
        return Range(NSRange(location: location, length: length), in: text)
    }
}

/// Confidence derived from the actual whisper tokens that overlap one raw transcript word.
public struct WordConfidence: Sendable, Equatable, Codable {
    /// Canvas MW-02d treats 78% as uncertain. Keep this distinct from the lower whole-dictation
    /// retry threshold, which answers whether transcription failed rather than which words to flag.
    public static let lowConfidenceThreshold = 0.80
    public var span: RawTextSpan
    public var confidence: Double

    public init?(span: RawTextSpan, confidence: Double) {
        guard confidence.isFinite, (0...1).contains(confidence) else { return nil }
        self.span = span
        self.confidence = confidence
    }

    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

/// Audio-free annotations anchored only to the unchanged raw transcript. Each collection is
/// independently optional so old rows and later manual edits never imply metadata that was not
/// actually observed.
public struct DictationAnnotations: Sendable, Equatable, Codable {
    public var removedFillerSpans: [RawTextSpan]?
    public var wordConfidences: [WordConfidence]?

    public init(removedFillerSpans: [RawTextSpan]? = nil, wordConfidences: [WordConfidence]? = nil) {
        self.removedFillerSpans = removedFillerSpans
        self.wordConfidences = wordConfidences
    }

    public var fillersRemoved: Int? {
        guard let spans = removedFillerSpans,
              spans.allSatisfy(Self.isStructurallyValid),
              Self.areDistinctAndNonoverlapping(spans) else { return nil }
        return spans.count
    }

    /// Rejects a corrupt annotation as a unit rather than partially highlighting the wrong text.
    public func validated(for rawText: String) -> DictationAnnotations? {
        let spans = (removedFillerSpans ?? []) + (wordConfidences ?? []).map(\.span)
        guard spans.allSatisfy({ $0.range(in: rawText) != nil }) else { return nil }
        guard (wordConfidences ?? []).allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence) }) else { return nil }
        guard Self.areDistinctAndNonoverlapping(removedFillerSpans ?? []),
              Self.areDistinctAndNonoverlapping((wordConfidences ?? []).map(\.span)) else { return nil }
        return self
    }

    private static func areDistinctAndNonoverlapping(_ spans: [RawTextSpan]) -> Bool {
        let sorted = spans.sorted { $0.location < $1.location }
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            // Both spans were range-checked above, so this addition cannot overflow.
            if left.location + left.length > right.location { return false }
        }
        return true
    }

    private static func isStructurallyValid(_ span: RawTextSpan) -> Bool {
        span.location >= 0 && span.length > 0 && span.location <= Int.max - span.length
    }
}

/// One timed piece of recognized speech. `start`/`end` are seconds from the beginning of the audio.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Average token probability 0…1 when the engine reports it.
    public var confidence: Double?
    /// Word confidence spans relative to this segment's `text`; nil when the engine did not supply
    /// complete, alignable token probabilities.
    public var wordConfidences: [WordConfidence]?

    /// Returns nil when `end` precedes `start`.
    public init?(start: TimeInterval, end: TimeInterval, text: String, confidence: Double? = nil,
                 wordConfidences: [WordConfidence]? = nil) {
        guard end >= start else { return nil }
        guard wordConfidences.map({
            DictationAnnotations(wordConfidences: $0).validated(for: text) != nil
        }) != false else { return nil }
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.wordConfidences = wordConfidences
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
