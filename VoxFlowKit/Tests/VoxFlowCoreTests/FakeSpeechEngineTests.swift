import Foundation
import Testing
import VoxFlowTestSupport
@testable import VoxFlowCore

@Suite("FakeSpeechEngine")
struct FakeSpeechEngineTests {
    @Test("streams the scripted segments then finishes")
    func streamsScript() async throws {
        let engine = FakeSpeechEngine(script: [
            .segment(TranscriptSegment(start: 0, end: 1, text: "one")!),
            .progress(0.5),
            .segment(TranscriptSegment(start: 1, end: 2, text: "two")!),
        ])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        var events: [SegmentEvent] = []
        for try await event in engine.transcribe(AudioSamples([0, 0, 0]), options: TranscriptionOptions()) {
            events.append(event)
        }
        #expect(events.count == 3)
        #expect(await engine.transcribeCalls == 1)
    }

    @Test("throws when used before load")
    func requiresLoad() async {
        let engine = FakeSpeechEngine(script: [])
        await #expect(throws: SpeechEngineError.modelNotLoaded) {
            for try await _ in engine.transcribe(AudioSamples([]), options: TranscriptionOptions()) {}
        }
    }
}
