import Foundation
import VoxFlowCore

/// Passes microphone events through and reports each chunk's RMS for the 14-bar waveform.
final class MeteredMicrophone: MicrophoneCapturing, Sendable {
    private let base: any MicrophoneCapturing
    private let onLevel: @Sendable (Float) -> Void
    init(base: any MicrophoneCapturing, onLevel: @escaping @Sendable (Float) -> Void) {
        self.base = base
        self.onLevel = onLevel
    }

    func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        let upstream = base.start()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .chunk(let c) = event { onLevel(c.rms) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
