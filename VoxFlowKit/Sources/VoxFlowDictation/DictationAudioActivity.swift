import VoxFlowCore

/// A conservative near-silence gate, not a speech/noise classifier. Inspect short frames so a
/// quiet word surrounded by silence is not lost to the RMS of the entire transcription window.
enum DictationAudioActivity {
    // -60 dBFS: ten times below the hands-free/window-cut threshold. The latter is deliberately
    // unsuitable as a discard threshold: it would also discard quiet but intelligible speech.
    private static let minimumRMS: Float = 0.001
    private static let frameSamples = 320 // 20 ms at the engine's 16 kHz sample rate.

    static func hasSignal(_ audio: AudioSamples) -> Bool {
        let samples = audio.samples
        for start in stride(from: 0, to: samples.count, by: frameSamples) {
            let end = min(start + frameSamples, samples.count)
            let energy = samples[start..<end].reduce(Float(0)) { $0 + $1 * $1 }
            if energy / Float(end - start) >= minimumRMS * minimumRMS { return true }
        }
        return false
    }
}
