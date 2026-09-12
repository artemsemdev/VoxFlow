@preconcurrency import AVFoundation
import VoxFlowCore

/// Configured only while CaptureSession's engine is stopped, on its serial queue.
protocol VoiceProcessingNode: AnyObject {
    var isVoiceProcessingEnabled: Bool { get }
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
    func setOtherAudioDucking(_ level: MicrophoneProcessingOptions.Ducking)
}

enum VoiceProcessingConfiguration {
    static func apply(_ options: MicrophoneProcessingOptions, to node: any VoiceProcessingNode) throws {
        if node.isVoiceProcessingEnabled != options.noiseSuppression {
            try node.setVoiceProcessingEnabled(options.noiseSuppression)
        }
        if options.noiseSuppression { node.setOtherAudioDucking(options.ducking) }
    }
}

extension AVAudioInputNode: VoiceProcessingNode {
    func setOtherAudioDucking(_ level: MicrophoneProcessingOptions.Ducking) {
        let native: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level
        switch level {
        case .minimum: native = .min
        case .standard: native = .default
        case .maximum: native = .max
        }
        voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: native)
    }
}
