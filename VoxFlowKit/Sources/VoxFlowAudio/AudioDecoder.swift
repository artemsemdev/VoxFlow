@preconcurrency import AVFoundation
import Foundation
import VoxFlowCore

/// Decodes AVFoundation-readable files to 16 kHz mono Float32, with a bounded cursor for Files.
public struct AudioDecoder: AudioDecoding {
    typealias FileRead = @Sendable (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
    public static var supportedExtensions: Set<String> { SupportedAudio.extensions }
    private let fileRead: FileRead

    public init() { fileRead = { try $0.read(into: $1, frameCount: $2) } }
    init(fileRead: @escaping FileRead) { self.fileRead = fileRead }

    public func open(_ url: URL, progress: @escaping @Sendable (Double) -> Void) throws -> any AudioSampleReading {
        try AudioFileReader(url: url, fileRead: fileRead, progress: progress)
    }

    public func decode(_ url: URL) throws -> AudioSamples { try decode(url, progress: { _ in }) }

    /// Compatibility for callers that explicitly need all samples. Files uses open(_:progress:).
    public func decode(_ url: URL, progress: @Sendable (Double) -> Void) throws -> AudioSamples {
        let reader = try AudioFileReader(url: url, fileRead: fileRead, progress: { _ in })
        var output: [Float] = []
        progress(0)
        while let chunk = try reader.read(upTo: 65_536) {
            output.append(contentsOf: chunk.samples)
            progress(reader.fraction)
        }
        try Task.checkCancellation()
        progress(1)
        return AudioSamples(output)
    }
}
