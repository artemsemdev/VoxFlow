import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

/// FB-09 "Paused · N min left" (`FlowBarContent`'s `now:` parameter), the menu bar's "Paused until
/// 10:41" (`DictationCoordinator.now()`), and `isHUDActive` staying false throughout a pause (I1)
/// — the coordinator-level half of the paused-pill plumbing `FlowBarContentTests`/
/// `MenuBarViewModelTests` don't cover directly.
@Suite("DictationCoordinator paused clock")
@MainActor
struct FlowBarPausedClockTests {
    func makeCoordinator(clock: FakeClock) -> DictationCoordinator {
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(),
                                             transcriber: FakeDictationTranscriber(result: .empty), inserter: FakeTextInserter(),
                                             clock: clock, preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        let coordinator = DictationCoordinator(controller: controller, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                               permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
                                               navigation: Navigation(), clock: clock)
        coordinator.start()
        return coordinator
    }

    func wait(_ c: DictationCoordinator, until predicate: @escaping (FlowBarState) -> Bool) async {
        for _ in 0..<2000 where !predicate(c.state) { await Task.yield() }
    }

    @Test("now() mirrors the coordinator's own clock")
    func nowMirrorsClock() {
        let clock = FakeClock()
        let coordinator = makeCoordinator(clock: clock)
        #expect(coordinator.now() == clock.now())
    }

    @Test("isHUDActive is false while paused (I1): FnKeyMonitor's global keyDown gate must not stay armed for the whole pause")
    func isHUDActiveFalseWhilePaused() async throws {
        let clock = FakeClock()
        let coordinator = makeCoordinator(clock: clock)
        #expect(!coordinator.isHUDActive)

        coordinator.pause(for: 3600)
        await wait(coordinator) { if case .paused = $0 { true } else { false } }
        #expect(coordinator.pausedUntil != nil)
        #expect(!coordinator.isHUDActive)   // the one thing this ruling changes

        coordinator.resume()
        await wait(coordinator) { $0 == .idle }
        #expect(!coordinator.isHUDActive)
    }
}
