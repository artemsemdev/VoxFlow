@preconcurrency import AVFoundation
import Foundation
import Synchronization
import VoxFlowCore

/// All AVFoundation cursor/converter access is confined to state’s mutex. The caller consumes
/// sequentially; its progress callback runs after unlocking, so it can cancel or inspect the reader.
final class AudioFileReader: AudioSampleReading {
    let estimatedSampleCount: Int
    private let state: Mutex<State>
    private let progress: @Sendable (Double) -> Void

    init(url: URL, fileRead: @escaping AudioDecoder.FileRead,
         progress: @escaping @Sendable (Double) -> Void) throws {
        let initial = try State(url: url, fileRead: fileRead)
        estimatedSampleCount = initial.estimatedSampleCount
        state = Mutex(initial)
        self.progress = progress
        progress(0)
    }

    var fraction: Double { state.withLock { $0.fraction } }

    func read(upTo sampleCount: Int) throws -> AudioSamples? {
        precondition(sampleCount > 0)
        let (audio, fraction) = try state.withLock { state in
            let audio = try state.read(upTo: sampleCount)
            return (audio, state.fraction)
        }
        try Task.checkCancellation()
        progress(fraction)
        return audio
    }

    private struct State {
        static let inputFrames: AVAudioFrameCount = 65_536
        let file: AVAudioFile
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let outputFormat: AVAudioFormat
        let maximumOutputFrames: AVAudioFrameCount
        let estimatedSampleCount: Int
        let fileRead: AudioDecoder.FileRead
        var finished = false

        var fraction: Double {
            finished ? 1 : min(Double(file.framePosition) / Double(max(file.length, 1)), Double(1).nextDown)
        }

        init(url: URL, fileRead: @escaping AudioDecoder.FileRead) throws {
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            guard AudioDecoder.supportedExtensions.contains(ext) else { throw AudioDecodingError.unsupportedType(ext) }
            guard FileManager.default.fileExists(atPath: url.path) else { throw AudioDecodingError.fileNotFound(url) }
            do { file = try AVAudioFile(forReading: url) }
            catch { throw AudioDecodingError.decodeFailed(error.localizedDescription) }
            outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.sampleRate,
                                         channels: file.processingFormat.channelCount, interleaved: false)!
            guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
                throw AudioDecodingError.decodeFailed("no converter to 16 kHz")
            }
            self.converter = converter
            self.fileRead = fileRead
            input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.inputFrames)!
            let ratio = AudioSamples.sampleRate / file.processingFormat.sampleRate
            maximumOutputFrames = AVAudioFrameCount(Double(Self.inputFrames) * ratio) + 1024
            estimatedSampleCount = Int(Double(file.length) * ratio)
        }

        mutating func read(upTo sampleCount: Int) throws -> AudioSamples? {
            try Task.checkCancellation()
            guard !finished else { return nil }
            let capacity = AVAudioFrameCount(min(sampleCount, Int(maximumOutputFrames)))
            let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
            let file = file, input = input, fileRead = fileRead
            let readError = Mutex<(any Error)?>(nil)
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, outStatus in
                guard file.framePosition < file.length else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try Task.checkCancellation()
                    try fileRead(file, input, Self.inputFrames)
                    try Task.checkCancellation()
                } catch {
                    readError.withLock { $0 = error }
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                return input.frameLength > 0 ? input : nil
            }
            try Task.checkCancellation()
            if let error = readError.withLock({ $0 }) {
                if error is CancellationError { throw error }
                throw AudioDecodingError.decodeFailed(error.localizedDescription)
            }
            if let conversionError { throw AudioDecodingError.decodeFailed(conversionError.localizedDescription) }
            guard status != .error else { throw AudioDecodingError.decodeFailed("conversion failed") }
            finished = status == .endOfStream
            guard buffer.frameLength > 0 else {
                guard finished else { throw AudioDecodingError.decodeFailed("converter produced no samples before end of stream") }
                return nil
            }
            // Never equate input EOF with output EOF: subsequent calls drain converter tail data.
            // AVAudioConverter selects a channel when downmixing; average channels ourselves.
            let channels = Int(outputFormat.channelCount), frames = Int(buffer.frameLength)
            let data = buffer.floatChannelData!
            var samples = [Float](repeating: 0, count: frames)
            for channel in 0..<channels {
                for frame in 0..<frames { samples[frame] += data[channel][frame] / Float(channels) }
            }
            return AudioSamples(samples)
        }
    }
}
