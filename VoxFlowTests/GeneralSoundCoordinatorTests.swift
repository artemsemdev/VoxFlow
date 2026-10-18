import Testing
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("SoundCoordinator")
@MainActor
struct GeneralSoundCoordinatorTests {
    private func harness(playSounds: Bool = true) -> (settings: GeneralSettings, player: FakeSoundPlayer, coordinator: SoundCoordinator) {
        let settings = GeneralSettings(store: InMemoryKeyValueStore())
        settings.playSounds = playSounds
        let player = FakeSoundPlayer()
        return (settings, player, SoundCoordinator(settings: settings, player: player))
    }

    @Test("plays .start on entering .listening, .end on .inserted and .copied")
    func playsOnStartAndEnd() {
        let h = harness()
        h.coordinator.stateChanged(to: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        h.coordinator.stateChanged(to: .inserted(appName: nil, words: 3, limitReached: false))
        h.coordinator.stateChanged(to: .idle)
        h.coordinator.stateChanged(to: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        h.coordinator.stateChanged(to: .copied(.noTextField))
        #expect(h.player.played == [.start, .end, .start, .end])
    }

    @Test("doesn't re-play .start while already listening (processing → still counts as listening exit)")
    func noRepeatStartWhileListening() {
        let h = harness()
        h.coordinator.stateChanged(to: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        h.coordinator.stateChanged(to: .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        #expect(h.player.played == [.start])
    }

    @Test("plays nothing for states other than listening/inserted/copied")
    func silentForOtherStates() {
        let h = harness()
        h.coordinator.stateChanged(to: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: "")))
        h.coordinator.stateChanged(to: .discarded)
        h.coordinator.stateChanged(to: .idle)
        #expect(h.player.played.isEmpty)
    }

    @Test("plays nothing while playSounds is off")
    func silentWhenDisabled() {
        let h = harness(playSounds: false)
        h.coordinator.stateChanged(to: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        h.coordinator.stateChanged(to: .inserted(appName: nil, words: 1, limitReached: false))
        #expect(h.player.played.isEmpty)
    }
}
