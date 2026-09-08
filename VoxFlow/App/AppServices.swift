import Foundation
import VoxFlowAudio
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowSpeech

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
    let navigation = Navigation()
    /// Built once here (not per-view `@State`) so `FilesPage` keeps the same view model — and the
    /// same in-memory queue subscription — across every navigation away from and back to Files.
    let filesViewModel: FilesViewModel
    /// Same reasoning as `filesViewModel`: `SettingsPage`/`ModelsSettingsView` read this instead of
    /// each owning their own, so a download started before leaving Settings keeps being tracked.
    let modelsViewModel: ModelsViewModel

    private init(modelStore: ModelStore, engine: WhisperCppEngine, queue: FileQueue, filesSettings: FilesSettings,
                 durations: AudioDurationReader, exports: ExportCoordinator, filesViewModel: FilesViewModel,
                 modelsViewModel: ModelsViewModel) {
        self.modelStore = modelStore
        self.engine = engine
        self.queue = queue
        self.filesSettings = filesSettings
        self.durations = durations
        self.exports = exports
        self.filesViewModel = filesViewModel
        self.modelsViewModel = modelsViewModel
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
        return AppServices(modelStore: modelStore, engine: engine, queue: queue, filesSettings: filesSettings,
                           durations: durations, exports: exports, filesViewModel: filesViewModel,
                           modelsViewModel: modelsViewModel)
    }

    var exporter: TranscriptExporter { TranscriptExporter(directory: filesSettings.outputFolder) }
}
