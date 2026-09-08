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

    private init(modelStore: ModelStore, engine: WhisperCppEngine, queue: FileQueue, filesSettings: FilesSettings,
                 durations: AudioDurationReader, exports: ExportCoordinator) {
        self.modelStore = modelStore
        self.engine = engine
        self.queue = queue
        self.filesSettings = filesSettings
        self.durations = durations
        self.exports = exports
    }

    static func live() -> AppServices {
        let settingsStore = UserDefaultsKeyValueStore()
        let modelStore = ModelStore(directory: ModelStore.defaultDirectory, downloader: RangeResumingDownloader(),
                                    freeSpace: VolumeFreeSpace(), settings: settingsStore)
        let engine = WhisperCppEngine()
        let filesSettings = FilesSettings(store: settingsStore)
        let snapshot = filesSettings.optionsSnapshot
        let transcriber = LazyModelFileTranscriber(store: modelStore, engine: engine, decoder: AudioDecoder())
        let durations = AudioDurationReader()
        let queue = FileQueue(transcriber: transcriber, durations: durations,
                              supportedExtensions: SupportedAudio.extensions,
                              options: { snapshot.current })
        let exports = ExportCoordinator(queue: queue, settings: filesSettings,
                                        exporter: { TranscriptExporter(directory: filesSettings.outputFolder) })
        return AppServices(modelStore: modelStore, engine: engine, queue: queue, filesSettings: filesSettings,
                           durations: durations, exports: exports)
    }

    var exporter: TranscriptExporter { TranscriptExporter(directory: filesSettings.outputFolder) }
}
