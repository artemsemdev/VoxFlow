import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("OnboardingViewModel", .timeLimit(.minutes(1)))
@MainActor
struct OnboardingViewModelTests {
    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    static let bigPayload = payload(1, count: 300_000)
    static let smallPayload = payload(2, count: 100_000)

    static func descriptor(id: String, payload: Data, isDefault: Bool) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, role: .speech,
                        downloadURL: URL(string: "https://example.com/\(id).bin")!,
                        sizeInBytes: Int64(payload.count),
                        sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                        languagesSummary: "test", isDefault: isDefault)
    }
    static let big = descriptor(id: "big", payload: bigPayload, isDefault: true)
    static let small = descriptor(id: "small", payload: smallPayload, isDefault: false)
    static let catalog = [big, small]

    /// One store backs everything (onboarding step/completed, dictation settings, model store
    /// bookkeeping) — the same shape `AppServices.live()` uses in production.
    @MainActor
    struct Harness {
        let store = InMemoryKeyValueStore()
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        var freeSpace = FakeFreeSpace(available: 10_000_000_000)
        let clock = FakeClock()
        let permissions: FakePermissions
        let historyStore: DictationStore
        let historyStoreBox: HistoryStoreBox
        let dictationSettings: DictationSettings
        let navigation = Navigation()

        init(microphone: PermissionState = .granted, accessibility: Bool = true) throws {
            permissions = FakePermissions(microphone: microphone, requestResult: .granted, accessibility: accessibility)
            historyStore = try DictationStore(inMemoryWith: nil)
            historyStoreBox = HistoryStoreBox(historyStore)
            dictationSettings = DictationSettings(store: store)
        }

        func serveAll() async {
            await downloader.serve(OnboardingViewModelTests.bigPayload, at: OnboardingViewModelTests.big.downloadURL)
            await downloader.serve(OnboardingViewModelTests.smallPayload, at: OnboardingViewModelTests.small.downloadURL)
        }

        func modelsViewModel() -> ModelsViewModel {
            let modelStore = ModelStore(directory: dir.url, catalog: OnboardingViewModelTests.catalog,
                                        downloader: downloader, freeSpace: freeSpace, settings: store)
            return ModelsViewModel(store: modelStore, catalog: OnboardingViewModelTests.catalog)
        }

        /// A `DictationCoordinator` wired to `historyWriter` and `ephemeralScope` (same instances the
        /// view model gets) — `ephemeralScope.isActive` at capture start is what decides whether that
        /// capture reaches `historyWriter.save` at all (I-1/I-2/I-3).
        func dictation(historyWriter: HistoryWriter, ephemeralScope: EphemeralScope) -> DictationCoordinator {
            let transcriber = FakeDictationTranscriber(result: DictationResult(
                text: "one two three four five six seven eight nine ten eleven",
                rawText: "one two three four five six seven eight nine ten eleven",
                segments: [], language: nil, duration: 0.6, lowConfidence: false))
            let controller = DictationController(
                config: FlowBarConfig(), microphone: FakeMicrophone(), transcriber: transcriber,
                inserter: FakeTextInserter(), clock: clock,
                preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                loadModel: {}, options: { TranscriptionOptions() },
                onSave: { result, appName in await historyWriter.save(result, appName: appName) },
                copyToClipboard: { _ in },
                ephemeral: { ephemeralScope.isActive })
            let coordinator = DictationCoordinator(controller: controller, settings: dictationSettings,
                                                   permissions: permissions, navigation: navigation)
            coordinator.start()
            return coordinator
        }

        /// Builds a fresh `OnboardingViewModel` resuming at `step` (persisted into `store` first, the
        /// same way a relaunch would resume it) plus every collaborator it was built from.
        func viewModel(step: OnboardingStep = .welcome, completed: Bool = false)
            -> (vm: OnboardingViewModel, state: OnboardingState, models: ModelsViewModel,
                dictation: DictationCoordinator, scope: EphemeralScope) {
            let bootstrap = OnboardingState(store: store)
            bootstrap.step = step
            bootstrap.completed = completed
            let state = OnboardingState(store: store)
            let models = modelsViewModel()
            let historyWriter = HistoryWriter(storeBox: historyStoreBox, settings: dictationSettings.box, now: { Date() })
            let scope = EphemeralScope()
            let dc = dictation(historyWriter: historyWriter, ephemeralScope: scope)
            let vm = OnboardingViewModel(state: state, permissions: permissions, settings: dictationSettings, models: models,
                                         dictation: dc, ephemeralScope: scope, navigation: navigation, clock: clock)
            return (vm, state, models, dc, scope)
        }
    }

    @Test("fresh state starts at .welcome")
    func freshState() throws {
        let h = try Harness()
        #expect(h.viewModel().vm.step == .welcome)
    }

    @Test("next() advances through the fixed step order and stops at .tryIt")
    func nextOrder() throws {
        let h = try Harness()
        let vm = h.viewModel().vm
        #expect(vm.step == .welcome)
        vm.next(); #expect(vm.step == .permissions)
        vm.next(); #expect(vm.step == .hotkey)
        vm.next(); #expect(vm.step == .model)
        vm.next(); #expect(vm.step == .tryIt)
        vm.next(); #expect(vm.step == .tryIt)
    }

    @Test("permissions: canContinue requires mic granted and (accessibility granted or skipped)")
    func permissionsCanContinue() async throws {
        let h = try Harness(microphone: .denied, accessibility: false)
        let (vm, state, _, _, _) = h.viewModel(step: .permissions)
        #expect(!vm.canContinue)

        await vm.requestMicrophone()
        #expect(vm.microphone == .granted)
        #expect(!vm.canContinue)   // accessibility still neither granted nor skipped

        state.accessibilitySkipped = true
        #expect(vm.canContinue)
    }

    @Test("permissions: both granted also satisfies canContinue")
    func permissionsBothGranted() throws {
        let h = try Harness(microphone: .granted, accessibility: true)
        let vm = h.viewModel(step: .permissions).vm
        #expect(vm.microphone == .granted && vm.accessibilityGranted)
        #expect(vm.canContinue)
    }

    @Test("openAccessibilitySettings polls the clock; the denied variant appears only after a failed poll, not immediately (M-4)")
    func accessibilityPolling() async throws {
        let h = try Harness(microphone: .granted, accessibility: false)
        let vm = h.viewModel(step: .permissions).vm

        vm.openAccessibilitySettings()
        #expect(!vm.showsAccessibilityDenied)   // neutral row while the first poll is still in flight
        #expect(h.permissions.openedAccessibilitySettings == 1)

        // `waitForSleepers` (not a fixed yield count) makes this deterministic: the poll task must
        // actually have registered its `clock.sleep(for: 1)` before `advance` fires it.
        await h.clock.waitForSleepers(1)
        await h.clock.advance(by: 1)
        #expect(vm.showsAccessibilityDenied)    // still not trusted after the first poll
        #expect(!vm.accessibilityGranted)

        h.permissions.accessibility = true
        await h.clock.waitForSleepers(1)
        await h.clock.advance(by: 1)
        #expect(vm.accessibilityGranted)
        #expect(!vm.showsAccessibilityDenied)
    }

    @Test("tryAgainAccessibility while still not trusted keeps showsAccessibilityDenied")
    func tryAgainStillDenied() throws {
        let h = try Harness(microphone: .granted, accessibility: false)
        let vm = h.viewModel(step: .permissions).vm

        vm.tryAgainAccessibility()

        #expect(vm.showsAccessibilityDenied)
        #expect(!vm.accessibilityGranted)
    }

    @Test("continueWithClipboard advances to .hotkey and persists accessibilitySkipped")
    func continueWithClipboardAdvances() throws {
        let h = try Harness(microphone: .granted, accessibility: false)
        let (vm, state, _, _, _) = h.viewModel(step: .permissions)

        vm.continueWithClipboard()

        #expect(vm.step == .hotkey)
        #expect(state.accessibilitySkipped)
    }

    @Test("choose(_:) writes the shared hotkey mode setting")
    func chooseHandsFree() throws {
        let h = try Harness()
        let vm = h.viewModel(step: .hotkey).vm

        vm.choose(.handsFree)

        #expect(vm.hotkeyMode == .handsFree)
        #expect(h.dictationSettings.hotkeyMode == .handsFree)
    }

    @Test("model step: download() installs the default model and auto-advances to .tryIt")
    func modelDownloadAdvances() async throws {
        let h = try Harness()
        await h.serveAll()
        let (vm, _, models, _, _) = h.viewModel(step: .model)
        await models.refresh()
        await waitFor { vm.modelRow != nil }

        #expect(vm.modelRow?.model.id == "big")
        #expect(!vm.canContinue)

        await vm.download()

        #expect(vm.modelRow?.state == .installed)
        #expect(vm.canContinue)
        #expect(vm.step == .tryIt)
    }

    @Test("useSmallerModel switches selectedModelID to the smaller speech model")
    func useSmallerModel() async throws {
        let h = try Harness()
        await h.serveAll()
        let (vm, _, models, _, _) = h.viewModel(step: .model)
        await models.refresh()
        await waitFor { vm.modelRow != nil }

        vm.useSmallerModel()

        #expect(vm.modelRow?.model.id == "small")
    }

    @Test("model step (B-2/N-4): insufficient space surfaces the alert and stays on .model; useSmallerModelInsufficientSpace switches the row to the installed smaller model and auto-advances")
    func modelInsufficientSpaceAlert() async throws {
        var h = try Harness()
        await h.serveAll()
        h.freeSpace = FakeFreeSpace(available: 300_000 + ModelStore.reserveBytes - 1)   // not enough for "big"
        let (vm, _, models, _, _) = h.viewModel(step: .model)
        await models.refresh()
        await waitFor { vm.modelRow != nil }

        await vm.download()

        #expect(models.alert == .insufficientSpace(OnboardingViewModelTests.big,
                                                    required: 300_000 + ModelStore.reserveBytes,
                                                    available: 300_000 + ModelStore.reserveBytes - 1))
        #expect(vm.step == .model)   // never auto-advanced — the row never reached .installed
        #expect(!vm.canContinue)

        await vm.useSmallerModelInsufficientSpace()

        #expect(models.alert == nil)
        #expect(vm.modelRow?.model.id == "small")
        #expect(vm.modelRow?.state == .installed)
        #expect(vm.canContinue)
        // N-4: the alert-driven recovery must auto-advance too, not just the happy-path download() —
        // otherwise a successful SYS-DISK recovery leaves the user parked on ONB-04.
        #expect(vm.step == .tryIt)
    }

    @Test("resume at persisted step on init")
    func resumesAtPersistedStep() throws {
        let h = try Harness()
        let first = OnboardingState(store: h.store)
        first.step = .hotkey

        let resumed = OnboardingState(store: h.store)
        #expect(resumed.step == .hotkey)

        let vm = h.viewModel(step: .hotkey).vm
        #expect(vm.step == .hotkey)
    }

    @Test("finish() marks completed, resets step, requests the main window, and dismisses the onboarding window")
    func finishCompletes() throws {
        let h = try Harness()
        let (vm, state, _, _, _) = h.viewModel(step: .tryIt)
        var dismissed = false
        vm.dismiss = { dismissed = true }

        vm.finish()

        #expect(state.completed)
        #expect(state.step == .welcome)
        #expect(h.navigation.requestMainWindow)
        #expect(dismissed)
    }

    @Test("tryIt: beginTryIt() enters the ephemeral scope — a capture started while it's active isn't saved; .inserted still sets tryItResult")
    func tryItSuppressesHistory() async throws {
        let h = try Harness()
        let (vm, _, _, dc, scope) = h.viewModel(step: .tryIt)
        vm.beginTryIt()
        #expect(scope.isActive)

        dc.fn(.down)
        // `.armed(_)`/`.listening(_)` (explicit wildcard payload), not `if case .armed = $0` — same
        // toolchain quirk `DictationCoordinatorTests` works around.
        await waitFor { if case .armed(_) = dc.state { true } else { false } }
        await h.clock.advance(by: 0.3)   // past the 0.25 s hold threshold: armed → listening
        await waitFor { if case .listening(_) = dc.state { true } else { false } }
        dc.fn(.up)
        await waitFor { vm.tryItResult != nil }

        #expect(vm.tryItResult?.hasPrefix("✓ Inserted · 11 words") == true)
        #expect(try h.historyStore.count() == 0)
    }

    // MARK: B-1 — the try-it observation lifecycle must not leak past onboarding

    @Test("B-1: a fresh view model resuming with completed == true never enters the ephemeral scope, even on .tryIt")
    func completedNeverSuppresses() async throws {
        let h = try Harness()
        let (vm, _, _, dc, scope) = h.viewModel(step: .tryIt, completed: true)

        vm.beginTryIt()   // must no-op: onboarding is already completed
        #expect(scope.isActive == false)

        dc.fn(.down)
        await waitFor { if case .armed(_) = dc.state { true } else { false } }
        await h.clock.advance(by: 0.3)
        await waitFor { if case .listening(_) = dc.state { true } else { false } }
        dc.fn(.up)
        await waitFor { if case .inserted = dc.state { true } else { false } }
        await waitFor { (try? h.historyStore.count()) == 1 }

        #expect(try h.historyStore.count() == 1)   // never suppressed
    }

    @Test("B-1: finish() leaves the ephemeral scope — a dictation started after finish() is saved normally")
    func finishStopsObservation() async throws {
        let h = try Harness()
        let (vm, state, _, dc, scope) = h.viewModel(step: .tryIt)
        vm.beginTryIt()
        #expect(scope.isActive)

        vm.finish()
        #expect(state.completed)
        #expect(scope.isActive == false)

        dc.fn(.down)
        await waitFor { if case .armed(_) = dc.state { true } else { false } }
        await h.clock.advance(by: 0.3)
        await waitFor { if case .listening(_) = dc.state { true } else { false } }
        dc.fn(.up)
        await waitFor { if case .inserted = dc.state { true } else { false } }
        await waitFor { (try? h.historyStore.count()) == 1 }

        #expect(try h.historyStore.count() == 1)
    }

    @Test("B-1/M-2: leaving .tryIt (e.g. Back) after only arming leaves the ephemeral scope — the next capture is saved normally")
    func leavingTryItClearsSuppression() async throws {
        let h = try Harness()
        let (vm, _, _, dc, scope) = h.viewModel(step: .tryIt)
        vm.beginTryIt()
        #expect(scope.isActive)

        vm.back()   // leaves .tryIt without ever reaching .inserted
        #expect(scope.isActive == false)

        dc.fn(.down)
        await waitFor { if case .armed(_) = dc.state { true } else { false } }
        await h.clock.advance(by: 0.3)
        await waitFor { if case .listening(_) = dc.state { true } else { false } }
        dc.fn(.up)
        await waitFor { (try? h.historyStore.count()) == 1 }
        #expect(try h.historyStore.count() == 1)   // the stale suppression didn't eat this save
    }

    @Test("N-2: endTryIt() (e.g. the onboarding window closing mid-try-it) leaves the ephemeral scope; idempotent against a second call")
    func endTryItClearsSuppression() async throws {
        let h = try Harness()
        let (vm, _, _, _, scope) = h.viewModel(step: .tryIt)
        vm.beginTryIt()
        #expect(scope.isActive)

        vm.endTryIt()   // e.g. the window is closed instead of "Back"/"Start using VoxFlow"
        #expect(scope.isActive == false)

        vm.endTryIt()   // a second call (e.g. transition(to:) then onDisappear) must not go negative
        #expect(scope.isActive == false)
    }

    @Test("N-3: finish() resets the in-memory step to .welcome, not just the persisted one")
    func finishResetsInMemoryStep() throws {
        let h = try Harness()
        let vm = h.viewModel(step: .tryIt).vm

        vm.finish()

        #expect(vm.step == .welcome)
    }

    /// No-sleep poll, same technique as `ModelsViewModelTests`/`DictationCoordinatorTests`.
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<2_000 where !predicate() { await Task.yield() }
    }
}
