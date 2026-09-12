import Foundation
import Synchronization
import VoxFlowCore

/// Decode → (auto language) → transcribe → `TranscriptDocument`. One file per call.
public struct FileTranscriber: FileTranscribing {
    static let decodeShare = 0.05
    private static let windowSamples = Int(10 * AudioSamples.sampleRate)
    private static let minimumTailSamples = Int(0.2 * AudioSamples.sampleRate)

    private let decoder: any AudioDecoding
    private let engine: any SpeechEngine
    private let modelID: String
    private let now: @Sendable () -> Date

    public init(decoder: any AudioDecoding, engine: any SpeechEngine, modelID: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.decoder = decoder
        self.engine = engine
        self.modelID = modelID
        self.now = now
    }

    public func transcribe(_ url: URL, options: TranscriptionOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        try Task.checkCancellation()
        let started = now()
        let preparing = Mutex(true)
        defer { preparing.withLock { $0 = false } }
        var options = options
        do {
            let source = try decoder.open(url) { fraction in
                if preparing.withLock({ $0 }) { progress(Self.decodeShare * min(max(fraction, 0), 1)) }
            }
            let estimatedCount = source.estimatedSampleCount
            var audio = DecodedWindowBuffer(source: source)
            try audio.fill(upTo: options.language == nil ? Int(30 * AudioSamples.sampleRate) : Self.windowSamples + Self.minimumTailSamples)
            preparing.withLock { $0 = false }
            progress(Self.decodeShare)
            var lastProgress = Self.decodeShare
            if options.language == nil {
                let detectionAudio = AudioSamples(audio.samples)
                options.language = try await engine.detectLanguage(in: detectionAudio).code
            }
            var segments: [TranscriptSegment] = []
            var offset = 0
            repeat {
                try Task.checkCancellation()
                try audio.fill(upTo: Self.windowSamples + Self.minimumTailSamples)
                let count = Self.windowEnd(in: audio.samples, from: 0)
                let window = AudioSamples(Array(audio.samples.prefix(count)))
                for try await event in engine.transcribe(window, options: options) {
                    switch event {
                    case .segment(let segment):
                        let start = Double(offset) / AudioSamples.sampleRate
                        segments.append(TranscriptSegment(start: segment.start + start, end: segment.end + start,
                                                          text: segment.text, confidence: segment.confidence)!)
                    case .progress(let value):
                        let fraction = (Double(offset) + min(max(value, 0), 1) * Double(count)) / Double(max(estimatedCount, 1))
                        // Metadata can under/overestimate decoded length. Never regress, or report
                        // completion until the real reader EOF and the last inference have finished.
                        lastProgress = max(lastProgress, min(Double(1).nextDown, Self.decodeShare + (1 - Self.decodeShare) * fraction))
                        progress(lastProgress)
                    }
                }
                offset += count
                audio.consume(count)
            } while !audio.reachedEnd || !audio.samples.isEmpty
            try Task.checkCancellation()
            progress(1)
            let finished = now()
            return TranscriptDocument(sourceURL: url, transcript: Transcript(segments: segments, language: options.language),
                                      modelID: modelID, audioDuration: Double(audio.decodedCount) / AudioSamples.sampleRate,
                                      processingTime: finished.timeIntervalSince(started), createdAt: finished)
        } catch let error as AudioDecodingError {
            switch error {
            case .unsupportedType(let ext): throw FileTranscriptionError.unsupportedType(ext)
            case .fileNotFound(let missing): throw FileTranscriptionError.decodeFailed("file not found: \(missing.lastPathComponent)")
            case .decodeFailed(let reason): throw FileTranscriptionError.decodeFailed(reason)
            }
        } catch SpeechEngineError.modelNotLoaded {
            throw FileTranscriptionError.noModelInstalled
        } catch SpeechEngineError.cancelled {
            throw FileTranscriptionError.cancelled
        } catch is CancellationError {
            throw FileTranscriptionError.cancelled
        } catch let error as FileTranscriptionError {
            throw error
        } catch {
            throw FileTranscriptionError.engineFailed(String(describing: error))
        }
    }

    private static func windowEnd(in samples: [Float], from offset: Int) -> Int {
        // Keep a tiny remainder with this window, accounting for Whisper's mel-frame rounding.
        if samples.count - offset < windowSamples + minimumTailSamples { return samples.count }
        let maximum = offset + windowSamples
        let frame = Int(0.02 * AudioSamples.sampleRate)
        var quietSamples = 0
        var quietEnd = maximum
        // Prefer the last 200 ms pause after at least three seconds, avoiding a cut through a word.
        for end in stride(from: maximum, through: offset + Int(3 * AudioSamples.sampleRate) + frame, by: -frame) {
            let energy = samples[(end - frame)..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
            if energy / Double(frame) < 0.0001 {
                if quietSamples == 0 { quietEnd = end }
                quietSamples += frame
                if quietSamples >= minimumTailSamples { return quietEnd }
            } else {
                quietSamples = 0
            }
        }
        return maximum
    }
}
