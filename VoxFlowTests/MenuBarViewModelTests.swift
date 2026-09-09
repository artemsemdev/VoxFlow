import CryptoKit
import Foundation
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

@Suite("MenuBarViewModel")
@MainActor
struct MenuBarViewModelTests {
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

    /// Bounded, non-sleeping wait for the coordinator's (asynchronously applied) state to catch up.
    func wait(_ c: DictationCoordinator, until predicate: @escaping (FlowBarState) -> Bool) async {
        for _ in 0..<2000 where !predicate(c.state) { await Task.yield() }
    }

    /// A real `StatsService` over a seeded temp database — mirrors `StatsServiceTests`' harness so
    /// `wordsTodayText`/`minutesSavedText` reflect real aggregate numbers, not a stub.
    func makeStats(dir: TemporaryDirectory, words: Int, minutes: TimeInterval, at date: Date = Date()) async throws -> StatsService {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        settings.encryptHistory = false
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

    func makeViewModel(dir: TemporaryDirectory, coordinator: DictationCoordinator, settings: DictationSettings? = nil,
                       stats injectedStats: StatsService? = nil, modelsOnDisk: @escaping @Sendable () async -> Int = { 0 },
                       navigation: Navigation? = nil, now: @escaping () -> Date = Date.init) async throws -> MenuBarViewModel {
        let settings = settings ?? DictationSettings(store: InMemoryKeyValueStore())
        let stats: StatsService
        if let injectedStats { stats = injectedStats } else { stats = try await makeStats(dir: dir, words: 0, minutes: 0) }
        return MenuBarViewModel(dictation: coordinator, settings: settings, stats: stats, models: ModelsViewModel(store: makeEmptyModelStore()),
                                modelsOnDisk: modelsOnDisk, navigation: navigation ?? Navigation(), now: now)
    }

    func makeEmptyModelStore() -> ModelStore {
        ModelStore(directory: TemporaryDirectory().url, downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 100_000_000_000),
                  settings: InMemoryKeyValueStore())
    }

    @Test("statusText/statusColor follow the coordinator's state — idle, listening, processing")
    func statusFollowsState() async throws {
        let clock = FakeClock()
        let coordinator = makeCoordinator(clock: clock)
        let dir = TemporaryDirectory()
        let vm = try await makeViewModel(dir: dir, coordinator: coordinator)
        #expect(vm.statusText == "Ready · on-device" && vm.statusColor == Palette.onDevice)

        // `.armed` (the instant fn goes down) still reads "Ready · on-device" per `MenuBarStatus`
        // (only `.listening`/`.processing`/`.paused` change it) — advance past the hold threshold so
        // the machine actually reaches `.listening`.
        coordinator.fn(.down)
        // N1: `.armed(_)` (explicit wildcard payload), not `.armed` — the bare-case form mis-evaluates
        // as an if-expression inside an `@escaping` closure under this toolchain (see
        // `DictationCoordinatorTests`).
        await wait(coordinator) { if case .armed(_) = $0 { true } else { false } }
        await clock.waitForSleepers(1)
        await clock.advance(by: FlowBarConfig().holdThreshold + 0.1)
        await wait(coordinator) { if case .listening(_) = $0 { true } else { false } }
        #expect(vm.statusText == "Listening…")
    }

    @Test("pauseOneHour() pauses for MenuBarViewModel.pauseDuration; resume() clears it")
    func pauseAndResume() async throws {
        let clock = FakeClock()
        let coordinator = makeCoordinator(clock: clock)
        let dir = TemporaryDirectory()
        let vm = try await makeViewModel(dir: dir, coordinator: coordinator)
        #expect(!vm.isPaused)

        vm.pauseOneHour()
        await wait(coordinator) { if case .paused = $0 { true } else { false } }
        #expect(vm.isPaused)
        #expect(vm.isCondensed)
        #expect(coordinator.pausedUntil == MenuBarViewModel.pauseDuration)

        vm.resume()
        await wait(coordinator) { $0 == .idle }
        #expect(!vm.isPaused)
    }

    @Test("pausedUntilText / statusText format the wall-clock 'until' time as 'h:mm', no AM/PM")
    func pausedUntilFormatting() async throws {
        let clock = FakeClock()
        let coordinator = makeCoordinator(clock: clock)
        let dir = TemporaryDirectory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let wallNow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 9, minute: 41))!
        let vm = try await makeViewModel(dir: dir, coordinator: coordinator, now: { wallNow })

        vm.pauseOneHour()   // 3600 s — 9:41 + 1 h = 10:41 (design MB-02's exact example)
        await wait(coordinator) { if case .paused = $0 { true } else { false } }

        #expect(vm.pausedUntilText == "10:41")
        #expect(vm.statusText == "Paused until 10:41")
        #expect(vm.statusColor == Palette.amber)
    }

    @Test("handsFree reads/writes DictationSettings.hotkeyMode")
    func handsFreeBinding() async throws {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let clock = FakeClock()
        let dir = TemporaryDirectory()
        let vm = try await makeViewModel(dir: dir, coordinator: makeCoordinator(clock: clock), settings: settings)
        #expect(!vm.handsFree)
        vm.handsFree = true
        #expect(settings.hotkeyMode == .handsFree)
        vm.handsFree = false
        #expect(settings.hotkeyMode == .pushToTalk)
    }

    @Test("wordsTodayText / minutesSavedText read StatsService.today, comma-formatted")
    func statsLine() async throws {
        let dir = TemporaryDirectory()
        // words: 1240, duration: 13 min → minutesSaved = floor(1240/40 - 13) = 18 (design MB-01's
        // exact "1,240 words today · 18 min saved").
        let stats = try await makeStats(dir: dir, words: 1240, minutes: 13)
        let vm = try await makeViewModel(dir: dir, coordinator: makeCoordinator(clock: FakeClock()), stats: stats)
        #expect(vm.wordsTodayText == "1,240 words today")
        #expect(vm.minutesSavedText == "18 min saved")
    }

    @Test("footer: 'No network connections · N models on disk · {mode}', modelsOnDisk from refresh()")
    func footerText() async throws {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let dir = TemporaryDirectory()
        let vm = try await makeViewModel(dir: dir, coordinator: makeCoordinator(clock: FakeClock()), settings: settings, modelsOnDisk: { 3 })
        #expect(vm.footer == "No network connections · 0 models on disk · Push-to-talk")
        await vm.refresh()
        #expect(vm.footer == "No network connections · 3 models on disk · Push-to-talk")

        settings.hotkeyMode = .handsFree
        #expect(vm.footer == "No network connections · 3 models on disk · Hands-free")
    }

    @Test("languageName / setLanguage bind DictationSettings.language through the same 7-language list as General")
    func language() async throws {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let dir = TemporaryDirectory()
        let vm = try await makeViewModel(dir: dir, coordinator: makeCoordinator(clock: FakeClock()), settings: settings)
        #expect(vm.languageName == "Auto-detect")
        vm.setLanguage("es")
        #expect(settings.language == "es" && vm.languageName == "Español")
        vm.setLanguage(nil)
        #expect(settings.language == nil && vm.languageName == "Auto-detect")
    }

    @Test("openMain/openHistory/openSettings drive Navigation")
    func navigationActions() async throws {
        let navigation = Navigation()
        let dir = TemporaryDirectory()
        let vm = try await makeViewModel(dir: dir, coordinator: makeCoordinator(clock: FakeClock()), navigation: navigation)

        vm.openMain()
        #expect(navigation.requestMainWindow)
        navigation.requestMainWindow = false

        vm.openHistory()
        #expect(navigation.page == .history && navigation.requestMainWindow)
        navigation.requestMainWindow = false

        vm.openSettings()
        #expect(navigation.page == .settings && navigation.requestMainWindow)
    }

    @Test("downloading(in:) finds the first actively-downloading row, speech before style, with a rounded percent")
    func downloadingRow() {
        let speechModel = ModelCatalog.all.first { $0.role == .speech }!
        let styleModel = ModelCatalog.all.first { $0.role == .style }!
        let idle = ModelsViewModel.Row(model: speechModel, state: .installed, isDefault: true)
        #expect(MenuBarViewModel.downloadingRow(in: [idle]) == nil)

        let downloadingStyle = ModelsViewModel.Row(model: styleModel, state: .downloading(bytesWritten: 620_000_000, total: 1_000_000_000), isDefault: false)
        let result = MenuBarViewModel.downloadingRow(in: [idle, downloadingStyle])
        #expect(result?.name == styleModel.displayName && result?.percent == 62)

        // Speech rows are checked first when both are downloading (array order — `downloading` in
        // `MenuBarViewModel` passes `speechRows + styleRows`).
        let downloadingSpeech = ModelsViewModel.Row(model: speechModel, state: .downloading(bytesWritten: 1, total: 4), isDefault: true)
        #expect(MenuBarViewModel.downloadingRow(in: [downloadingSpeech, downloadingStyle])?.name == speechModel.displayName)
    }

    @Test("isCondensed is true while a model is actively downloading, even when not paused (ruling 6)")
    func isCondensedWhileDownloading() async throws {
        let payload = Data(count: 40_000)
        let model = ModelDescriptor(id: "m", displayName: "M", role: .speech, downloadURL: URL(string: "https://example.com/m.bin")!,
                                    sizeInBytes: Int64(payload.count), sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                                    languagesSummary: "test", isDefault: true)
        let downloader = FakeModelDownloader()
        await downloader.serve(payload, at: model.downloadURL)
        await downloader.setBlockAfterBytes(20_000)
        let store = ModelStore(directory: TemporaryDirectory().url, catalog: [model], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 100_000_000_000), settings: InMemoryKeyValueStore())
        let models = ModelsViewModel(store: store, catalog: [model])
        await models.refresh()
        let dir = TemporaryDirectory()
        let downloadingVM = MenuBarViewModel(dictation: makeCoordinator(clock: FakeClock()), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                             stats: try await makeStats(dir: dir, words: 0, minutes: 0), models: models, modelsOnDisk: { 0 },
                                             navigation: Navigation())
        #expect(!downloadingVM.isCondensed)   // nothing downloading yet

        let task = Task { await models.download(model) }
        await downloader.waitUntilBlocked()
        var midState = models.speechRows.first?.state
        for _ in 0..<1_000 where !Self.isDownloadingState(midState) {
            await Task.yield()
            midState = models.speechRows.first?.state
        }
        #expect(downloadingVM.isCondensed && !downloadingVM.isPaused)

        await downloader.release()
        _ = await task.value
    }

    private static func isDownloadingState(_ state: ModelState?) -> Bool {
        if case .downloading = state { true } else { false }
    }
}
