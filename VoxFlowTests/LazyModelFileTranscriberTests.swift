import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

struct StubDecoder: AudioDecoding {
    func decode(_ url: URL) throws -> AudioSamples { AudioSamples([Float](repeating: 0, count: 16_000)) }
}

@Suite("LazyModelFileTranscriber")
struct LazyModelFileTranscriberTests {
    @Test("first use reports model loading before inference progress")
    func loadingPrecedesProgress() async throws {
        let dir = TemporaryDirectory()
        let payload = Data(repeating: 1, count: 1000)
        let model = ModelDescriptor(id: "m", displayName: "m", role: .speech, downloadURL: URL(string: "https://x/m.bin")!,
                                    sizeInBytes: 1000, sha256: SHA256File.hexDigest(of: payload), languagesSummary: "", isDefault: true)
        let downloader = FakeModelDownloader()
        await downloader.serve(payload, at: model.downloadURL)
        let store = ModelStore(directory: dir.url, catalog: [model], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        for try await _ in await store.install(id: "m") {}
        let engine = FakeSpeechEngine(script: [.progress(0.25)])
        let transcriber = LazyModelFileTranscriber(loader: ModelLoader(store: store, engine: engine), store: store,
                                                   engine: engine, decoder: StubDecoder())
        let updates = Mutex<[FileTranscriptionUpdate]>([])

        _ = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/a.wav"), options: TranscriptionOptions(language: "en")) {
            update in updates.withLock { $0.append(update) }
        }

        let observed = updates.withLock { $0 }
        #expect(observed.first == .loadingModel(modelID: "m"))
        #expect(observed.dropFirst().contains { if case .progress = $0 { true } else { false } })

        updates.withLock { $0 = [] }
        _ = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/b.wav"), options: TranscriptionOptions(language: "en")) {
            update in updates.withLock { $0.append(update) }
        }
        #expect(updates.withLock { $0 }.contains { if case .loadingModel = $0 { true } else { false } } == false)
    }

    @Test("cancelled model loading stays cancellation rather than becoming a failed file job")
    func cancelledLoad() async throws {
        let dir = TemporaryDirectory()
        let payload = Data(repeating: 1, count: 1000)
        let model = ModelDescriptor(id: "m", displayName: "m", role: .speech, downloadURL: URL(string: "https://x/m.bin")!,
                                    sizeInBytes: 1000, sha256: SHA256File.hexDigest(of: payload), languagesSummary: "", isDefault: true)
        let downloader = FakeModelDownloader()
        await downloader.serve(payload, at: model.downloadURL)
        let store = ModelStore(directory: dir.url, catalog: [model], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        for try await _ in await store.install(id: "m") {}
        let engine = CancelledLoadEngine()
        let transcriber = LazyModelFileTranscriber(loader: ModelLoader(store: store, engine: engine), store: store,
                                                   engine: engine, decoder: StubDecoder())
        await #expect(throws: CancellationError.self) {
            _ = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/a.wav"), options: TranscriptionOptions()) { _ in }
        }
    }

    private struct CancelledLoadEngine: SpeechEngine {
        func load(modelAt url: URL) async throws { throw CancellationError() }
        func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection { throw CancellationError() }
        func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
    }

    @Test("no installed speech model → noModelInstalled, engine untouched")
    func noModel() async throws {
        let dir = TemporaryDirectory()
        let store = ModelStore(directory: dir.url, catalog: ModelCatalog.all, downloader: FakeModelDownloader(),
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        let engine = FakeSpeechEngine(script: [])
        let loader = ModelLoader(store: store, engine: engine)
        let transcriber = LazyModelFileTranscriber(loader: loader, store: store, engine: engine, decoder: StubDecoder())
        await #expect(throws: FileTranscriptionError.noModelInstalled) {
            _ = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/a.wav"), options: TranscriptionOptions(language: "en")) { _ in }
        }
        #expect(await engine.isLoaded == false)
    }

    @Test("loads the default model once and reuses it")
    func loadsOnce() async throws {
        let dir = TemporaryDirectory()
        let payload = Data(repeating: 1, count: 1000)
        let model = ModelDescriptor(id: "m", displayName: "m", role: .speech, downloadURL: URL(string: "https://x/m.bin")!,
                                    sizeInBytes: 1000, sha256: SHA256File.hexDigest(of: payload), languagesSummary: "", isDefault: true)
        let downloader = FakeModelDownloader()
        await downloader.serve(payload, at: model.downloadURL)
        let store = ModelStore(directory: dir.url, catalog: [model], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        for try await _ in await store.install(id: "m") {}
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "hi")!)])
        let loader = ModelLoader(store: store, engine: engine)
        let transcriber = LazyModelFileTranscriber(loader: loader, store: store, engine: engine, decoder: StubDecoder())
        let url = URL(fileURLWithPath: "/tmp/a.wav")
        let first = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        let second = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        #expect(first.modelID == "m" && second.modelID == "m")
        #expect(await engine.loadedModelURL?.lastPathComponent == "m.bin")
        #expect(await engine.transcribeCalls == 2)
    }
}
