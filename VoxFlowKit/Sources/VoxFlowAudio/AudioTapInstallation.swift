@preconcurrency import AVFoundation
import VoxFlowAudioBridge
import VoxFlowCore

enum AudioTapInstallation {
    /// A route can change after format discovery and before the first render callback.
    /// Never pass a buffer in the new hardware format to the old converter.
    static func validate(_ actual: AVAudioFormat, expected: AVAudioFormat) throws {
        guard actual.isEqual(expected) else {
            throw MicrophoneError.engineFailed("Microphone format changed. Please start recording again.")
        }
    }

    static func install(on node: AVAudioNode, format: AVAudioFormat? = nil,
                        block: @escaping AVAudioNodeTapBlock) throws {
        var error: NSError?
        guard VFInstallAudioTap(node, 0, 4096, format, block, &error) else {
            throw MicrophoneError.engineFailed(error?.localizedDescription ?? "Could not install microphone tap.")
        }
    }
}
