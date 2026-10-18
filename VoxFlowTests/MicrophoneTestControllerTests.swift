import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Microphone test", .timeLimit(.minutes(1))) @MainActor
struct MicrophoneTestControllerTests {
    final class Player: AudioSamplePlaying {
        var played: [[Float]] = []
        var stops = 0
        func play(_ samples: [Float]) async throws { played.append(samples) }
        func stop() { stops += 1 }
    }
    @Test("test caps recorded memory at five seconds, updates levels and plays without retaining audio")
    func boundedPlayback() async {
        let microphone = FakeMicrophone(), player = Player()
        let model = MicrophoneTestController(microphone: microphone, player: player,
            permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: false),
            clock: FakeClock(), canStart: { true })
        model.start()
        await microphone.waitUntilCapturing()
        microphone.emit(rms: 0.3, seconds: 6)
        microphone.emit(rms: 0.8, seconds: 0.1) // Buffered after the cap; must not suppress playback.
        await model.waitUntilFinished()
        #expect(player.played.count == 1 && player.played[0].count == 80_000)
        #expect(model.state == .idle && model.bufferedSampleCount == 0)
        #expect(microphone.stopCount == 1)
    }
    @Test("permission denial or active dictation never opens the microphone", arguments: [false, true])
    func refused(busy: Bool) async {
        let microphone = FakeMicrophone(), player = Player()
        let permissions = FakePermissions(microphone: .denied, requestResult: .denied, accessibility: false)
        let model = MicrophoneTestController(microphone: microphone, player: player,
                                             permissions: permissions, clock: FakeClock(), canStart: { !busy })
        model.start(); await model.waitUntilFinished()
        #expect(microphone.startCount == 0 && player.played.isEmpty)
        #expect(model.message != nil)
    }
    @Test("cancellation clears samples and stops capture without playback")
    func cancellation() async {
        let microphone = FakeMicrophone(), player = Player()
        let model = MicrophoneTestController(microphone: microphone, player: player,
            permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: false),
            clock: FakeClock(), canStart: { true })
        model.start(); await microphone.waitUntilCapturing()
        model.stop(); await model.waitUntilFinished()
        #expect(microphone.stopCount == 1 && player.played.isEmpty)
        #expect(model.bufferedSampleCount == 0 && model.state == .idle)
    }
    @Test("no-input wall deadline ends the test without waiting for audio chunks")
    func deadline() async {
        let microphone = FakeMicrophone(), player = Player(), clock = FakeClock()
        let model = MicrophoneTestController(microphone: microphone, player: player,
            permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: false),
            clock: clock, canStart: { true })
        model.start(); await microphone.waitUntilCapturing()
        await clock.waitForSleepers(1)
        await clock.advance(by: 5)
        await model.waitUntilFinished()
        #expect(microphone.stopCount == 1 && player.played.isEmpty && model.state == .idle)
    }
}
