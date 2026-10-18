import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("Microphone voice processing")
struct VoiceProcessingConfigurationTests {
    final class Node: VoiceProcessingNode {
        var isVoiceProcessingEnabled = false
        var calls: [String] = []
        func setVoiceProcessingEnabled(_ enabled: Bool) throws {
            isVoiceProcessingEnabled = enabled; calls.append("enabled:\(enabled)")
        }
        func setOtherAudioDucking(_ level: MicrophoneProcessingOptions.Ducking) { calls.append(level.rawValue) }
    }
    @Test("default settings preserve raw input and do not request output attenuation")
    func defaults() throws {
        let node = Node()
        try VoiceProcessingConfiguration.apply(MicrophoneProcessingOptions(), to: node)
        #expect(node.calls.isEmpty)
    }
    @Test("suppression enables voice processing and selects the honest ducking level",
          arguments: MicrophoneProcessingOptions.Ducking.allCases)
    func enabled(level: MicrophoneProcessingOptions.Ducking) throws {
        let node = Node()
        try VoiceProcessingConfiguration.apply(.init(noiseSuppression: true, ducking: level), to: node)
        #expect(node.calls == ["enabled:true", level.rawValue])
        try VoiceProcessingConfiguration.apply(.init(), to: node)
        #expect(node.calls.last == "enabled:false")
    }
}
