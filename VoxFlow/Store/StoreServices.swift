import AppKit
import AVFoundation
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowModels
import VoxFlowSpeech

/// A separate composition root: no Accessibility, global input monitor, MCP, or shared user data.
@Observable @MainActor
final class StoreServices {
    static let shared = StoreServices()
    let engine: WhisperCppEngine
    let modelLoader: ModelLoader
    let models: ModelsViewModel
    let settings: FilesSettings
    let queue: FileQueue
    let exports: ExportCoordinator
    let files: FilesViewModel
    let draft: StoreDraft
    let dictation: DictationController
    var state: FlowBarState = .idle
    var isRequestingMicrophone = false
    private var inputAccess: Set<URL> = []

    private init() {
        let preferences = UserDefaultsKeyValueStore()
        let store = ModelStore(directory: ModelStore.defaultDirectory,
            downloader: RangeResumingDownloader(), freeSpace: VolumeFreeSpace(), settings: preferences)
        let engine = WhisperCppEngine()
        self.engine = engine
        let loader = ModelLoader(store: store, engine: engine)
        modelLoader = loader
        models = ModelsViewModel(store: store, modelLoader: loader)
        let settings = FilesSettings(store: preferences)
        self.settings = settings
        let options = settings.optionsSnapshot
        let transcriber = LazyModelFileTranscriber(loader: loader, store: store, engine: engine.fileEngine, decoder: AudioDecoder())
        let durations = AudioDurationReader()
        let queue = FileQueue(transcriber: transcriber, durations: durations,
                              supportedExtensions: SupportedAudio.extensions, options: { options.current })
        self.queue = queue
        let exports = ExportCoordinator(queue: queue, settings: settings, exporter: { settings.makeExporter() })
        self.exports = exports
        files = FilesViewModel(queue: queue, settings: settings, modelStore: store, durations: durations, exports: exports)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let draft = StoreDraft(url: root.appending(path: "VoxFlow/draft.txt"))
        self.draft = draft
        dictation = DictationController(config: FlowBarConfig(silenceStop: 10), microphone: MicrophoneSource(),
            transcriber: WindowedTranscriber(engine: engine), inserter: draft, clock: SystemMonotonicClock(),
            preflight: {
                Preflight(excludedApp: nil, secureInput: false,
                    microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied,
                    model: await loader.readiness())
            }, loadModel: { _ = try await loader.ensureLoaded() }, options: { options.current },
            onSave: { _, _ in }, copyToClipboard: { SystemPasteboard().setString($0) })
    }

    func observeDictation() async {
        for await value in await dictation.currentAndChanges() {
            guard !Task.isCancelled else { return }
            state = value
        }
    }

    func startDictation() async {
        guard !state.hasUnfinishedCapture, !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        await dictation.shortcutDown(.handsFree)
        isRequestingMicrophone = false
    }

    /// Keep the picker grants alive through duration inspection, queueing and decoding.
    func importFiles(_ urls: [URL]) async {
        for url in urls where !inputAccess.contains(url) {
            if url.startAccessingSecurityScopedResource() { inputAccess.insert(url) }
        }
        await files.addFiles(urls)
    }

    func releaseInputAccess() {
        for url in inputAccess { url.stopAccessingSecurityScopedResource() }
        inputAccess.removeAll()
    }
}
