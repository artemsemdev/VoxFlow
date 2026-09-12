import AppKit
import CryptoKit
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 2 Step 4) — gated behind `VOXFLOW_RENDER` so normal test runs never
/// touch disk. Run with `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/OnboardingRenderTests`
/// (xcodebuild does not forward a plain `VOXFLOW_RENDER=1` prefix into the xctest host process — see
/// the task report), then compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf`
/// pages 10–12.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct OnboardingRenderTests {
    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    /// A small dummy payload for the checksum — never actually served/downloaded in any render case,
    /// so its byte *content* doesn't need to match `sizeInBytes` (which is a separate, explicit field
    /// below). M-7: this used to derive `sizeInBytes` from the payload itself, scaled down to ~0.5 MB
    /// for `big` while `small` stayed at its real 487 MB — inverting the two and silently hiding the
    /// "Have an 8 GB Mac?" hint from every render.
    static func descriptor(id: String, displayName: String, sizeInBytes: Int64, isDefault: Bool) -> ModelDescriptor {
        let dummy = payload(1, count: 4_096)
        return ModelDescriptor(id: id, displayName: displayName, role: .speech,
                        downloadURL: URL(string: "https://example.com/\(id).bin")!,
                        sizeInBytes: sizeInBytes,
                        sha256: SHA256.hash(data: dummy).map { String(format: "%02x", $0) }.joined(),
                        languagesSummary: "99 languages · best accuracy on M-series", isDefault: isDefault)
    }
    static let big = descriptor(id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo",
                                sizeInBytes: 1_624_555_275, isDefault: true)
    static let small = descriptor(id: "whisper-small", displayName: "Whisper small",
                                  sizeInBytes: 487_601_967, isDefault: false)
    static let catalog = [big, small]

    /// Everything one render case might need to drive: the view model plus its collaborators that
    /// aren't otherwise reachable through it (the dictation coordinator and clock, to drive a Try It
    /// capture through to `.inserted`).
    private struct Bundle {
        let vm: OnboardingViewModel
        let dictation: DictationCoordinator
        let clock: FakeClock
    }

    private func makeBundle(step: OnboardingStep, accessibility: Bool = true) -> Bundle {
        let settingsStore = InMemoryKeyValueStore()
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        let modelStore = ModelStore(directory: dir.url, catalog: Self.catalog, downloader: downloader,
                                    freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: settingsStore)
        let models = ModelsViewModel(store: modelStore, catalog: Self.catalog)
        let dictationSettings = DictationSettings(store: settingsStore)
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: accessibility)
        let navigation = Navigation()
        let historyStoreBox = HistoryStoreBox(try? DictationStore(inMemoryWith: nil))
        let historyWriter = HistoryWriter(storeBox: historyStoreBox, settings: dictationSettings.box, now: { Date() })
        let transcriber = FakeDictationTranscriber(result: DictationResult(
            text: "testing one two three four five this is voxflow running on my mac",
            rawText: "testing one two three four five this is voxflow running on my mac",
            segments: [], language: nil, duration: 0.6, lowConfidence: false))
        let clock = FakeClock()
        let ephemeralScope = EphemeralScope()
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(), transcriber: transcriber,
                                             inserter: FakeTextInserter(), clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { result, appName in await historyWriter.save(result, appName: appName) },
                                             copyToClipboard: { _ in },
                                             ephemeral: { ephemeralScope.isActive })
        let dictation = DictationCoordinator(controller: controller, settings: dictationSettings, permissions: permissions, navigation: navigation)
        dictation.start()
        let state = OnboardingState(store: settingsStore)
        state.step = step
        let vm = OnboardingViewModel(state: state, permissions: permissions, settings: dictationSettings, models: models,
                                     dictation: dictation, ephemeralScope: ephemeralScope, navigation: navigation, clock: clock)
        return Bundle(vm: vm, dictation: dictation, clock: clock)
    }

    private struct RenderCase {
        let name: String
        let step: OnboardingStep
        var accessibility = true
        var fnAction = FnSystemAction.doNothing
        let configure: @MainActor (Bundle) async -> Void
    }

    private static func isArmed(_ state: FlowBarState) -> Bool { if case .armed = state { true } else { false } }
    private static func isListening(_ state: FlowBarState) -> Bool { if case .listening = state { true } else { false } }

    private static let cases: [RenderCase] = [
        RenderCase(name: "1-welcome", step: .welcome) { _ in },
        RenderCase(name: "2-permissions", step: .permissions) { bundle in await bundle.vm.requestMicrophone() },
        RenderCase(name: "2a-accessibility-denied", step: .permissions, accessibility: false) { bundle in
            await bundle.vm.requestMicrophone()
            bundle.vm.openAccessibilitySettings()
            // N-1: `advance` snapshots sleepers synchronously — without waiting for the poll task to
            // actually reach its `clock.sleep(for: 1)` first, `advance(by: 1)` resumes nothing (the
            // sleeper registers *after*, with `now` already moved on, so it parks at deadline 2 and
            // never fires). `waitForSleepers(1)` makes this deterministic, same fix as the unit test.
            await bundle.clock.waitForSleepers(1)
            await bundle.clock.advance(by: 1)
            for _ in 0..<1_000 where !bundle.vm.showsAccessibilityDenied { await Task.yield() }
            if !bundle.vm.showsAccessibilityDenied { Issue.record("2a-accessibility-denied: never reached the denied variant") }
        },
        RenderCase(name: "3-hotkey", step: .hotkey, fnAction: .changeInputSource) { _ in },
        RenderCase(name: "3a-hotkey-fn-unknown", step: .hotkey, fnAction: .unknown) { _ in },
        RenderCase(name: "4-model", step: .model) { bundle in
            for _ in 0..<200 where bundle.vm.modelRow == nil { await Task.yield() }
        },
        // `render()` attaches the production view to its native host before configuration, so the
        // Try It view's own `.onAppear` starts the exercise exactly as it does in the app.
        RenderCase(name: "5-tryit", step: .tryIt) { _ in },
        RenderCase(name: "5b-tryit-inserted", step: .tryIt) { bundle in
            // M-7: exercises the result chip — the most distinctive element on ONB-05 — which no
            // render case previously drove to `.inserted`.
            bundle.dictation.fn(.down)
            for _ in 0..<1_000 where !isArmed(bundle.dictation.state) { await Task.yield() }
            if !isArmed(bundle.dictation.state) { Issue.record("5b-tryit-inserted: never reached .armed (state: \(bundle.dictation.state))") }
            await bundle.clock.waitForSleepers(1)
            await bundle.clock.advance(by: 0.3)   // past the 0.25 s hold threshold: armed → listening
            for _ in 0..<1_000 where !isListening(bundle.dictation.state) { await Task.yield() }
            if !isListening(bundle.dictation.state) { Issue.record("5b-tryit-inserted: never reached .listening (state: \(bundle.dictation.state))") }
            bundle.dictation.fn(.up)
            for _ in 0..<2_000 where bundle.vm.tryItResult == nil { await Task.yield() }
            if bundle.vm.tryItResult == nil { Issue.record("5b-tryit-inserted: tryItResult never set (state: \(bundle.dictation.state))") }
        },
    ]

    @Test("renders every onboarding step for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for testCase in Self.cases {
            let bundle = makeBundle(step: testCase.step, accessibility: testCase.accessibility)
            // The shipped hidden-titlebar window still owns its traffic lights; this render-only
            // chrome keeps the fixture comparable to the mock without showing or focusing a window.
            let fnState = FnSystemActionWarningState(action: testCase.fnAction, currentAction: { testCase.fnAction })
            let content = OnboardingContentView(viewModel: bundle.vm, fnWarningState: fnState, openKeyboard: {})
            let host = NativeRenderHost(RenderChrome(content: content), size: NSSize(width: 700, height: 520))
            defer { host.close() }
            await testCase.configure(bundle)
            await Task.yield()
            host.layout()
            try host.capture(to: directory.appendingPathComponent("Onboarding-\(testCase.name).png"))
        }
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }

}

/// Render-only stand-in for the real window's `.hiddenTitleBar` traffic lights (D-1) — the shipped
/// `OnboardingContentView` no longer draws these itself.
private struct RenderChrome: View {
    let content: OnboardingContentView

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color.black.opacity(0.12)).frame(width: 12, height: 12)
                Circle().fill(Color.black.opacity(0.12)).frame(width: 12, height: 12)
            }
            .padding(.leading, 20)
            .padding(.top, 20)
        }
        .frame(width: 700, height: 520)
    }
}
