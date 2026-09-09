import CryptoKit
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Records every `authorize()`/`post(_:)` call, `Mutex`-protected so it stays `Sendable` without
/// `@unchecked` — same reasoning as `UserNotificationsPoster.routes`.
private final class FakePoster: NotificationPosting, Sendable {
    private struct State { var authorizeCount = 0; var posted: [AppNotification] = [] }
    private let state = Mutex(State())

    func authorize() async -> Bool {
        state.withLock { $0.authorizeCount += 1 }
        return true
    }

    func post(_ notification: AppNotification) {
        state.withLock { $0.posted.append(notification) }
    }

    var authorizeCount: Int { state.withLock { $0.authorizeCount } }
    var posted: [AppNotification] { state.withLock { $0.posted } }
}

@Suite("NotificationCoordinator") @MainActor
struct NotificationCoordinatorTests {
    static let fileURL = URL(fileURLWithPath: "/tmp/interview-raw.m4a")

    static func document(duration: TimeInterval) -> TranscriptDocument {
        TranscriptDocument(sourceURL: fileURL, transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "ok")!], language: "en"),
                           modelID: "m", audioDuration: duration, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: Files harness (mirrors `ExportCoordinatorTests.Harness`)

    @MainActor
    struct FilesHarness {
        let dir = TemporaryDirectory()
        let transcriber = FakeFileTranscriber()
        let durations = FakeAudioDuration([NotificationCoordinatorTests.fileURL: 65])
        let filesSettings = FilesSettings(store: InMemoryKeyValueStore())
        let queue: FileQueue
        let exports: ExportCoordinator
        let filesViewModel: FilesViewModel

        init() {
            let modelStore = ModelStore(directory: dir.file("Models"), downloader: FakeModelDownloader(),
                                        freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: InMemoryKeyValueStore())
            let transcriptsDirectory = dir.file("Transcripts")   // a local (not `self.dir`), so the escaping `exporter` closure below doesn't capture `self` before every stored property is set
            queue = FileQueue(transcriber: transcriber, durations: durations, supportedExtensions: SupportedAudio.extensions,
                              options: { TranscriptionOptions() })
            exports = ExportCoordinator(queue: queue, settings: filesSettings, exporter: { TranscriptExporter(directory: transcriptsDirectory) })
            filesViewModel = FilesViewModel(queue: queue, settings: filesSettings, modelStore: modelStore,
                                            durations: durations, exports: exports)
        }

        func settle() async {
            await queue.waitUntilIdle()
            for _ in 0..<50 { await Task.yield() }
        }
    }

    // MARK: Models harness (mirrors `ModelsViewModelTests.Harness`, minimally)

    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    static let modelPayload = payload(1, count: 1_000)
    static let model = ModelDescriptor(id: "m1", displayName: "Whisper small", role: .speech,
                                       downloadURL: URL(string: "https://example.com/m1.bin")!,
                                       sizeInBytes: Int64(modelPayload.count),
                                       sha256: SHA256.hash(data: modelPayload).map { String(format: "%02x", $0) }.joined(),
                                       languagesSummary: "test", isDefault: true)

    @MainActor
    struct ModelsHarness {
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        func store() -> ModelStore {
            ModelStore(directory: dir.url, catalog: [NotificationCoordinatorTests.model], downloader: downloader,
                      freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: InMemoryKeyValueStore())
        }
        func viewModel() -> ModelsViewModel { ModelsViewModel(store: store(), catalog: [NotificationCoordinatorTests.model]) }
        func serve() async { await downloader.serve(NotificationCoordinatorTests.modelPayload, at: NotificationCoordinatorTests.model.downloadURL) }
    }

    private func coordinator(files: FilesHarness, poster: FakePoster, models: ModelsViewModel,
                             navigation: Navigation, isFrontmost: @escaping () -> Bool) -> NotificationCoordinator {
        NotificationCoordinator(posting: poster, isFrontmost: isFrontmost, navigation: navigation, queue: files.queue,
                                modelsViewModel: models, filesViewModel: files.filesViewModel,
                                outputFormat: { files.filesSettings.outputFormat })
    }

    // MARK: Files (MB-04)

    @Test("a finished transcription posts nothing while the main window is frontmost")
    func fileFrontmostPostsNothing() async throws {
        let files = FilesHarness()
        await files.transcriber.script(Self.fileURL, .document(Self.document(duration: 65)))
        let poster = FakePoster()
        let models = ModelsHarness().viewModel()
        let coordinator = coordinator(files: files, poster: poster, models: models, navigation: Navigation(), isFrontmost: { true })
        coordinator.start()

        await files.queue.add([Self.fileURL])
        await files.queue.start()
        await files.settle()

        #expect(poster.posted.isEmpty)
        #expect(poster.authorizeCount == 0)
    }

    @Test("a finished transcription posts exactly one notification with the exact MB-04 copy while backgrounded")
    func fileBackgroundPostsExactCopy() async throws {
        let files = FilesHarness()
        await files.transcriber.script(Self.fileURL, .document(Self.document(duration: 65)))
        let poster = FakePoster()
        let models = ModelsHarness().viewModel()
        let coordinator = coordinator(files: files, poster: poster, models: models, navigation: Navigation(), isFrontmost: { false })
        coordinator.start()

        await files.queue.add([Self.fileURL])
        await files.queue.start()
        await files.settle()

        let item = try #require(await files.queue.items.first)
        #expect(poster.posted.count == 1)
        let notification = try #require(poster.posted.first)
        #expect(notification.title == "VoxFlow")
        #expect(notification.body == "interview-raw.m4a transcribed · 1:05 · TXT saved to ~/Transcripts")
        #expect(notification.route == .filesResult(itemID: item.id))
        #expect(poster.authorizeCount == 1)
    }

    @Test("a failed transcription never posts, frontmost or not")
    func fileFailureNeverPosts() async throws {
        let files = FilesHarness()
        await files.transcriber.script(Self.fileURL, .failure(.engineFailed("boom")))
        let poster = FakePoster()
        let models = ModelsHarness().viewModel()
        let coordinator = coordinator(files: files, poster: poster, models: models, navigation: Navigation(), isFrontmost: { false })
        coordinator.start()

        await files.queue.add([Self.fileURL])
        await files.queue.start()
        await files.settle()

        #expect(poster.posted.isEmpty)
    }

    @Test("a file click routes to the Files result for that row")
    func fileClickRoutes() async throws {
        let files = FilesHarness()
        await files.transcriber.script(Self.fileURL, .document(Self.document(duration: 65)))
        await files.queue.add([Self.fileURL])
        await files.queue.start()
        await files.settle()
        let item = try #require(await files.queue.items.first)

        let navigation = Navigation()
        let coordinator = coordinator(files: files, poster: FakePoster(), models: ModelsHarness().viewModel(),
                                      navigation: navigation, isFrontmost: { false })
        coordinator.handleRoute(.filesResult(itemID: item.id))

        #expect(navigation.requestMainWindow)
        #expect(navigation.page == .files)
        #expect(files.filesViewModel.selected?.item.id == item.id)
    }

    // MARK: Models (MB-03)

    @Test("a model finishing its install posts nothing while the main window is frontmost")
    func modelInstallFrontmostPostsNothing() async throws {
        let files = FilesHarness()
        let modelsHarness = ModelsHarness()
        await modelsHarness.serve()
        let models = modelsHarness.viewModel()
        await models.refresh()
        let poster = FakePoster()
        let coordinator = coordinator(files: files, poster: poster, models: models, navigation: Navigation(), isFrontmost: { true })
        coordinator.start()

        await models.download(Self.model)
        for _ in 0..<50 { await Task.yield() }

        #expect(poster.posted.isEmpty)
    }

    @Test("a model finishing its install posts exactly one notification with the exact MB-03 copy while backgrounded")
    func modelInstallBackgroundPostsExactCopy() async throws {
        let files = FilesHarness()
        let modelsHarness = ModelsHarness()
        await modelsHarness.serve()
        let models = modelsHarness.viewModel()
        await models.refresh()
        let poster = FakePoster()
        let coordinator = coordinator(files: files, poster: poster, models: models, navigation: Navigation(), isFrontmost: { false })
        coordinator.start()

        await models.download(Self.model)
        for _ in 0..<50 { await Task.yield() }

        #expect(poster.posted.count == 1)
        let notification = try #require(poster.posted.first)
        #expect(notification.body == "Whisper small installed. Ready to use offline.")
        #expect(notification.route == .settingsModels)
    }

    @Test("a model already installed when the coordinator starts never fires a spurious notification")
    func modelAlreadyInstalledDoesNotFire() async throws {
        let files = FilesHarness()
        let modelsHarness = ModelsHarness()
        await modelsHarness.serve()
        let models = modelsHarness.viewModel()
        await models.download(Self.model)   // installed before the coordinator ever starts
        await models.refresh()
        #expect(models.speechRows.first?.state == .installed)

        let poster = FakePoster()
        let coordinator = coordinator(files: files, poster: poster, models: models, navigation: Navigation(), isFrontmost: { false })
        coordinator.start()
        for _ in 0..<20 { await Task.yield() }

        #expect(poster.posted.isEmpty)
    }

    @Test("a model click routes to Settings › Models")
    func modelClickRoutes() async throws {
        let files = FilesHarness()
        let navigation = Navigation()
        let coordinator = coordinator(files: files, poster: FakePoster(), models: ModelsHarness().viewModel(),
                                      navigation: navigation, isFrontmost: { false })
        coordinator.handleRoute(.settingsModels)

        #expect(navigation.requestMainWindow)
        #expect(navigation.page == .settings)
        #expect(navigation.settingsTab == .models)
    }

    // MARK: Pure duration formatting (design MB-04: "m:ss or h:mm:ss")

    @Test("durationText formats under an hour as m:ss and at/past an hour as h:mm:ss")
    func durationText() {
        #expect(NotificationCoordinator.durationText(0) == "0:00")
        #expect(NotificationCoordinator.durationText(65) == "1:05")
        #expect(NotificationCoordinator.durationText(3599) == "59:59")
        #expect(NotificationCoordinator.durationText(3600) == "1:00:00")
        #expect(NotificationCoordinator.durationText(3725) == "1:02:05")
    }
}
