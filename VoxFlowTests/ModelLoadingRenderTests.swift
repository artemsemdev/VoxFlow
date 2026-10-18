import AppKit
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct ModelLoadingRenderTests {
    private static let speechModel = ModelDescriptor(
        id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", role: .speech,
        downloadURL: URL(string: "https://example.invalid/model.bin")!, sizeInBytes: 1_624_555_275,
        sha256: "fixture", languagesSummary: "99 languages", isDefault: true)

    @Test("renders the production Files and Models first-use loading rows")
    func renderLoadingRows() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try await makeFilesFixture()

        let modelStore = ModelStore(directory: TemporaryDirectory().url, catalog: [], downloader: FakeModelDownloader(),
                                    freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        let models = ModelsViewModel(store: modelStore, catalog: [])
        let modelRow = ModelsViewModel.Row(model: Self.speechModel, state: .installed, isDefault: true,
                                           isLoadingIntoMemory: true)
        let content = VStack(spacing: 24) {
            QueueRowView(item: fixture.item, model: fixture.viewModel)
                .frame(width: 620)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            ModelsSettingsView(model: models).rowView(modelRow)
                .frame(width: 620)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(24)

        for dark in [false, true] {
            let host = NativeRenderHost(content, size: NSSize(width: 700, height: 240), dark: dark)
            defer { host.close() }
            try host.capture(to: directory.appendingPathComponent("Model-loading-\(dark ? "dark" : "light").png"))
        }
        await fixture.queue.cancel(id: fixture.item.id)
        await fixture.queue.waitUntilIdle()
    }

    private func makeFilesFixture() async throws -> (queue: FileQueue, viewModel: FilesViewModel, item: QueueItem) {
        let url = URL(fileURLWithPath: "/tmp/interview-raw.m4a")
        let transcriber = FakeFileTranscriber()
        await transcriber.setLoadingModelID(Self.speechModel.id)
        await transcriber.setProgressSteps([])
        await transcriber.hold(url)
        await transcriber.script(url, .document(TranscriptDocument(sourceURL: url, transcript: Transcript(segments: [], language: "en"),
            modelID: Self.speechModel.id, audioDuration: 2_892, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))))
        let queue = FileQueue(transcriber: transcriber, durations: FakeAudioDuration([url: 2_892]),
                              supportedExtensions: ["m4a"], options: { TranscriptionOptions() })
        let settings = FilesSettings(store: InMemoryKeyValueStore())
        let store = ModelStore(directory: TemporaryDirectory().url, catalog: [], downloader: FakeModelDownloader(),
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        let exports = ExportCoordinator(queue: queue, settings: settings,
                                         exporter: { TranscriptExporter(directory: TemporaryDirectory().url) })
        let viewModel = FilesViewModel(queue: queue, settings: settings, modelStore: store,
                                       durations: FakeAudioDuration([url: 2_892]), exports: exports)
        let events = await queue.subscribe()
        _ = await queue.add([url])
        await queue.start()
        await transcriber.waitUntilHeld(url)
        for await event in events {
            if case .changed(let item) = event,
               item.status == .loadingModel(modelID: Self.speechModel.id) {
                return (queue, viewModel, item)
            }
        }
        Issue.record("queue event stream ended before the loading-model state")
        return (queue, viewModel, try #require(await queue.items.first))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
    }
}
