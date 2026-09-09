import Foundation
import Synchronization
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowModels
import VoxFlowSpeech
import VoxFlowStorage

/// Sendable pipe from `MeteredMicrophone`'s `@Sendable` level callback (called off the main actor)
/// into the main-actor `DictationCoordinator` — same `Mutex`-boxed pattern as `DictationSettingsBox`,
/// needed because `DictationCoordinator` itself isn't `Sendable`.
///
/// Holds the coordinator *weakly*: `dictation.controller.microphone.onLevel` closure captures this
/// sink, so a strong reference back to `dictation` here would close a retain cycle among
/// `dictation` → `dictationController` → `MeteredMicrophone` → sink → `dictation`, none of which
/// would ever deallocate as a group. `WeakBox` is a private, unchecked-by-the-compiler `weak var`
/// holder — sound because it only ever lives inside `Mutex`'s protected storage, which is what
/// makes concurrent mutation of that `weak var` safe, not an `@unchecked Sendable` on this type.
private final class DictationLevelSink: Sendable {
    private struct WeakBox { weak var coordinator: DictationCoordinator? }
    private let box = Mutex(WeakBox(coordinator: nil))
    func attach(_ coordinator: DictationCoordinator) { box.withLock { $0.coordinator = coordinator } }
    func report(_ rms: Float) {
        Task { @MainActor in self.box.withLock { $0.coordinator }?.reportLevel(rms) }
    }
}

/// Composition root: the real engine, decoder, model store and queue, built once per app run.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices.live()

    let modelStore: ModelStore
    let engine: WhisperCppEngine
    let queue: FileQueue
    let filesSettings: FilesSettings
    let durations: AudioDurationReader
    /// Built right after `queue` — its subscription must exist before anything can `start()` the
    /// queue, so the Dock-open path (queue running while the Files page isn't shown) still exports.
    let exports: ExportCoordinator
    let navigation: Navigation
    /// Built once here (not per-view `@State`) so `FilesPage` keeps the same view model — and the
    /// same in-memory queue subscription — across every navigation away from and back to Files.
    let filesViewModel: FilesViewModel
    /// Same reasoning as `filesViewModel`: `SettingsPage`/`ModelsSettingsView` read this instead of
    /// each owning their own, so a download started before leaving Settings keeps being tracked.
    let modelsViewModel: ModelsViewModel
    /// Settings › Audio (ST-04) — built once here so `SettingsPage` keeps reading the same instance.
    let audioViewModel: AudioViewModel
    /// Settings › Privacy (ST-05) — same reasoning as `audioViewModel`.
    let privacyViewModel: PrivacyViewModel

    let dictationSettings: DictationSettings
    /// Shared with the Files `LazyModelFileTranscriber` (ruling 9: one place knows which model is loaded).
    let modelLoader: ModelLoader
    /// Owns the `DictationStore`/`RetentionRunner`; `historyService.status` is `.disabled(reason:)`
    /// when history storage is unavailable this launch (see `StorageError.keyLost`) or reopening failed.
    let historyService: HistoryService
    /// Drives the History page (design MW-02) — built once here so navigating away and back keeps
    /// its search/expanded/undo state, same reasoning as `filesViewModel`.
    let historyViewModel: HistoryViewModel
    let inserter: AccessibilityTextInserter
    /// Entered/left by onboarding's Try It step and History's scratchpad sheet — read once at the
    /// start of every capture (`dictationController`'s `ephemeral:` closure) to decide whether that
    /// capture should be written to History (I-1/I-2/I-3). See `EphemeralScope`'s doc comment.
    let ephemeralScope: EphemeralScope
    let dictationController: DictationController
    let dictation: DictationCoordinator
    let flowBar: FlowBarPresenter
    let fnMonitor: FnKeyMonitor
    /// Persisted onboarding progress (design ONB-01…05) — `AppDelegate` checks `.completed` on first
    /// launch to decide whether to show the onboarding window instead of the main one.
    let onboardingState: OnboardingState
    let onboardingViewModel: OnboardingViewModel

    private init(modelStore: ModelStore, engine: WhisperCppEngine, queue: FileQueue, filesSettings: FilesSettings,
                 durations: AudioDurationReader, exports: ExportCoordinator, navigation: Navigation,
                 filesViewModel: FilesViewModel, modelsViewModel: ModelsViewModel, audioViewModel: AudioViewModel,
                 privacyViewModel: PrivacyViewModel, dictationSettings: DictationSettings,
                 modelLoader: ModelLoader, historyService: HistoryService, historyViewModel: HistoryViewModel,
                 inserter: AccessibilityTextInserter, ephemeralScope: EphemeralScope, dictationController: DictationController,
                 dictation: DictationCoordinator, flowBar: FlowBarPresenter, fnMonitor: FnKeyMonitor,
                 onboardingState: OnboardingState, onboardingViewModel: OnboardingViewModel) {
        self.modelStore = modelStore
        self.engine = engine
        self.queue = queue
        self.filesSettings = filesSettings
        self.durations = durations
        self.exports = exports
        self.navigation = navigation
        self.filesViewModel = filesViewModel
        self.modelsViewModel = modelsViewModel
        self.audioViewModel = audioViewModel
        self.privacyViewModel = privacyViewModel
        self.dictationSettings = dictationSettings
        self.modelLoader = modelLoader
        self.historyService = historyService
        self.historyViewModel = historyViewModel
        self.inserter = inserter
        self.ephemeralScope = ephemeralScope
        self.dictationController = dictationController
        self.dictation = dictation
        self.flowBar = flowBar
        self.fnMonitor = fnMonitor
        self.onboardingState = onboardingState
        self.onboardingViewModel = onboardingViewModel
    }

    static func live() -> AppServices {
        let settingsStore = UserDefaultsKeyValueStore()
        let modelStore = ModelStore(directory: ModelStore.defaultDirectory, downloader: RangeResumingDownloader(),
                                    freeSpace: VolumeFreeSpace(), settings: settingsStore)
        let engine = WhisperCppEngine()
        let filesSettings = FilesSettings(store: settingsStore)
        let snapshot = filesSettings.optionsSnapshot
        let modelLoader = ModelLoader(store: modelStore, engine: engine)
        let transcriber = LazyModelFileTranscriber(loader: modelLoader, store: modelStore, engine: engine, decoder: AudioDecoder())
        let durations = AudioDurationReader()
        let queue = FileQueue(transcriber: transcriber, durations: durations,
                              supportedExtensions: SupportedAudio.extensions,
                              options: { snapshot.current })
        let exports = ExportCoordinator(queue: queue, settings: filesSettings,
                                        exporter: { TranscriptExporter(directory: filesSettings.outputFolder) })
        let filesViewModel = FilesViewModel(queue: queue, settings: filesSettings, modelStore: modelStore,
                                            durations: durations, exports: exports)
        let modelsViewModel = ModelsViewModel(store: modelStore)
        let navigation = Navigation()

        let dictationSettings = DictationSettings(store: settingsStore)
        let permissions = SystemPermissions()
        let frontmost = WorkspaceFrontmostApp()
        let inserter = AccessibilityTextInserter(permissions: permissions, pasteboard: SystemPasteboard())

        // `HistoryService` owns opening/reopening the store (and its `RetentionRunner`) off the main
        // actor; `.keyLost` (the original key material is gone, e.g. a Keychain reset) and other open
        // failures land in `historyService.status` and are logged inside the service.
        let historyService = HistoryService(url: DictationStore.defaultURL, settings: dictationSettings,
                                            keyProvider: { HistoryKeyProviders.default() }, clock: SystemMonotonicClock())

        let historyWriter = HistoryWriter(storeBox: historyService.storeBox, settings: dictationSettings.box, now: Date.init,
                                          ready: { await historyService.ready() })

        // Built fresh on every fn-down (not once, up front) so a Settings edit to the excluded-apps
        // list or hotkey mode applies to the very next capture rather than only after a relaunch.
        let preflight: @Sendable () async -> Preflight = {
            let builder = PreflightBuilder(frontmost: frontmost, permissions: permissions,
                                           readiness: { await modelLoader.readiness() },
                                           settings: dictationSettings.box.current,
                                           captureFocus: { app in await inserter.captureFocus(app: app) })
            return await builder.preflight()
        }

        // `dictation` is assigned after `dictationController` below — the microphone needs to report
        // levels into the coordinator, but the coordinator needs the (already-built) controller.
        // `levelSink` carries the level callback across that gap without capturing the (non-Sendable)
        // coordinator itself in the microphone's `@Sendable` closure.
        let levelSink = DictationLevelSink()
        // Entered/left by onboarding's Try It step and History's scratchpad sheet — read once at the
        // start of every capture below so an onboarding/scratchpad dictation is never written to
        // History (I-1/I-2/I-3), replacing the old shared `HistoryWriter` suppression flag.
        let ephemeralScope = EphemeralScope()
        let dictationController = DictationController(
            config: dictationSettings.flowBarConfig,
            microphone: MeteredMicrophone(base: MicrophoneSource()) { rms in levelSink.report(rms) },
            transcriber: WindowedTranscriber(engine: engine),
            inserter: inserter,
            clock: SystemMonotonicClock(),
            preflight: preflight,
            loadModel: { _ = try await modelLoader.ensureLoaded() },
            options: { dictationSettings.box.current.options },
            onSave: { result, appName in await historyWriter.save(result, appName: appName) },
            copyToClipboard: { SystemPasteboard().setString($0) },
            ephemeral: { ephemeralScope.isActive }
        )
        let dictation = DictationCoordinator(controller: dictationController, settings: dictationSettings,
                                             permissions: permissions, navigation: navigation)
        levelSink.attach(dictation)

        // History's "Try it in a scratchpad" (design 2d) enters/leaves `ephemeralScope` from its own
        // sheet view (`HistoryPage.ScratchpadSheet`) — this view model doesn't need to know about it.
        let historyViewModel = HistoryViewModel(service: historyService, settings: dictationSettings, navigation: navigation,
                                                clock: SystemMonotonicClock(), pasteboard: SystemPasteboard())

        // Live settings: a silence-stop change reaches the running controller without waiting for
        // the next dictation to start it fresh; an encryption/retention change reopens the store.
        dictationSettings.onConfigChange = { config in Task { await dictationController.updateConfig(config) } }
        dictationSettings.onHistorySettingsChange = { historyService.reopen() }

        let flowBarPanel = FlowBarPanel(rootView: FlowBarView(coordinator: dictation))
        let flowBar = FlowBarPresenter(panel: flowBarPanel, scheduler: TaskHideScheduler())

        let fnMonitor = FnKeyMonitor(
            onFn: { dictation.fn($0) },
            onEscape: { dictation.escape() },
            onAnyKey: { dictation.anyKey() },
            isHUDActive: { dictation.isHUDActive }
        )

        let onboardingState = OnboardingState(store: settingsStore)
        let onboardingViewModel = OnboardingViewModel(state: onboardingState, permissions: permissions, settings: dictationSettings,
                                                       models: modelsViewModel, dictation: dictation, ephemeralScope: ephemeralScope,
                                                       navigation: navigation, clock: SystemMonotonicClock())

        let audioViewModel = AudioViewModel(devices: AVCaptureInputDeviceProvider(), settings: dictationSettings, dictation: dictation)
        let privacyViewModel = PrivacyViewModel(settings: dictationSettings, history: historyService, apps: WorkspaceInstalledApps())

        return AppServices(modelStore: modelStore, engine: engine, queue: queue, filesSettings: filesSettings,
                           durations: durations, exports: exports, navigation: navigation, filesViewModel: filesViewModel,
                           modelsViewModel: modelsViewModel, audioViewModel: audioViewModel, privacyViewModel: privacyViewModel,
                           dictationSettings: dictationSettings, modelLoader: modelLoader,
                           historyService: historyService, historyViewModel: historyViewModel, inserter: inserter,
                           ephemeralScope: ephemeralScope, dictationController: dictationController, dictation: dictation,
                           flowBar: flowBar, fnMonitor: fnMonitor,
                           onboardingState: onboardingState, onboardingViewModel: onboardingViewModel)
    }

    var exporter: TranscriptExporter { TranscriptExporter(directory: filesSettings.outputFolder) }
}
