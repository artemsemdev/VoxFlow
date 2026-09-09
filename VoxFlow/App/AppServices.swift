import AppKit
import Foundation
import Synchronization
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowModels
import VoxFlowSpeech
import VoxFlowStorage
import VoxFlowStyling

/// Sendable pipe (same reasoning as `DictationLevelSink`, below) from `UserNotificationsPoster`'s
/// delegate callback — which can arrive off the main actor — into the main-actor
/// `NotificationCoordinator.handleRoute(_:)`. Held weakly for the same reason: the poster's
/// `onRoute` closure captures this sink, and `notifications` (built after `posting`, below) is
/// attached to it once constructed, so a strong reference back to `notifications` here would close
/// a retain cycle.
private final class NotificationRouteSink: Sendable {
    private struct WeakBox { weak var coordinator: NotificationCoordinator? }
    private let box = Mutex(WeakBox(coordinator: nil))
    func attach(_ coordinator: NotificationCoordinator) { box.withLock { $0.coordinator = coordinator } }
    func route(_ route: NotificationRoute) {
        Task { @MainActor in self.box.withLock { $0.coordinator }?.handleRoute(route) }
    }
}

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

/// Sendable pipe from `HistoryWriter.save`'s `onSaved` (called off the main actor, inside a
/// detached insert task) into `HistoryService.notifyChanged()` — same `Mutex`-boxed weak-attach
/// pattern as `DictationLevelSink`/`NotificationRouteSink` above, needed because `HistoryWriter`
/// itself is `Sendable` and can't capture the main-actor `HistoryService` directly in its
/// `@Sendable` `onSaved` closure (C1). `notify()` is `async` (unlike the fire-and-forget siblings
/// above) and awaits the hop, so `HistoryWriter.save` only returns once `notifyChanged()` has
/// actually run — what makes "a save through the writer bumps `StatsService.today.words`"
/// deterministically testable.
private final class HistorySavedSink: Sendable {
    private struct WeakBox { weak var service: HistoryService? }
    private let box = Mutex(WeakBox(service: nil))
    func attach(_ service: HistoryService) { box.withLock { $0.service = service } }
    func notify() async {
        await Task { @MainActor in self.box.withLock { $0.service }?.notifyChanged() }.value
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
    /// Home's numbers (design MW-01, ruling 1) — built once here (not per-view `@State`, same
    /// reasoning as `historyViewModel`) so `StatsService.onChange`'s subscription and this run's
    /// numbers survive navigating away from and back to Home.
    let statsService: StatsService
    /// Drives the Home page (design MW-01, MW-01e) — built once here so its Setup-row state
    /// survives navigating away and back, same reasoning as `historyViewModel`.
    let homeViewModel: HomeViewModel
    /// The default style plus fillers/auto-punctuate/snippet-prefix/learn-from-contacts toggles
    /// (design MW-05 Styles page) — read by `StyledTranscriber` via `stylingSettings.box`.
    let stylingSettings: StylingSettings
    /// Dictionary/Snippets/Styles page content (design MW-03/04/05), built on `historyService`'s
    /// shared database — `StyledTranscriber` reads its snapshot boxes to expand snippets and feed
    /// the dictionary into `TranscriptionOptions.vocabulary`.
    let contentService: ContentService
    /// Drives the Dictionary page (design MW-03) — built once here so navigating away and back
    /// keeps its sheet/contacts state, same reasoning as `historyViewModel`.
    let dictionaryViewModel: DictionaryViewModel
    /// Drives the Snippets page (design MW-04) — built once here so navigating away and back keeps
    /// its sheet state, same reasoning as `dictionaryViewModel`.
    let snippetsViewModel: SnippetsViewModel
    /// Drives the Styles page (design MW-05) — same reasoning as `snippetsViewModel`.
    let stylesViewModel: StylesViewModel
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

    // MARK: Settings › General and MCP Server (design ST-01, ST-06) — folded in from `SettingsServices`
    // so `generalViewModel`'s appearance/Flow Bar adapters apply the moment `AppServices.shared` is
    // first built (i.e. at real launch), not only once someone opens the Settings page.
    let generalSettings: GeneralSettings
    let mcpSettings: MCPSettings
    let generalViewModel: GeneralViewModel
    let mcpViewModel: MCPViewModel
    /// ST-01 "Play sounds…" — bound to `dictation` below (`live()`), same as `flowBar`.
    let soundCoordinator: SoundCoordinator

    /// Drives the menu bar dropdown (design MB-00…02) — folded in from `MenuBarServices` so it's
    /// the same instance whether the dropdown is opened before or after Settings.
    let menuBarViewModel: MenuBarViewModel

    /// MB-03/MB-04 completion notifications (ruling 8) — started by `AppDelegate` at a real launch,
    /// not here, same reasoning as `dictation.start()`/`fnMonitor.start()`.
    let notifications: NotificationCoordinator

    private init(modelStore: ModelStore, engine: WhisperCppEngine, queue: FileQueue, filesSettings: FilesSettings,
                 durations: AudioDurationReader, exports: ExportCoordinator, navigation: Navigation,
                 filesViewModel: FilesViewModel, modelsViewModel: ModelsViewModel, audioViewModel: AudioViewModel,
                 privacyViewModel: PrivacyViewModel, dictationSettings: DictationSettings,
                 modelLoader: ModelLoader, historyService: HistoryService, historyViewModel: HistoryViewModel,
                 statsService: StatsService, homeViewModel: HomeViewModel,
                 stylingSettings: StylingSettings, contentService: ContentService, dictionaryViewModel: DictionaryViewModel,
                 snippetsViewModel: SnippetsViewModel, stylesViewModel: StylesViewModel,
                 inserter: AccessibilityTextInserter, ephemeralScope: EphemeralScope, dictationController: DictationController,
                 dictation: DictationCoordinator, flowBar: FlowBarPresenter, fnMonitor: FnKeyMonitor,
                 onboardingState: OnboardingState, onboardingViewModel: OnboardingViewModel,
                 generalSettings: GeneralSettings, mcpSettings: MCPSettings, generalViewModel: GeneralViewModel,
                 mcpViewModel: MCPViewModel, soundCoordinator: SoundCoordinator, menuBarViewModel: MenuBarViewModel,
                 notifications: NotificationCoordinator) {
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
        self.statsService = statsService
        self.homeViewModel = homeViewModel
        self.stylingSettings = stylingSettings
        self.contentService = contentService
        self.dictionaryViewModel = dictionaryViewModel
        self.snippetsViewModel = snippetsViewModel
        self.stylesViewModel = stylesViewModel
        self.inserter = inserter
        self.ephemeralScope = ephemeralScope
        self.dictationController = dictationController
        self.dictation = dictation
        self.flowBar = flowBar
        self.fnMonitor = fnMonitor
        self.onboardingState = onboardingState
        self.onboardingViewModel = onboardingViewModel
        self.generalSettings = generalSettings
        self.mcpSettings = mcpSettings
        self.generalViewModel = generalViewModel
        self.mcpViewModel = mcpViewModel
        self.soundCoordinator = soundCoordinator
        self.menuBarViewModel = menuBarViewModel
        self.notifications = notifications
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

        // C1: `historySavedSink` bridges a successful `HistoryWriter.save` (running off the main
        // actor) back into `historyService.notifyChanged()`, so `StatsService` (the one subscriber
        // to `onChange`) refreshes after every dictation, not just after a History
        // delete/deleteAll/reinsert.
        let historySavedSink = HistorySavedSink()
        historySavedSink.attach(historyService)
        let historyWriter = HistoryWriter(storeBox: historyService.storeBox, settings: dictationSettings.box, now: Date.init,
                                          ready: { await historyService.ready() }, onSaved: { await historySavedSink.notify() })

        // Styles/Dictionary/Snippets content (design MW-03/04/05) — `ContentService` builds its three
        // stores from `historyService`'s shared database once that opens; `StyledTranscriber` reads
        // its snapshot boxes below.
        let stylingSettings = StylingSettings(store: settingsStore)
        let contentService = ContentService(history: historyService)
        // `PreflightBuilder` fills this on the clean path (fn-down) below; `StyledTranscriber` reads
        // it once the window loop returns, instead of re-querying `NSWorkspace` itself.
        let frontmostBox = FrontmostBox()
        // Weak-attach pipe (same pattern as `levelSink` below) from `StyledTranscriber`, running off
        // the main actor, into `ContentService.noteUses`.
        let usesSink = contentService.makeUsesSink()
        let contentSnapshots = ContentSnapshots(vocabularyBox: contentService.vocabularyBox, snippetsBox: contentService.snippetsBox,
                                                overridesBox: contentService.overridesBox,
                                                noteUses: { text, snippets in usesSink.note(text: text, snippets: snippets) })
        let styledTranscriber = StyledTranscriber(base: WindowedTranscriber(engine: engine), styler: RuleStyler(),
                                                  settings: stylingSettings.box, content: contentSnapshots, frontmost: frontmostBox,
                                                  clipboard: { NSPasteboard.general.string(forType: .string) }, now: Date.init)

        // Built fresh on every fn-down (not once, up front) so a Settings edit to the excluded-apps
        // list or hotkey mode applies to the very next capture rather than only after a relaunch.
        let preflight: @Sendable () async -> Preflight = {
            let builder = PreflightBuilder(frontmost: frontmost, permissions: permissions,
                                           readiness: { await modelLoader.readiness() },
                                           settings: dictationSettings.box.current,
                                           captureFocus: { app in await inserter.captureFocus(app: app) },
                                           onFrontmostCaptured: { app in frontmostBox.set(app) })
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
        // One instance, shared with `dictation` below (review fix, Task 4): `SystemMonotonicClock`
        // captures its own `origin` at `init` — two separate instances disagree about "now" by
        // however long apart they were created, which would throw off `DictationCoordinator`'s
        // wall-clock projection of `pausedUntil` (`MenuBarViewModel.pausedUntilText`, MB-02
        // "Paused until 10:41").
        let clock = SystemMonotonicClock()
        let dictationController = DictationController(
            config: dictationSettings.flowBarConfig,
            microphone: MeteredMicrophone(base: MicrophoneSource()) { rms in levelSink.report(rms) },
            transcriber: styledTranscriber,
            inserter: inserter,
            clock: clock,
            preflight: preflight,
            loadModel: { _ = try await modelLoader.ensureLoaded() },
            options: {
                var options = dictationSettings.box.current.options
                options.vocabulary = contentService.vocabularyBox.current
                return options
            },
            onSave: { result, appName in await historyWriter.save(result, appName: appName) },
            copyToClipboard: { SystemPasteboard().setString($0) },
            ephemeral: { ephemeralScope.isActive }
        )
        let dictation = DictationCoordinator(controller: dictationController, settings: dictationSettings,
                                             permissions: permissions, navigation: navigation, clock: clock)
        levelSink.attach(dictation)

        // History's "Try it in a scratchpad" (design 2d) enters/leaves `ephemeralScope` from its own
        // sheet view (`HistoryPage.ScratchpadSheet`) — this view model doesn't need to know about it.
        let historyViewModel = HistoryViewModel(service: historyService, settings: dictationSettings, navigation: navigation,
                                                clock: SystemMonotonicClock(), pasteboard: SystemPasteboard())

        // Home's numbers (design MW-01, ruling 1) — subscribes itself to `historyService.onChange`
        // (see its own doc comment), so a dictation/delete/undo anywhere keeps these live.
        let statsService = StatsService(history: historyService)
        // `ModelLoader.readiness()` alone doesn't carry the model's display name (ruling 9); paired
        // here with `modelStore.defaultModel(role:)` for the Setup card's "Speech model" row.
        let homeViewModel = HomeViewModel(
            stats: statsService, settings: dictationSettings, permissions: permissions,
            modelStatus: { HomeModelStatus(readiness: await modelLoader.readiness(),
                                           displayName: await modelStore.defaultModel(role: .speech)?.displayName) },
            navigation: navigation, ephemeralScope: ephemeralScope)

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
        // Shared across Privacy/Snippets/Styles — one `/Applications` scan behind the three app
        // pickers ("Never record in", "Only in {app}", "Add app override").
        let installedApps = WorkspaceInstalledApps()
        let privacyViewModel = PrivacyViewModel(settings: dictationSettings, history: historyService, apps: installedApps)

        // Dictionary/Snippets/Styles pages (design MW-03/04/05) — built on the same
        // `contentService`/`stylingSettings` `StyledTranscriber` reads above; `SystemContacts` is the
        // real `CNContactStore` seam.
        let dictionaryViewModel = DictionaryViewModel(content: contentService, contactsImporter: SystemContacts(), stylingSettings: stylingSettings)
        let snippetsViewModel = SnippetsViewModel(content: contentService, stylingSettings: stylingSettings, installedApps: installedApps)
        let stylesViewModel = StylesViewModel(content: contentService, stylingSettings: stylingSettings, installedApps: installedApps)

        // Settings › General and MCP Server (design ST-01, ST-06) — folded in from `SettingsServices`
        // (Task 3, controller ruling 4/6): built here, eagerly, so `GeneralViewModel`'s init (which
        // applies the persisted appearance and Flow Bar position immediately) runs the moment
        // `AppServices.shared` is first built — i.e. at real launch — instead of only once someone
        // opens the Settings page, which is when `SettingsServices`' own `lazy var` used to build it.
        let generalSettings = GeneralSettings(store: settingsStore)
        let mcpSettings = MCPSettings(store: settingsStore, token: KeychainTokenStore())
        let generalViewModel = GeneralViewModel(settings: generalSettings, dictationSettings: dictationSettings,
                                                loginItem: SMLoginItem(), appearanceApplier: NSAppearanceApplier(),
                                                flowBarPositioning: flowBar)
        let mcpViewModel = MCPViewModel(settings: mcpSettings, pasteboard: SystemPasteboard())
        // ST-01 "Play sounds…" — bound here (Task 3's `SettingsServices` built this but never bound
        // it to a live coordinator; wiring `bind(to:)` into the real launch sequence was left to
        // this task, see its file-scope note).
        let soundCoordinator = SoundCoordinator(settings: generalSettings, player: NSSoundPlayer())
        soundCoordinator.bind(to: dictation)

        // Menu bar dropdown (design MB-00…02) — folded in from `MenuBarServices` (Task 4), same
        // reasoning as `generalViewModel` above (one instance, built at real launch).
        let menuBarViewModel = MenuBarViewModel(dictation: dictation, settings: dictationSettings, stats: statsService,
                                                models: modelsViewModel, modelsOnDisk: Self.countModelsOnDisk,
                                                navigation: navigation, now: Date.init)

        // MB-03/MB-04 completion notifications (ruling 8). `routeSink` bridges
        // `UserNotificationsPoster`'s delegate (which can arrive off the main actor) back into
        // `notifications.handleRoute(_:)` — same weak-attach reasoning as `levelSink` above.
        // "Frontmost" (ruling 8) is `NSApp.isActive` *and* the main window specifically being key —
        // Settings/Onboarding being key while the app is active still counts as "away", since the
        // person isn't looking at Files/Home right now either.
        let routeSink = NotificationRouteSink()
        let notificationsPoster = UserNotificationsPoster(onRoute: { route in routeSink.route(route) })
        let isMainWindowFrontmost: () -> Bool = {
            NSApp.isActive && NSApp.windows.contains { $0.isKeyWindow && $0.identifier?.rawValue == MainWindowID.main }
        }
        // I2: subscribes to `exports.onExported` (the export's own success signal), not
        // `queue.subscribe()` directly — see the type's own doc comment.
        let notifications = NotificationCoordinator(posting: notificationsPoster, isFrontmost: isMainWindowFrontmost,
                                                     navigation: navigation, exports: exports, modelsViewModel: modelsViewModel,
                                                     filesViewModel: filesViewModel)
        routeSink.attach(notifications)

        return AppServices(modelStore: modelStore, engine: engine, queue: queue, filesSettings: filesSettings,
                           durations: durations, exports: exports, navigation: navigation, filesViewModel: filesViewModel,
                           modelsViewModel: modelsViewModel, audioViewModel: audioViewModel, privacyViewModel: privacyViewModel,
                           dictationSettings: dictationSettings, modelLoader: modelLoader,
                           historyService: historyService, historyViewModel: historyViewModel,
                           statsService: statsService, homeViewModel: homeViewModel,
                           stylingSettings: stylingSettings, contentService: contentService, dictionaryViewModel: dictionaryViewModel,
                           snippetsViewModel: snippetsViewModel, stylesViewModel: stylesViewModel,
                           inserter: inserter,
                           ephemeralScope: ephemeralScope, dictationController: dictationController, dictation: dictation,
                           flowBar: flowBar, fnMonitor: fnMonitor,
                           onboardingState: onboardingState, onboardingViewModel: onboardingViewModel,
                           generalSettings: generalSettings, mcpSettings: mcpSettings, generalViewModel: generalViewModel,
                           mcpViewModel: mcpViewModel, soundCoordinator: soundCoordinator, menuBarViewModel: menuBarViewModel,
                           notifications: notifications)
    }

    /// `modelsOnDisk` for `menuBarViewModel` above — a standalone, explicitly-typed `@Sendable`
    /// function (not an inline closure literal in the initializer call) so the type checker resolves
    /// its isolation on its own instead of alongside the whole `MenuBarViewModel(...)` call, which
    /// left it ambiguous (moved here unchanged from `MenuBarServices.countModelsOnDisk`).
    nonisolated private static func countModelsOnDisk() async -> Int {
        let modelStore = await AppServices.shared.modelStore
        let speech = await modelStore.installedModels(role: .speech).count
        let style = await modelStore.installedModels(role: .style).count
        return speech + style
    }

    var exporter: TranscriptExporter { TranscriptExporter(directory: filesSettings.outputFolder) }
}
