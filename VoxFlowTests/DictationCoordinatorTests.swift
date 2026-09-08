import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("DictationCoordinator", .timeLimit(.minutes(1)))
@MainActor
struct DictationCoordinatorTests {
    func make(preflight: Preflight = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded))
        -> (DictationCoordinator, FakeMicrophone, FakeClock, FakePermissions, Navigation) {
        let mic = FakeMicrophone(), clock = FakeClock(), permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let transcriber = FakeDictationTranscriber(result: DictationResult(text: "hi there", rawText: "hi there", segments: [], language: nil, duration: 1, lowConfidence: false))
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { preflight }, loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { _, _ in }, copyToClipboard: { _ in })
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let navigation = Navigation()
        let c = DictationCoordinator(controller: controller, settings: settings, permissions: permissions, navigation: navigation)
        c.start()
        return (c, mic, clock, permissions, navigation)
    }

    /// Waits until the coordinator's observable state satisfies `predicate` (observation-driven, no sleeps).
    func wait(_ c: DictationCoordinator, until predicate: @escaping (FlowBarState) -> Bool) async {
        while !predicate(c.state) { await Task.yield() }
    }

    @Test("mirrors controller state: fn down → armed; HUD active; levels roll")
    func mirrors() async {
        let (c, mic, clock, _, _) = make()
        #expect(c.state == .idle && !c.isHUDActive && c.levels.count == 14)
        c.fn(.down)
        // Note: `if case .armed = $0` (payload pattern omitted) mis-evaluates to `false` under this
        // toolchain when used as an if-expression inside an `@escaping` closure — `.armed(_)`
        // (explicit wildcard payload) works around it; `switch`-statement matching is unaffected.
        await wait(c) { if case .armed(_) = $0 { true } else { false } }
        #expect(c.isHUDActive)
        await mic.waitUntilCapturing()
        c.reportLevel(0.4)
        #expect(c.levels.count == 14 && c.levels.last == 0.4)
        // `FlowBarMachine` only handles `.escape` from `.loadingModel`/`.listening`/`.processing` (a
        // no-op from `.armed`), so the hold timer needs to fire — advance the fake clock past
        // `holdThreshold` and wait for `.listening` before escaping, so escape() has an effect.
        await clock.advance(by: FlowBarConfig().holdThreshold + 0.1)
        await wait(c) { if case .listening(_) = $0 { true } else { false } }
        c.escape()
        await wait(c) { $0 == .discarded }
    }

    @Test("open settings routes by state: mic denied → Microphone pane; model missing → Settings › Models")
    func openSettings() async {
        let (denied, _, _, perms, _) = make(preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded))
        denied.fn(.down)
        await wait(denied) { $0 == .micUnavailable(.denied) }
        denied.openSettingsForCurrentError()
        #expect(perms.openedMicrophoneSettings == 1)

        let (missing, _, _, _, nav) = make(preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .notInstalled(sizeBytes: 1)))
        missing.fn(.down)
        await wait(missing) { $0 == .modelNotInstalled(sizeBytes: 1) }
        missing.openSettingsForCurrentError()
        #expect(nav.page == .settings && nav.settingsTab == .models && nav.requestMainWindow)
    }
}
