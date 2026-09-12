import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowDictation

@Suite("WindowPlanner")
struct WindowPlannerTests {
    func chunk(seconds: Double, rms: Float) -> AudioChunk {
        AudioChunk(samples: Array(repeating: rms, count: Int(seconds * AudioSamples.sampleRate)))
    }

    @Test("the silence-stop threshold and the window-cut threshold never drift apart (I4)")
    func sharedVoiceThreshold() {
        #expect(FlowBarConfig().voiceRMS == WindowPlanner().voiceRMS)
        #expect(WindowPlanner().voiceRMS == DictationDefaults.voiceRMS)
    }

    @Test("closes a window after ≥ 3 s when the last 0.4 s are silent; reports its start offset")
    func silenceCut() {
        var planner = WindowPlanner()
        #expect(planner.append(chunk(seconds: 2.9, rms: 0.3)) == nil)
        #expect(planner.append(chunk(seconds: 0.3, rms: 0.0)) == nil)          // 3.2 s but only 0.3 s of silence
        let window = planner.append(chunk(seconds: 0.2, rms: 0.0))
        #expect(window?.startOffset == 0)
        #expect(window?.samples.duration == 3.4)
        #expect(planner.append(chunk(seconds: 3.0, rms: 0.3)) == nil)
        let second = planner.append(chunk(seconds: 0.5, rms: 0.0))
        #expect(second?.startOffset == 3.4)
    }

    @Test("closes at 10 s even without silence")
    func hardCut() {
        var planner = WindowPlanner()
        for _ in 0..<9 { #expect(planner.append(chunk(seconds: 1, rms: 0.3)) == nil) }
        let window = planner.append(chunk(seconds: 1.5, rms: 0.3))
        #expect(window?.samples.duration == 10.5)
    }

    @Test("flush returns the remainder when ≥ 0.3 s, nil otherwise")
    func flush() {
        var planner = WindowPlanner()
        _ = planner.append(chunk(seconds: 0.2, rms: 0.3))
        #expect(planner.flush() == nil)
        _ = planner.append(chunk(seconds: 0.2, rms: 0.3))
        let rest = planner.flush()
        #expect(rest?.samples.duration == 0.4)
        #expect(planner.flush() == nil)
    }

    @Test("a device gap closes buffered audio and advances the next absolute offset")
    func deviceGap() {
        var planner = WindowPlanner()
        _ = planner.append(chunk(seconds: 0.2, rms: 0.3))
        let beforeSwitch = planner.interrupt(by: 1.5)
        #expect(beforeSwitch?.startOffset == 0)
        #expect(beforeSwitch?.samples.duration == 0.2)

        _ = planner.append(chunk(seconds: 0.4, rms: 0.3))
        #expect(planner.flush()?.startOffset == 1.7)
    }

    @Test("a new planner resets prior gaps and multiple switches accumulate")
    func resetAndMultipleGaps() {
        var planner = WindowPlanner()
        #expect(planner.interrupt(by: 0.25) == nil)
        #expect(planner.interrupt(by: 0.75) == nil)
        _ = planner.append(chunk(seconds: 0.4, rms: 0.3))
        #expect(planner.flush()?.startOffset == 1)

        var nextCapture = WindowPlanner()
        _ = nextCapture.append(chunk(seconds: 0.4, rms: 0.3))
        #expect(nextCapture.flush()?.startOffset == 0)
    }

    @Test("prompt context is the last 200 characters of the text so far")
    func promptTail() {
        #expect(WindowedTranscriber.promptContext(from: "") == nil)
        let long = String(repeating: "abcdefghij", count: 30)
        #expect(WindowedTranscriber.promptContext(from: long)?.count == 200)
        #expect(WindowedTranscriber.promptContext(from: "short") == "short")
    }
}
