import VoxFlowAudio
import VoxFlowCore

/// Read-only system input discovery, separate from the input selected for VoxFlow captures.
protocol InputDeviceProviding: Sendable {
    func availableInputs() -> [AudioInputDevice]
    func defaultInputName() -> String?
    /// Device-list and default-input changes; the payload preserves existing default-name callers.
    func changes() -> AsyncStream<String?>
}

extension InputDeviceProviding {
    func availableInputs() -> [AudioInputDevice] { [] }
    func changes() -> AsyncStream<String?> { AsyncStream { $0.finish() } }
}

struct AVCaptureInputDeviceProvider: InputDeviceProviding {
    func availableInputs() -> [AudioInputDevice] { AudioInputDevices.available() }
    func defaultInputName() -> String? { AudioInputDevices.defaultDevice()?.name }

    func changes() -> AsyncStream<String?> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let changes = AudioInputDevices.changes()
            let task = Task {
                for await _ in changes {
                    guard !Task.isCancelled else { break }
                    continuation.yield(AudioInputDevices.defaultDevice()?.name)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
