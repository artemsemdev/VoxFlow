import Testing
@testable import VoxFlowAudio

@Suite("Microphone capture ownership")
struct MicrophoneCaptureLeaseTests {
    @Test("a test and dictation cannot own the same source until native stop releases it")
    func exclusive() {
        let lease = MicrophoneCaptureLease()
        #expect(lease.acquire())
        #expect(!lease.acquire())
        lease.release()
        #expect(lease.acquire())
        #expect(!lease.acquire())
    }
}
