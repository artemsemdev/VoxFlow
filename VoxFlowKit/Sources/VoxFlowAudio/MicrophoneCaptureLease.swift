import Synchronization

/// Shared by dictation and microphone testing; released only after the engine has stopped.
final class MicrophoneCaptureLease: Sendable {
    private let occupied = Mutex(false)
    func acquire() -> Bool {
        occupied.withLock { guard !$0 else { return false }; $0 = true; return true }
    }
    func release() { occupied.withLock { $0 = false } }
}
