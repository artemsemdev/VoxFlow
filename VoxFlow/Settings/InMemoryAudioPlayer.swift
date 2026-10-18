import AVFoundation
import Foundation
import VoxFlowCore

/// AVAudioPlayer consumes an in-memory WAV; the encoded clip is released at completion/cancel.
@MainActor
final class InMemoryAudioPlayer: AudioSamplePlaying {
    private var player: AVAudioPlayer?
    func play(_ samples: [Float]) async throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? min(1, max(-1, sample)) : 0
            var value = Int16((finite * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ integer: T) {
            var value = integer.littleEndian
            withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(AudioSamples.sampleRate)); append(UInt32(AudioSamples.sampleRate * 2))
        append(UInt16(2)); append(UInt16(16)); wav.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count)); wav.append(pcm)
        let player = try AVAudioPlayer(data: wav)
        self.player = player
        defer { stop() }
        guard player.play() else { throw MicrophoneError.engineFailed("Couldn't play the microphone test") }
        try await Task.sleep(for: .seconds(Double(samples.count) / AudioSamples.sampleRate))
    }
    func stop() { player?.stop(); player = nil }
}
