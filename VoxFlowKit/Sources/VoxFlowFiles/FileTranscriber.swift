import Foundation
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
                           update: @Sendable @escaping (FileTranscriptionUpdate) -> Void) async throws -> TranscriptDocument {
        try Task.checkCancellation()
        let started = now()
        let audio: AudioSamples
        do {
            audio = try decoder.decode(url)
        } catch let error as AudioDecodingError {
            switch error {
            case .unsupportedType(let ext): throw FileTranscriptionError.unsupportedType(ext)
            case .fileNotFound(let missing): throw FileTranscriptionError.decodeFailed("file not found: \(missing.lastPathComponent)")
            case .decodeFailed(let reason): throw FileTranscriptionError.decodeFailed(reason)
            }
        }
        update(.progress(Self.decodeShare))

        var options = options
        do {
            if options.language == nil {
                let detectionAudio = AudioSamples(Array(audio.samples.prefix(Int(30 * AudioSamples.sampleRate))))
                options.language = try await engine.detectLanguage(in: detectionAudio).code
            }
            var segments: [TranscriptSegment] = []
            var offset = 0
            repeat {
                try Task.checkCancellation()
                let count = Self.windowEnd(in: audio.samples, from: offset) - offset
                let window = AudioSamples(Array(audio.samples[offset..<(offset + count)]))
                for try await event in engine.transcribe(window, options: options) {
                    switch event {
                    case .segment(let segment):
                        let start = Double(offset) / AudioSamples.sampleRate
                        segments.append(TranscriptSegment(start: segment.start + start, end: segment.end + start,
                                                          text: segment.text, confidence: segment.confidence)!)
                    case .progress(let value):
                        let fraction = (Double(offset) + min(max(value, 0), 1) * Double(count)) / Double(max(audio.samples.count, 1))
                        update(.progress(Self.decodeShare + (1 - Self.decodeShare) * fraction))
                    }
                }
                offset += count
            } while offset < audio.samples.count
            try Task.checkCancellation()
            update(.progress(1))
            let finished = now()
            return TranscriptDocument(sourceURL: url, transcript: Transcript(segments: segments, language: options.language),
                                      modelID: modelID, audioDuration: audio.duration,
                                      processingTime: finished.timeIntervalSince(started), createdAt: finished)
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
