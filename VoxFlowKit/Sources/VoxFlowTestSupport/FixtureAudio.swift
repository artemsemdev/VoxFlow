@preconcurrency import AVFoundation
import Foundation

/// Writes small synthetic audio files for decoder tests (no binaries in the repo except MP3,
/// which AVFoundation cannot encode).
public enum FixtureAudio {
    /// A 440 Hz sine at amplitude 0.5 on channel 0, PCM 16-bit; every other channel is silent
    /// (zeros), so a multi-channel fixture proves the decoder actually downmixes rather than
    /// just passing one already-identical channel through. Container chosen by the URL's
    /// extension (wav, aiff, caf).
    public static func writeSine(to url: URL, seconds: Double, sampleRate: Double, channels: UInt32) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased() == "aiff",
        ]
        try write(url: url, settings: settings, seconds: seconds, sampleRate: sampleRate, channels: channels)
    }

    /// A 440 Hz sine encoded as AAC (m4a or mp4 container).
    public static func writeAAC(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        try write(url: url, settings: settings, seconds: seconds, sampleRate: 44_100, channels: 1)
    }

    private static func write(url: URL, settings: [String: Any], seconds: Double, sampleRate: Double, channels: UInt32) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
        }
        // Channels 1... are left at their zero-initialized default (silence).
        try file.write(from: buffer)
    }
}
