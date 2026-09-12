import Foundation
import VoxFlowCore

/// Runs `SpeechEngine.transcribe` per window while the feed is still open, so text streams during speech.
public struct WindowedTranscriber: DictationTranscribing {
    public static let promptTailLength = 200
    private let engine: any SpeechEngine
    private let planner: WindowPlanner

    public init(engine: any SpeechEngine, planner: WindowPlanner = WindowPlanner()) {
        self.engine = engine
        self.planner = planner
    }

    public static func promptContext(from text: String) -> String? {
        text.isEmpty ? nil : String(text.suffix(promptTailLength))
    }

    public func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                           onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
        var planner = planner
        var segments: [TranscriptSegment] = []
        var language: LanguageDetection?
        var duration: TimeInterval = 0
        var text = ""

        func run(_ window: WindowPlanner.Window) async throws {
            var windowOptions = options
            if options.language == nil {
                if language == nil {
                    let detected = try await engine.detectLanguage(in: window.samples)
                    language = detected
                    await onEvent(.language(detected))
                }
                windowOptions.language = language?.code
            }
            windowOptions.promptContext = Self.promptContext(from: text)
            for try await event in engine.transcribe(window.samples, options: windowOptions) {
                guard case .segment(let s) = event else { continue }
                let words = s.wordConfidences.flatMap {
                    DictationAnnotations(wordConfidences: $0).validated(for: s.text)?.wordConfidences
                }
                guard let shifted = TranscriptSegment(start: s.start + window.startOffset, end: s.end + window.startOffset,
                                                       text: s.text, confidence: s.confidence,
                                                       wordConfidences: words) else { continue }
                segments.append(shifted)
            }
            if Task.isCancelled { throw DictationError.cancelled }    // #125: the stream may end silently
            text = Self.join(segments)
            await onEvent(.partialText(text))
        }

        do {
            for await chunk in chunks {
                if let interrupted = planner.interrupt(by: chunk.precedingGap) {
                    try await run(interrupted)
                }
                duration += chunk.precedingGap + chunk.duration
                if let window = planner.append(chunk) { try await run(window) }
            }
            if let rest = planner.flush() { try await run(rest) }
        } catch let error as DictationError {
            throw error
        } catch is CancellationError {
            throw DictationError.cancelled
        } catch SpeechEngineError.cancelled {   // consumer was already cancelled when a window started
            throw DictationError.cancelled
        } catch {
            throw DictationError.engineFailed(String(describing: error))
        }
        if Task.isCancelled { throw DictationError.cancelled }

        let confidences = segments.compactMap(\.confidence)
        let mean = confidences.isEmpty ? 1.0 : confidences.reduce(0, +) / Double(confidences.count)
        let joined = Self.joinWithWordConfidences(segments)
        return DictationResult(text: joined.text, rawText: joined.text, segments: segments, language: language,
                               duration: duration, lowConfidence: mean < 0.5,
                               annotations: DictationAnnotations(wordConfidences: joined.wordConfidences))
    }

    static func join(_ segments: [TranscriptSegment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func joinWithWordConfidences(_ segments: [TranscriptSegment]) -> (text: String, wordConfidences: [WordConfidence]?) {
        var pieces: [String] = []
        var remapped: [WordConfidence] = []
        var complete = true
        var outputLength = 0

        for segment in segments {
            let text = segment.text
            guard let first = text.firstIndex(where: { !$0.isWhitespace }),
                  let last = text.lastIndex(where: { !$0.isWhitespace }) else { continue }
            let end = text.index(after: last)
            let trimmed = String(text[first..<end])
            let trimStart = NSRange(text.startIndex..<first, in: text).length
            let trimEnd = trimStart + (trimmed as NSString).length
            if !pieces.isEmpty { outputLength += 1 }

            guard let words = segment.wordConfidences, !words.isEmpty,
                  DictationAnnotations(wordConfidences: words).validated(for: text) != nil else {
                complete = false
                pieces.append(trimmed)
                outputLength += (trimmed as NSString).length
                continue
            }
            for word in words {
                let localEnd = word.span.location + word.span.length
                guard word.span.location >= trimStart, localEnd <= trimEnd,
                      let span = RawTextSpan(location: outputLength + word.span.location - trimStart,
                                             length: word.span.length),
                      let shifted = WordConfidence(span: span, confidence: word.confidence) else {
                    complete = false
                    continue
                }
                remapped.append(shifted)
            }
            pieces.append(trimmed)
            outputLength += (trimmed as NSString).length
        }
        return (pieces.joined(separator: " "), complete ? remapped : nil)
    }
}
