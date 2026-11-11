import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("Selected microphone lifecycle", .timeLimit(.minutes(1)))
struct SelectedMicrophoneTests {
    @Test("an unavailable explicit input never falls back and releases the capture lease")
    func missingInputCanBeRetried() async {
        let source = MicrophoneSource(inputDeviceUID: { "voxflow-test-unavailable-input" })
        for _ in 0..<2 {
            do {
                for try await _ in source.start() { Issue.record("Must not capture another input") }
                Issue.record("Missing input must fail")
            } catch {
                #expect(error as? MicrophoneError == .noInputDevice)
            }
        }
    }
}
