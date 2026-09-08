@preconcurrency import AVFoundation
import Foundation
import Synchronization
import VoxFlowCore

/// Decodes any AVFoundation-readable audio/video file to `AudioSamples` (16 kHz mono Float32).
public struct AudioDecoder: AudioDecoding {
    /// Delegates to `SupportedAudio`, the single source of truth; kept as a name for existing call sites.
    public static var supportedExtensions: Set<String> { SupportedAudio.extensions }

    /// Input frames converted per iteration. Bounds the *conversion* buffers; the decoded output still
    /// holds the whole file (≈ 690 MB for 3 h) — chunking long files is a phase-2 decision.
    private static let chunkFrames: AVAudioFrameCount = 65_536

    public init() {}

    public func decode(_ url: URL) throws -> AudioSamples {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw AudioDecodingError.unsupportedType(ext) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioDecodingError.fileNotFound(url) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecodingError.decodeFailed(error.localizedDescription)
        }

        // AVAudioConverter's own channel-count reduction does not average channels — it just
        // selects one and drops the rest — so the mono downmix has to be ours: convert at the
        // source's own channel count (sample-rate conversion only) and average channels below.
        let sourceChannels = file.processingFormat.channelCount
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.sampleRate,
                                   channels: sourceChannels, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioDecodingError.decodeFailed("no converter from \(file.processingFormat) to 16 kHz")
        }

        let ratio = AudioSamples.sampleRate / file.processingFormat.sampleRate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        // The input block reads the next chunk directly from `file` each time the converter
        // asks for more; all state (the read cursor) lives on `file` itself, and `chunk` is
        // allocated once and reused, so nothing mutable Swift-side needs to be captured by
        // this @Sendable closure — except `readError`, which uses `Mutex` (Sendable, no
        // `@unchecked`/`nonisolated(unsafe)`) to carry a mid-file read failure back out.
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.chunkFrames)!
        let outputCapacity = AVAudioFrameCount(Double(Self.chunkFrames) * ratio) + 1024
        var conversionError: NSError?
        let readError = Mutex<(any Error)?>(nil)

        conversionLoop: while true {
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity)!
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                // `AVAudioFile.read` throws once `framePosition >= length` — that's the normal
                // end-of-file signal, not a failure, so don't call it there; only a `read`
                // while data legitimately remains can be a genuine mid-file error.
                guard file.framePosition < file.length else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: chunk, frameCount: Self.chunkFrames)
                } catch {
                    readError.withLock { $0 = error }
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard chunk.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return chunk
            }
            if let error = readError.withLock({ $0 }) {
                throw AudioDecodingError.decodeFailed(error.localizedDescription)
            }
            if let conversionError { throw AudioDecodingError.decodeFailed(conversionError.localizedDescription) }
            if status == .error { throw AudioDecodingError.decodeFailed("conversion failed") }

            appendDownmixed(outputBuffer, channels: Int(sourceChannels), to: &output)

            switch status {
            case .haveData:
                continue conversionLoop
            case .endOfStream, .inputRanDry:
                break conversionLoop
            case .error:
                throw AudioDecodingError.decodeFailed("conversion failed")
            @unknown default:
                break conversionLoop
            }
        }

        return AudioSamples(output)
    }

    /// Appends `buffer`'s frames to `output` as mono, averaging across `channels` deinterleaved
    /// channels (a no-op copy when `channels == 1`).
    private func appendDownmixed(_ buffer: AVAudioPCMBuffer, channels: Int, to output: inout [Float]) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        let channelData = buffer.floatChannelData!

        guard channels > 1 else {
            output.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
            return
        }

        let scale = 1 / Float(channels)
        output.reserveCapacity(output.count + frameLength)
        for frame in 0..<frameLength {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += channelData[channel][frame]
            }
            output.append(sum * scale)
        }
    }
}
