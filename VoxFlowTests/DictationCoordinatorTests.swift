import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("DictationCoordinator", .timeLimit(.minutes(1)))
@MainActor
struct DictationCoordinatorTests {
    /// `gate`, when given, makes the controller's `preflight()` suspend on it before returning —
    /// lets a test hold `fnDown()` open past its `await preflight()` to prove command ordering.
    func make(preflight: Preflight = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded), gate: Gate? = nil,
              permissionsMicrophone: PermissionState = .granted, permissionsRequestResult: PermissionState = .granted,
              loadModel: @escaping @Sendable () async throws -> Void = {})
        -> (DictationCoordinator, FakeMicrophone, FakeClock, FakePermissions, Navigation) {
        let mic = FakeMicrophone(), clock = FakeClock()
        let permissions = FakePermissions(microphone: permissionsMicrophone, requestResult: permissionsRequestResult, accessibility: true)
        let transcriber = FakeDictationTranscriber(result: DictationResult(text: "hi there", rawText: "hi there", segments: [], language: nil, duration: 1, lowConfidence: false))
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { if let gate { await gate.wait() }; return preflight },
                                             loadModel: loadModel, options: { TranscriptionOptions() },
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
        let (c, mic, _, _, _) = make()
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
        // `.armed + .escape → .discarded` ("esc before the hold/tap decision") is handled directly by
        // FlowBarMachine — no need to drive the hold timer first.
        c.escape()
        await wait(c) { $0 == .discarded }
    }

    @Test("fn(.down) immediately followed by fn(.up) doesn't get stuck armed when preflight is slow")
    func rapidTapOrdering() async {
        let gate = Gate()
        let (c, _, _, _, _) = make(gate: gate)
        // Both commands are enqueued before either is processed — the single command-consumer task
        // must run `fnDown()` (which suspends inside `await preflight()`, i.e. on `gate`) to
        // completion before it even looks at the queued `fnUp()`. If the two were instead dispatched
        // as independent `Task`s racing on the controller actor, `fnUp` could land first and be
        // dropped as a no-op from `.idle`, leaving the Flow Bar stuck armed/listening after release.
        c.fn(.down)
        c.fn(.up)
        await gate.open()
        // `.tapped` also carries a payload — same `.armed(_)`-style workaround as above.
        await wait(c) { if case .tapped(_) = $0 { true } else { false } }
    }

    @Test("first-use microphone prompt: notDetermined fn-down requests access instead of enqueuing; the matching fn-up is swallowed; a later fn-down proceeds normally")
    func firstUseMicrophonePrompt() async {
        let (c, mic, _, perms, _) = make(permissionsMicrophone: .notDetermined, permissionsRequestResult: .granted)
        c.fn(.down)
        c.fn(.up)
        while perms.requests == 0 { await Task.yield() }
        // Give the (would-be, wrongly) swallowed fn-up plenty of chances to reach the controller.
        for _ in 0..<50 { await Task.yield() }
        #expect(c.state == .idle)
        #expect(mic.startCount == 0)
        #expect(perms.requests == 1)

        // The next press is a normal, un-suspended one now that the grant landed.
        c.fn(.down)
        c.fn(.up)
        await wait(c) { if case .tapped(_) = $0 { true } else { false } }
    }

    // MARK: startProgrammaticDictation — the MCP `dictate` seam

    @Test("startProgrammaticDictation starts a hands-free capture through the same command queue as a real double-tap")
    func programmaticDictationStartsHandsFree() async {
        let (c, mic, _, _, _) = make()
        c.startProgrammaticDictation()
        await wait(c) { if case .listening(let l) = $0, l.mode == .handsFree { true } else { false } }
        await mic.waitUntilCapturing()
        #expect(c.isHUDActive)
    }

    @Test("startProgrammaticDictation defers to the microphone-permission prompt exactly like the hotkey — it doesn't bypass fn(_:)'s notDetermined diversion")
    func programmaticDictationRespectsPendingMicPermission() async {
        let (c, mic, _, perms, _) = make(permissionsMicrophone: .notDetermined, permissionsRequestResult: .granted)
        c.startProgrammaticDictation()
        while perms.requests == 0 { await Task.yield() }
        // Give the (would-be, wrongly) swallowed up/down their chance to reach the controller.
        for _ in 0..<50 { await Task.yield() }
        #expect(c.state == .idle)
        #expect(mic.startCount == 0)
        #expect(perms.requests == 1)
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

        // `.error` (e.g. a failed model load) has nothing to do with Accessibility — it routes to
        // Settings › Models, same destination as `.modelNotInstalled` (I-2).
        struct LoadFailed: Error {}
        let (errored, _, _, _, errNav) = make(preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .installedNotLoaded),
                                              loadModel: { throw LoadFailed() })
        errored.fn(.down)
        await wait(errored) { if case .error = $0 { true } else { false } }
        errored.openSettingsForCurrentError()
        #expect(errNav.page == .settings && errNav.settingsTab == .models && errNav.requestMainWindow)
    }
}
