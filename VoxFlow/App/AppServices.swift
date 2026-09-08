import Foundation
import os
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

    let dictationSettings: DictationSettings
    /// Shared with the Files `LazyModelFileTranscriber` (ruling 9: one place knows which model is loaded).
    let modelLoader: ModelLoader
    /// `nil` when history storage is unavailable this launch (see `StorageError.keyLost` in `live()`).
    let dictationStore: DictationStore?
    let retention: RetentionRunner?
    let inserter: AccessibilityTextInserter
    let dictationController: DictationController
    let dictation: DictationCoordinator
    let flowBar: FlowBarPresenter
    let fnMonitor: FnKeyMonitor

    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "app-services")

    private init(modelStore: ModelStore, engine: WhisperCppEngine, queue: FileQueue, filesSettings: FilesSettings,
                 durations: AudioDurationReader, exports: ExportCoordinator, navigation: Navigation,
                 filesViewModel: FilesViewModel, modelsViewModel: ModelsViewModel, dictationSettings: DictationSettings,
                 modelLoader: ModelLoader, dictationStore: DictationStore?, retention: RetentionRunner?,
                 inserter: AccessibilityTextInserter, dictationController: DictationController,
                 dictation: DictationCoordinator, flowBar: FlowBarPresenter, fnMonitor: FnKeyMonitor) {
        self.modelStore = modelStore
        self.engine = engine
        self.queue = queue
        self.filesSettings = filesSettings
        self.durations = durations
        self.exports = exports
        self.navigation = navigation
        self.filesViewModel = filesViewModel
        self.modelsViewModel = modelsViewModel
        self.dictationSettings = dictationSettings
        self.modelLoader = modelLoader
        self.dictationStore = dictationStore
        self.retention = retention
        self.inserter = inserter
        self.dictationController = dictationController
        self.dictation = dictation
        self.flowBar = flowBar
        self.fnMonitor = fnMonitor
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

        // `try?` would discard which failure happened; `.keyLost` (the original key material is gone,
        // e.g. a Keychain reset) is worth a log line, since it silently turns history off this launch.
        var dictationStore: DictationStore?
        do {
            dictationStore = try DictationStore(databaseURL: DictationStore.defaultURL,
                                                keyProvider: dictationSettings.encryptHistory ? HistoryKeyProviders.default() : nil)
        } catch StorageError.keyLost {
            log.error("history key lost — history disabled for this launch")
        } catch {
            log.error("history store unavailable, history disabled for this launch: \(String(describing: error))")
        }

        // Reads the persisted value straight from `settingsStore` (Sendable) rather than
        // `dictationSettings.retentionDays` (a main-actor-isolated `var`), which a `@Sendable`
        // closure called from the actor's own executor cannot touch directly. `DictationSettings.Keys`
        // is the single source of truth for the key name, so this can't silently drift from what
        // `DictationSettings` itself persists to.
        let retention: RetentionRunner? = dictationStore.map { store in
            RetentionRunner(store: store,
                            policy: { RetentionPolicy(days: settingsStore.string(forKey: DictationSettings.Keys.retentionDays).flatMap(Int.init) ?? 30) },
                            now: Date.init, clock: SystemMonotonicClock())
        }
        if let retention { Task { await retention.start() } }

        let historyWriter = HistoryWriter(store: dictationStore, settings: dictationSettings.box, now: Date.init)

        // Built fresh on every fn-down (not once, up front) so a Settings edit to the excluded-apps
        // list or hotkey mode applies to the very next capture rather than only after a relaunch.
        let preflight: @Sendable () async -> Preflight = {
            let builder = PreflightBuilder(frontmost: frontmost, permissions: permissions,
                                           readiness: { await modelLoader.readiness() },
                                           settings: dictationSettings.box.current,
                                           captureFocus: { inserter.captureFocus() })
            return await builder.preflight()
        }

        // `dictation` is assigned after `dictationController` below — the microphone needs to report
        // levels into the coordinator, but the coordinator needs the (already-built) controller.
        // `levelSink` carries the level callback across that gap without capturing the (non-Sendable)
        // coordinator itself in the microphone's `@Sendable` closure.
        let levelSink = DictationLevelSink()
        let dictationController = DictationController(
            config: dictationSettings.flowBarConfig,
            microphone: MeteredMicrophone(base: MicrophoneSource()) { rms in levelSink.report(rms) },
            transcriber: WindowedTranscriber(engine: engine),
            inserter: inserter,
            clock: SystemMonotonicClock(),
            preflight: preflight,
            loadModel: { try await modelLoader.ensureLoaded() },
            options: { dictationSettings.box.current.options },
            onSave: { result, appName in await historyWriter.save(result, appName: appName) },
            copyToClipboard: { SystemPasteboard().setString($0) }
        )
        let dictation = DictationCoordinator(controller: dictationController, settings: dictationSettings,
                                             permissions: permissions, navigation: navigation)
        levelSink.attach(dictation)

        let flowBarPanel = FlowBarPanel(rootView: FlowBarView(coordinator: dictation))
        let flowBar = FlowBarPresenter(panel: flowBarPanel, scheduler: TaskHideScheduler())

        let fnMonitor = FnKeyMonitor(
            onFn: { dictation.fn($0) },
            onEscape: { dictation.escape() },
            onAnyKey: { dictation.anyKey() },
            isHUDActive: { dictation.isHUDActive }
        )

        return AppServices(modelStore: modelStore, engine: engine, queue: queue, filesSettings: filesSettings,
                           durations: durations, exports: exports, navigation: navigation, filesViewModel: filesViewModel,
                           modelsViewModel: modelsViewModel, dictationSettings: dictationSettings, modelLoader: modelLoader,
                           dictationStore: dictationStore, retention: retention, inserter: inserter,
                           dictationController: dictationController, dictation: dictation, flowBar: flowBar, fnMonitor: fnMonitor)
    }

    var exporter: TranscriptExporter { TranscriptExporter(directory: filesSettings.outputFolder) }
}
