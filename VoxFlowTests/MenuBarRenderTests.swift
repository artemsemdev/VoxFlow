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

private struct FakeHistoryKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
}

/// Design-fidelity renders (Task 4 Step 4) — gated behind `VOXFLOW_RENDER` so normal test runs
/// never touch disk. Run with `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/MenuBarRenderTests`
/// (see `OnboardingRenderTests` for why the `TEST_RUNNER_` prefix is needed), then compare the PNGs
/// in `.superpowers/design/renders/` against `canvas.pdf` pages 11 (MB-01), 8 (MB-02), 4 (MB-00).
///
/// Same `ImageRenderer` limitation as `SettingsRenderTests` (confirmed empirically, not a bug):
/// AppKit-backed controls that draw their own interaction chrome — `Toggle` (the "Hands-free mode"
/// row), `Menu` (the "Language: …" row) and `ProgressView(.linear)` (the download bar) — rasterize
/// as a plain yellow "unavailable cursor" glyph here instead of their real appearance. Every other
/// row (labels, buttons, the status dot) is representative; verify the toggle/menu/progress-bar
/// chrome by running the live app instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct MenuBarRenderTests {
    func makeCoordinator(clock: FakeClock) -> DictationCoordinator {
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(),
                                             transcriber: FakeDictationTranscriber(result: .empty), inserter: FakeTextInserter(),
                                             clock: clock, preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        let coordinator = DictationCoordinator(controller: controller, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                               permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
                                               navigation: Navigation(), clock: clock)
        coordinator.start()
        return coordinator
    }

    func wait(_ c: DictationCoordinator, until predicate: @escaping (FlowBarState) -> Bool) async {
        for _ in 0..<2000 where !predicate(c.state) { await Task.yield() }
    }

    func makeStats(words: Int, minutes: TimeInterval, at date: Date) async throws -> StatsService {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        settings.encryptHistory = false
        let dir = TemporaryDirectory()
        let history = HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                                     keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
        await history.ready()
        let store = try #require(history.store)
        let text = Array(repeating: "hi", count: words).joined(separator: " ")
        _ = try store.insert(DictationDraft(text: text, rawText: text, appName: "Mail", style: nil, language: "en",
                                            duration: minutes * 60, createdAt: date))
        let stats = StatsService(history: history, now: { date })
        await stats.refresh()
        return stats
    }

    func makeEmptyModelsViewModel() -> ModelsViewModel {
        let store = ModelStore(directory: TemporaryDirectory().url, catalog: [], downloader: FakeModelDownloader(),
                               freeSpace: FakeFreeSpace(available: 100_000_000_000), settings: InMemoryKeyValueStore())
        return ModelsViewModel(store: store, catalog: [])
    }

    @Test("renders the menu bar dropdown (ready, paused, downloading) and the MB-00 hint for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. Ready (MB-01, canvas.pdf page 11): "1,240 words today · 18 min saved", 3 models on disk.
        let readyStats = try await makeStats(words: 1240, minutes: 13, at: Date())
        let readyViewModel = MenuBarViewModel(dictation: makeCoordinator(clock: FakeClock()), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                              stats: readyStats, models: makeEmptyModelsViewModel(), modelsOnDisk: { 3 }, navigation: Navigation())
        await readyViewModel.refresh()
        try Self.render(MenuBarView(viewModel: readyViewModel), name: "1-ready", to: directory)

        // 2. Paused (MB-02, canvas.pdf page 8): "Paused until 10:41", "Resume dictation".
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let wallNow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 9, minute: 41))!
        let pausedCoordinator = makeCoordinator(clock: FakeClock())
        let pausedStats = try await makeStats(words: 0, minutes: 0, at: Date())
        let pausedViewModel = MenuBarViewModel(dictation: pausedCoordinator, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                               stats: pausedStats, models: makeEmptyModelsViewModel(), modelsOnDisk: { 3 },
                                               navigation: Navigation(), now: { wallNow })
        pausedViewModel.pauseOneHour()
        await wait(pausedCoordinator) { if case .paused = $0 { true } else { false } }
        await pausedViewModel.refresh()
        try Self.render(MenuBarView(viewModel: pausedViewModel), name: "2-paused", to: directory)

        // 3. Downloading (MB-02, canvas.pdf page 8): "Downloading Parakeet TDT 0.6B · 62%".
        let parakeetPayload = Data(count: 620_000_000)
        let parakeet = ModelDescriptor(id: "parakeet-tdt-0.6b", displayName: "Parakeet TDT 0.6B", role: .speech,
                                       downloadURL: URL(string: "https://example.com/parakeet.bin")!,
                                       sizeInBytes: Int64(parakeetPayload.count),
                                       sha256: SHA256.hash(data: parakeetPayload).map { String(format: "%02x", $0) }.joined(),
                                       languagesSummary: "test", isDefault: false)
        let downloader = FakeModelDownloader()
        await downloader.serve(parakeetPayload, at: parakeet.downloadURL)
        await downloader.setBlockAfterBytes(Int64(Double(parakeetPayload.count) * 0.62))
        let modelStore = ModelStore(directory: TemporaryDirectory().url, catalog: [parakeet], downloader: downloader,
                                    freeSpace: FakeFreeSpace(available: 100_000_000_000), settings: InMemoryKeyValueStore())
        let downloadingModels = ModelsViewModel(store: modelStore, catalog: [parakeet])
        await downloadingModels.refresh()
        let downloadTask = Task { await downloadingModels.download(parakeet) }
        await downloader.waitUntilBlocked()
        var midState = downloadingModels.speechRows.first?.state
        for _ in 0..<1_000 where !Self.isDownloading(midState) {
            await Task.yield()
            midState = downloadingModels.speechRows.first?.state
        }
        let downloadingStats = try await makeStats(words: 0, minutes: 0, at: Date())
        let downloadingViewModel = MenuBarViewModel(dictation: makeCoordinator(clock: FakeClock()), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                                    stats: downloadingStats, models: downloadingModels, modelsOnDisk: { 3 }, navigation: Navigation())
        try Self.render(MenuBarView(viewModel: downloadingViewModel), name: "3-downloading", to: directory)
        await downloader.release()
        _ = await downloadTask.value

        // 4. MB-00 hint (canvas.pdf page 4): "VoxFlow lives here" / body / "Got it".
        try Self.render(MenuBarHintView(onGotIt: {}).frame(width: 300, height: 110), name: "4-hint", to: directory)
    }

    private static func isDownloading(_ state: ModelState?) -> Bool {
        if case .downloading = state { true } else { false }
    }

    private static func render(_ view: some View, name: String, to directory: URL) throws {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render \(name)")
            return
        }
        try writePNG(image, to: directory.appendingPathComponent("MenuBar-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
    }
}
