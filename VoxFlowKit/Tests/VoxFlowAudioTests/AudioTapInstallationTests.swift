import AVFoundation
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("Audio tap exception boundary")
struct AudioTapInstallationTests {
    @Test("a duplicate tap becomes a Swift error and the node remains usable")
    func duplicateTap() throws {
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        try AudioTapInstallation.install(on: mixer, format: format) { _, _ in }
        defer { mixer.removeTap(onBus: 0) }
        #expect(throws: MicrophoneError.self) {
            try AudioTapInstallation.install(on: mixer, format: format) { _, _ in }
        }
        mixer.removeTap(onBus: 0)
        try AudioTapInstallation.install(on: mixer, format: format) { _, _ in }
    }

    @Test("a hardware rate or channel change is rejected before conversion")
    func changedFormat() throws {
        let original = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try AudioTapInstallation.validate(original, expected: original)
        for (rate, channels): (Double, AVAudioChannelCount) in [(44_100, 1), (48_000, 2)] {
            let changed = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
            #expect(throws: MicrophoneError.self) {
                try AudioTapInstallation.validate(changed, expected: original)
            }
        }
    }
}
