# VoxFlow v2 Phase 2b — Files page and Settings › Models — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The first user-visible product of v2: drop audio/video files on the app, get transcripts in `~/Transcripts` in the chosen format, and manage speech models — the promotion gate of #105. Screens: Files (design 1c Files, 2d empty/drag-over, 2f result, MW-06/MW-06g/MW-06r/MW-06x/MW-06c) and Settings › Models (ST-03, ST-03v, ST-03d, SYS-DISK, ST-03o).

**Architecture:** `AppServices` (MainActor, built once in `VoxFlowApp`) wires the real engine, decoder, model store and `FileQueue`. View models are `@Observable @MainActor` classes that own all state transitions and confirmation states (alerts are data, testable without UI); views are thin. The app target links `VoxFlowCore/Audio/Speech/Models/Files`; the app test target links `VoxFlowTestSupport` through a new package product.

**Tech Stack:** SwiftUI (macOS 15), AppKit bridges (`NSSavePanel`, `NSWorkspace`, `NSApplicationDelegateAdaptor`), Swift Testing, XcodeGen.

**Spec:** design spec §1; canvas sections listed above; issue #109 (UI half). Depends on phase 2a (merged).

**Phase 2a API facts to build on:** `FileQueue.subscribe() -> AsyncStream<FileQueueEvent>` (multi-subscriber; events `.added(item)`, `.changed(item)`, `.removed(id)`, `.finished(item)`, `.idle`; cancelled rows emit `.changed` only; terminal rows emit `.changed` then `.finished`); `FileQueue.waitUntilIdle()`; `SupportedAudio.extensions` in Core is the single drop gate; progress events are coalesced by 0.01 delta, not time — the view model throttles UI updates to 1 Hz (design 3d); the exported URL per row is kept by the view model (`exportedURLs: [UUID: URL]`); the app is not sandboxed in phase 2, so `~/Transcripts` is the real home folder (a security-scoped bookmark becomes necessary only if sandboxing is enabled in phase 7).

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)`.
- Views contain no business rules: every decision (stop confirmation threshold 10 %, > 4 h confirmation, model-required banner, export naming) lives in a view model or Core/Files and has a test.
- Copy and labels follow the design canvas verbatim where quoted (e.g. "Drop audio or video to transcribe", "Release to add N files", "Queue · N files", "Not an audio or video file. Supported: MP3, WAV, M4A, AAC, FLAC, MP4, MOV.").
- Green on-device status stays in the sidebar footer; no network except model download on user action.
- Commits: Conventional Commits, owner-authored, no attribution. Branch `feature/109-v2-files-ui` from `develop` (after 2a merges); PR into `develop`.
- Verify: `cd v2 && xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`; the app launches and a real file can be transcribed on the owner's Mac (manual check recorded in the PR).

---

### Task 1: Package/app wiring, settings store, `AppServices`

**Files:**
- Modify: `v2/VoxFlowKit/Package.swift` — add product `.library(name: "VoxFlowTestSupport", targets: ["VoxFlowTestSupport"])`.
- Modify: `v2/project.yml` — app target dependencies: products `VoxFlowCore`, `VoxFlowAudio`, `VoxFlowSpeech`, `VoxFlowModels`, `VoxFlowFiles`; `VoxFlowTests` dependencies add `package: VoxFlowKit, product: VoxFlowTestSupport` (and the five products); app `info.properties` add `CFBundleDocumentTypes` (viewer for `public.audio`, `public.movie`) and `NSDownloadsFolderUsageDescription`-free (no sandbox in phase 2).
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/UserDefaultsKeyValueStore.swift`
- Create: `v2/VoxFlow/App/AppServices.swift`, `v2/VoxFlow/App/AppDelegate.swift`, `v2/VoxFlow/Files/FilesSettings.swift`, `v2/VoxFlow/Files/LazyModelFileTranscriber.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowCoreTests/UserDefaultsKeyValueStoreTests.swift`, `v2/VoxFlowTests/FilesSettingsTests.swift`, `v2/VoxFlowTests/LazyModelFileTranscriberTests.swift`

**Interfaces:**
- `UserDefaultsKeyValueStore(defaults: UserDefaults = .standard, prefix: String = "voxflow.")`: `KeyValueStore`.
- `FilesSettings` (`@Observable @MainActor`): `outputFormat: OutputFormat` (default `.txt`), `batchMode: Bool` (true), `timestamps: Bool` (true), `language: String?` (nil = auto), `outputFolder: URL` (default `TranscriptExporter.defaultDirectory`); each setter persists through `KeyValueStore`; `init(store:)` reads them back; `transcriptionOptions: TranscriptionOptions` (language only in 2b; vocabulary comes in phase 4).
- `LazyModelFileTranscriber: FileTranscribing` (actor): `init(store: ModelStore, engine: any SpeechEngine, decoder: any AudioDecoding)`; on each call resolves `store.defaultModel(role: .speech)`; throws `FileTranscriptionError.noModelInstalled` if nil; loads the model into the engine if the loaded id differs; delegates to `FileTranscriber`.
- `AppServices` (`@MainActor final class`, `@Observable`): `modelStore`, `engine`, `queue`, `filesSettings`, `exporter`, `durations`; `static func live() -> AppServices`.
- `AppDelegate: NSObject, NSApplicationDelegate`: `application(_:open:)` forwards URLs to `AppServices.shared.queue.add`.

- [ ] Step 1: tests

`Tests/VoxFlowCoreTests/UserDefaultsKeyValueStoreTests.swift`:
```swift
import Foundation
import Testing
@testable import VoxFlowCore

@Suite("UserDefaultsKeyValueStore")
struct UserDefaultsKeyValueStoreTests {
    @Test("round-trips and namespaces keys; nil removes")
    func roundTrip() {
        let suite = "voxflow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsKeyValueStore(defaults: defaults, prefix: "t.")
        #expect(store.string(forKey: "a") == nil)
        store.set("1", forKey: "a")
        #expect(store.string(forKey: "a") == "1")
        #expect(defaults.string(forKey: "t.a") == "1")
        store.set(nil, forKey: "a")
        #expect(store.string(forKey: "a") == nil)
    }
}
```

`VoxFlowTests/FilesSettingsTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("FilesSettings") @MainActor
struct FilesSettingsTests {
    @Test("defaults match the design: TXT, batch on, timestamps on, auto language, ~/Transcripts")
    func defaults() {
        let settings = FilesSettings(store: InMemoryKeyValueStore())
        #expect(settings.outputFormat == .txt)
        #expect(settings.batchMode && settings.timestamps)
        #expect(settings.language == nil)
        #expect(settings.outputFolder.lastPathComponent == "Transcripts")
        #expect(settings.transcriptionOptions == TranscriptionOptions())
    }

    @Test("changes persist and reload")
    func persistence() {
        let store = InMemoryKeyValueStore()
        let settings = FilesSettings(store: store)
        settings.outputFormat = .srt
        settings.timestamps = false
        settings.language = "de"
        settings.outputFolder = URL(fileURLWithPath: "/tmp/out")
        let reloaded = FilesSettings(store: store)
        #expect(reloaded.outputFormat == .srt && reloaded.timestamps == false && reloaded.language == "de")
        #expect(reloaded.outputFolder.path == "/tmp/out")
        #expect(reloaded.transcriptionOptions.language == "de")
    }
}
```

`VoxFlowTests/LazyModelFileTranscriberTests.swift`:
```swift
import Foundation
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
    @Test("no installed speech model → noModelInstalled, engine untouched")
    func noModel() async throws {
        let dir = TemporaryDirectory()
        let store = ModelStore(directory: dir.url, catalog: ModelCatalog.all, downloader: FakeModelDownloader(),
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
        let engine = FakeSpeechEngine(script: [])
        let transcriber = LazyModelFileTranscriber(store: store, engine: engine, decoder: StubDecoder())
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
        let transcriber = LazyModelFileTranscriber(store: store, engine: engine, decoder: StubDecoder())
        let url = URL(fileURLWithPath: "/tmp/a.wav")
        let first = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        let second = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        #expect(first.modelID == "m" && second.modelID == "m")
        #expect(await engine.loadedModelURL?.lastPathComponent == "m.bin")
        #expect(await engine.transcribeCalls == 2)
    }
}
```
(`SHA256File.hexDigest(of: Data)` overload: add `public static func hexDigest(of data: Data) -> String` to `SHA256File` in this task — one line using CryptoKit.)

- [ ] Step 2: RED (xcodegen generate + build-for-testing shows missing types).

- [ ] Step 3: implementation

`Sources/VoxFlowCore/UserDefaultsKeyValueStore.swift`:
```swift
import Foundation

/// `KeyValueStore` over `UserDefaults`, all keys namespaced with `prefix`.
public struct UserDefaultsKeyValueStore: KeyValueStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "voxflow.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: prefix + key) }

    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}
```
(`UserDefaults` is `Sendable` in the macOS 15 SDK; if the compiler disagrees, mark the struct `@unchecked Sendable` with the comment "UserDefaults is thread-safe per Apple docs" — the one exception allowed in this task.)

`VoxFlow/Files/FilesSettings.swift`:
```swift
import Foundation
import VoxFlowCore
import VoxFlowFiles

/// The Files page's persistent choices (design 1c Files › Output format / Batch mode / Timestamps / Language / Save to).
@Observable @MainActor
final class FilesSettings {
    private let store: any KeyValueStore

    var outputFormat: OutputFormat { didSet { store.set(outputFormat.rawValue, forKey: "files.format") } }
    var batchMode: Bool { didSet { store.set(batchMode ? "1" : "0", forKey: "files.batch") } }
    var timestamps: Bool { didSet { store.set(timestamps ? "1" : "0", forKey: "files.timestamps") } }
    /// ISO 639-1 code or nil for auto-detect.
    var language: String? { didSet { store.set(language, forKey: "files.language") } }
    var outputFolder: URL { didSet { store.set(outputFolder.path, forKey: "files.outputFolder") } }

    init(store: any KeyValueStore) {
        self.store = store
        outputFormat = store.string(forKey: "files.format").flatMap(OutputFormat.init(rawValue:)) ?? .default
        batchMode = store.string(forKey: "files.batch") != "0"
        timestamps = store.string(forKey: "files.timestamps") != "0"
        language = store.string(forKey: "files.language")
        outputFolder = store.string(forKey: "files.outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TranscriptExporter.defaultDirectory
    }

    var transcriptionOptions: TranscriptionOptions { TranscriptionOptions(language: language) }
}
```

`VoxFlow/Files/LazyModelFileTranscriber.swift`:
```swift
import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// Resolves the default speech model per job, loads it into the engine when it changed, then transcribes.
actor LazyModelFileTranscriber: FileTranscribing {
    private let store: ModelStore
    private let engine: any SpeechEngine
    private let decoder: any AudioDecoding
    private var loadedModelID: String?

    init(store: ModelStore, engine: any SpeechEngine, decoder: any AudioDecoding) {
        self.store = store
        self.engine = engine
        self.decoder = decoder
    }

    func transcribe(_ url: URL, options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        guard let model = await store.defaultModel(role: .speech) else { throw FileTranscriptionError.noModelInstalled }
        if loadedModelID != model.id {
            do {
                try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName))
            } catch {
                throw FileTranscriptionError.engineFailed("model load failed: \(error)")
            }
            loadedModelID = model.id
        }
        return try await FileTranscriber(decoder: decoder, engine: engine, modelID: model.id)
            .transcribe(url, options: options, progress: progress)
    }
}
```

`VoxFlow/App/AppServices.swift`:
```swift
import Foundation
import VoxFlowAudio
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowSpeech

/// Composition root: the real engine, decoder, model store and queue, built once per app run.
@MainActor
final class AppServices {
    static let shared = AppServices.live()

    let modelStore: ModelStore
    let engine: WhisperCppEngine
    let queue: FileQueue
    let filesSettings: FilesSettings
    let durations: AudioDurationReader

    private init(modelStore: ModelStore, engine: WhisperCppEngine, queue: FileQueue, filesSettings: FilesSettings, durations: AudioDurationReader) {
        self.modelStore = modelStore
        self.engine = engine
        self.queue = queue
        self.filesSettings = filesSettings
        self.durations = durations
    }

    static func live() -> AppServices {
        let settingsStore = UserDefaultsKeyValueStore()
        let modelStore = ModelStore(directory: ModelStore.defaultDirectory, downloader: RangeResumingDownloader(),
                                    freeSpace: VolumeFreeSpace(), settings: settingsStore)
        let engine = WhisperCppEngine()
        let filesSettings = FilesSettings(store: settingsStore)
        let transcriber = LazyModelFileTranscriber(store: modelStore, engine: engine, decoder: AudioDecoder())
        let queue = FileQueue(transcriber: transcriber, durations: AudioDurationReader(),
                              supportedExtensions: SupportedAudio.extensions,
                              options: { MainActor.assumeIsolated { filesSettings.transcriptionOptions } })
        return AppServices(modelStore: modelStore, engine: engine, queue: queue, filesSettings: filesSettings, durations: AudioDurationReader())
    }

    var exporter: TranscriptExporter { TranscriptExporter(directory: filesSettings.outputFolder) }
}
```
Note: the `options` closure runs on the queue actor; `MainActor.assumeIsolated` is wrong there. Replace with a Sendable snapshot: make `FilesSettings` publish its options into a `Mutex<TranscriptionOptions>`-backed `OptionsSnapshot` (final class, Sendable) updated in each `didSet`; the closure reads the snapshot. Implement `OptionsSnapshot` in `FilesSettings.swift` (`import Synchronization`).

`VoxFlow/App/AppDelegate.swift`:
```swift
import AppKit
import SwiftUI

/// Dock-icon drops and Finder "Open With" (design MW-06: "drop on Dock icon").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            await AppServices.shared.queue.add(urls)
            await AppServices.shared.queue.start()
        }
    }
}
```
Wire in `VoxFlowApp`: `@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate` and `.environment(AppServices.shared)` is not needed (singleton); view models receive services explicitly.

- [ ] Step 4: GREEN (scheme build test), Step 5: commit `feat(v2): wire app services, files settings and the lazy model transcriber`.

---

### Task 2: `FilesViewModel` and `ResultViewModel` (logic only, tested)

**Files:**
- Create: `v2/VoxFlow/Files/FilesViewModel.swift`, `v2/VoxFlow/Files/ResultViewModel.swift`
- Test: `v2/VoxFlowTests/FilesViewModelTests.swift`, `v2/VoxFlowTests/ResultViewModelTests.swift`

**Interfaces:**
```swift
@Observable @MainActor final class FilesViewModel {
    enum Confirmation: Equatable { case stop(QueueItem, progress: Double), longAudio(urls: [URL], hours: Double) }
    struct ExportedResult: Equatable { let item: QueueItem; let document: TranscriptDocument; let url: URL? }

    var items: [QueueItem]                  // maintained from subscribe() events (.added/.changed/.removed), initialised from queue.items
    var confirmation: Confirmation?
    var selected: ExportedResult?           // opens the result view (MW-06r)
    var needsModel: Bool                    // banner: "Speech model not installed"
    var isDragOver: Bool
    var headerTitle: String                 // "Queue · 3 files"
    var headerSubtitle: String              // "2 h 32 min of audio · 1 done · 1 running · 1 needs attention"
    var transcribeButtonTitle: String       // "Transcribe 2 files as SRT"
    var canTranscribe: Bool

    init(queue: FileQueue, settings: FilesSettings, modelStore: ModelStore, exporter: @escaping () -> TranscriptExporter)
    func addFiles(_ urls: [URL]) async          // > 4 h total → confirmation .longAudio (3e), else add
    func confirmLongAudio() async; func cancelConfirmation()
    func transcribeAll() async                  // refreshes needsModel, starts the queue
    func requestStop(_ item: QueueItem) async   // running & progress > 0.1 → .stop confirmation (MW-06c); else cancel silently
    func confirmStop() async
    func remove(_ item: QueueItem) async; func retry(_ item: QueueItem) async
    func open(_ item: QueueItem)                // done → selected
    func closeResult()
    func exported(for item: QueueItem) -> URL?  // auto-export result (set on .finished)
}
```
Event loop: a single `Task` started in `init` iterates `queue.subscribe()`; `.changed` for a running row updates `progress`/ETA but re-renders at most once per second per row (keep `lastRender[id]`). Auto-export: on `.finished(item)` with `.done(document)` the view model exports in `settings.outputFormat` with `settings.timestamps` and stores the URL. Failures to export are stored as `exportErrors[item.id]` and shown in the row.
`needsModel` = `modelStore.installedModels(role: .speech).isEmpty` (refreshed on `transcribeAll`, on appear, and after Models changes via a `refreshModelState()` call).

```swift
@Observable @MainActor final class ResultViewModel {
    let document: TranscriptDocument
    var format: OutputFormat
    var timestamps: Bool
    var searchText: String
    var rendered: String                     // TranscriptRenderer output for the current format
    var visibleSegments: [TranscriptSegment] // filtered by searchText (case-insensitive contains)
    var metaLine: String                     // "1:32:10 · 13,842 words · EN (auto) · whisper-large-v3-turbo · took 4 min 12 s on this Mac"
    var savedURL: URL?
    var exportMessage: String?               // "Saved to ~/Transcripts/lecture-04.srt"
    init(document:, format:, timestamps:, savedURL:, exporter: @escaping () -> TranscriptExporter, pasteboard: any Pasteboard, revealer: any FileRevealing)
    func copy()                              // rendered → pasteboard
    func exportAlso(_ format: OutputFormat) throws -> URL
    func reveal()
}
protocol Pasteboard { func setString(_ s: String) }          // NSPasteboard in the app, fake in tests
protocol FileRevealing { func reveal(_ url: URL) }           // NSWorkspace.activateFileViewerSelecting
```
`metaLine` rules: duration via `TimeCode.short`, words with thousands separators, language upper-cased + " (auto)" when the settings language was nil (pass `autoDetected: Bool` in init), `processingTime` as "took 4 min 12 s" / "took 12 s".

- [ ] Tests (excerpt — write the full files following these cases):
  - `FilesViewModelTests`: uses `FakeFileTranscriber`-backed `FileQueue`, `FakeAudioDuration`, an in-memory `FilesSettings`, a `ModelStore` with an installed fake model (helper from Task 1 tests) and `TranscriptExporter(directory: TemporaryDirectory)`.
    1. `addFiles` under 4 h adds directly; ≥ 4 h total sets `.longAudio(hours:)` and adds nothing until `confirmLongAudio()`.
    2. `headerTitle/headerSubtitle` for the design's example: 4 files, 1 done, 1 running, 2 failed → "Queue · 4 files", "1 done · 1 running · 2 need attention".
    3. `transcribeButtonTitle` = "Transcribe 2 files as SRT" counts queued items only; `canTranscribe` false when no queued items or `needsModel`.
    4. `requestStop` on running item at progress 0.72 → `.stop` confirmation; at 0.05 → cancelled immediately (queue item `.cancelled`).
    5. On `.finished(done)` an export file appears in the temp folder with the settings' format and `exported(for:)` returns it; `open` sets `selected` with the URL.
    6. `needsModel` true with an empty store; `transcribeAll` does not start the queue then.
  - `ResultViewModelTests`: rendered text changes with `format`; `copy` writes the rendered text to the fake pasteboard; `searchText` filters segments; `metaLine` formatting for the design example (5530 s, 13_842 words, "en", auto, 252 s) == "1:32:10 · 13,842 words · EN (auto) · whisper-large-v3-turbo · took 4 min 12 s on this Mac"; `exportAlso(.vtt)` writes a file and sets `exportMessage`.

- [ ] Implement, GREEN, commit `feat(v2): add Files and Result view models`.

---

### Task 3: Files page views

**Files:** `v2/VoxFlow/Files/FilesPage.swift`, `DropZoneView.swift`, `QueueListView.swift`, `QueueRowView.swift`, `FilesToolbar.swift`, `ModelRequiredBanner.swift`, `TranscriptResultView.swift`; modify `MainWindow.swift` (route `.files` to `FilesPage`), `PlaceholderPageView` stays for the others.

Design mapping (from the canvas):
- Empty state (2d): big arrow icon, "Drop audio or video to transcribe", "MP3, WAV, M4A, MP4, MOV · any length · processed on this Mac, never uploaded", button "Choose Files…" (`fileImporter`, `allowedContentTypes: [.audio, .movie]`, multiple).
- Drag-over (MW-06g): overlay "Release to add N files" + "X h Y min of audio · processed on this Mac" (durations read on drop enter are not available; show the count only, add the duration line after drop) — use `.dropDestination(for: URL.self)` with `isTargeted` binding.
- Queue list: header "Queue · 3 files" + subtitle; rows: name, "48:12 · 72% · about 3 min left" (ETA from `ETAEstimator` fed by `.changed` events with `Date()` timestamps inside the view model — add `eta(for:)`), "12:04 · queued", "1:32:10 · done" + "Reveal in Finder"; failed rows with "!" and the MW-06x copy: decode failure "Couldn't decode this file — it may be incomplete or corrupt." with Retry/Remove; unsupported "Not an audio or video file. Supported: MP3, WAV, M4A, AAC, FLAC, MP4, MOV." with Remove; `2×` badge when `duplicates > 1`; Stop button on the running row → `requestStop`.
- Toolbar (bottom, design 1c): "Output format" segmented (TXT SRT VTT JSON MD), "Batch mode · One output folder, shared settings" toggle, "Timestamps" toggle (disabled when the format ignores it), "Language" picker (Auto-detect + the design's 6 languages), "Save to ~/Transcripts" (folder chooser), primary button `transcribeButtonTitle`.
- Alerts: `.stop` → "Stop transcribing “name”?" / "It’s 72% done. The partial transcript will be discarded and the file stays in the queue." buttons "Keep going" (cancel) / "Stop" (destructive, not default). `.longAudio` → "Transcribe N h of audio?" with ETA estimate "about X min on this Mac" using RTF 0.063 (constant `FilesViewModel.estimatedRealTimeFactor`), buttons Cancel / Transcribe.
- Result view (2f): "‹ Queue" back button, title = file name, `metaLine`, segmented formats, Copy, Save as… (`NSSavePanel` via a `Saving` protocol; default name `<base>.<ext>`), "Find in transcript" search field, segment list `1  00:00:00,000 → 00:00:04,120  text` (index, `TimeCode.srt` start → end), footer "Saved to ~/Transcripts/lecture-04.srt · Reveal in Finder" + "Also export: TXT · VTT · JSON · MD — instant, no re-processing" (buttons per format not equal to the current one). "Segment length" and "Apply Casual cleanup" controls are **not** built (phase 4/5); leave a comment.
- Model banner: "Speech model not installed" + "Download" → navigates to Settings › Models (`navigation.page = .settings`, `settingsTab = .models`).

- [ ] Build with `xcodebuild`; manual check on the owner's Mac: drop `attention-10s.wav`, see the row progress and the result view, file appears in `~/Transcripts`. Commit `feat(v2): add the Files page (drop zone, queue, result view)`.

---

### Task 4: `ModelsViewModel` and Settings › Models

**Files:** `v2/VoxFlow/Settings/SettingsPage.swift` (segmented tabs General/Hotkeys/Models/Audio/Privacy/MCP Server; only Models real), `v2/VoxFlow/Settings/ModelsViewModel.swift`, `ModelsSettingsView.swift`; `MainWindow.swift` routes `.settings`; `Navigation` gains `settingsTab: SettingsTab`.
- Test: `v2/VoxFlowTests/ModelsViewModelTests.swift`.

```swift
@Observable @MainActor final class ModelsViewModel {
    struct Row: Identifiable, Equatable { let model: ModelDescriptor; var state: ModelState; var isDefault: Bool
        var sizeText: String /* "1.6 GB" */; var subtitle: String /* "1.6 GB · 99 languages · best accuracy on M-series" */ }
    enum Alert: Equatable { case insufficientSpace(model: ModelDescriptor, required: Int64, available: Int64)   // SYS-DISK
                            case removeModel(ModelDescriptor)                                                      // ST-03d
                            case downloadFailed(ModelDescriptor, reason: String)                                     // ST-03v mismatch / http
                            case offline(ModelDescriptor, bytesWritten: Int64, total: Int64) }                       // ST-03o
    var speechRows: [Row]; var styleRows: [Row]; var alert: Alert?; var footerText: String  // "3.5 GB in ~/Library/Application Support/VoxFlow/Models. Downloads happen only when you press Download …"
    init(store: ModelStore, catalog: [ModelDescriptor] = ModelCatalog.all)
    func refresh() async
    func download(_ model: ModelDescriptor) async     // runs store.install, updates the row per state, maps errors to alerts
    func pause(_ model: ModelDescriptor)              // cancels the install task → .paused
    func resume(_ model: ModelDescriptor) async       // = download
    func requestRemove(_ model: ModelDescriptor)      // → .removeModel alert (blocked with an explanatory alert if cannotRemoveOnlyModel)
    func confirmRemove() async
    func useSmallModelInstead() async                 // SYS-DISK: "Use the 480 MB model"
}
```
Tests (FakeModelDownloader etc.): rows reflect notInstalled/installed/paused from disk; `download` streams `.downloading` then `.verifying` then `.installed`; insufficient space → `.insufficientSpace` alert with the numbers; checksum mismatch → `.downloadFailed`; offline → `.offline` with bytes and a resume that continues from the partial; `requestRemove` on the only speech model → alert explaining ST-03d; `confirmRemove` switches the default.

View (ST-03): two groups "Speech recognition" and "Cleanup & styles", rows with DEFAULT / RECOMMENDED badges, state-specific trailing controls: Installed (+ Remove… menu), Download, progress "744 MB of 1.2 GB · 1 min left" + Pause, Resume, "Verifying download… checking 1.2 GB against the published checksum" (indeterminate), failed row "The download didn't verify (checksum mismatch). Nothing was installed and the file was deleted." + Retry download; footer text. Alerts per `Alert`. The Qwen row shows "Download" disabled with tooltip "Available in a later version" (phase 5).

- [ ] Commit `feat(v2): add Settings › Models`.

---

### Task 5: App integration, project types, README, PR
- `VoxFlowApp`: `@NSApplicationDelegateAdaptor`, `.commands { CommandGroup(replacing: .newItem) { Button("Open…") { openFiles() }.keyboardShortcut("o") } }` (menu bar extra keeps its own ⌘O in its own menu).
- `project.yml`: `CFBundleDocumentTypes` (viewer, `LSItemContentTypes: [public.audio, public.movie]`).
- Home page: leave placeholder (phase 4).
- `v2/README.md`: "What works today" section (files transcription, models).
- Manual verification recorded in the PR: transcribe a real file end to end with turbo; drop on Dock; pause/resume a download; remove a model; export in all five formats.
- PR `feat(v2): phase 2b Files page and Settings › Models` into `develop`, `Refs #109`; after merge: close #109 and mark the promotion gate reached in #105.

## Self-review
- Coverage: MW-06 (queue), MW-06g (drag-over), MW-06r (result), MW-06x (errors), MW-06c (stop), 2d (empty), 2f (result details), ST-03/ST-03v/ST-03d/SYS-DISK/ST-03o, Dock drop, Choose Files, output settings. Not built: notifications MB-04 (phase 4), "Apply Casual cleanup" and "Segment length" (phase 4/5), Qwen download (phase 5).
- Placeholders: Task 2/4 tests are specified as cases, not full code — the executing agent writes them; each case has concrete inputs/expectations above. Task 3 is view code with a manual check.
- Type consistency: `FilesViewModel.Confirmation`, `ExportedResult`, `ResultViewModel` init parameters, `ModelsViewModel.Alert` are used consistently in views; `Navigation.settingsTab` added in Task 4 and used by the banner in Task 3 (Task 3 may add the enum stub if it lands first).

#### Task 2 — full code

`v2/VoxFlow/Files/FilesViewModel.swift`:
```swift
import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// State and rules of the Files page (design 1c Files, MW-06, MW-06c, MW-06x, 3e). Views render it; nothing else decides.
@Observable @MainActor
final class FilesViewModel {
    enum Confirmation: Equatable {
        /// MW-06c: stop the running file? Only asked above 10 % progress.
        case stop(QueueItem, progress: Double)
        /// 3e "huge input": more than 4 hours in one drop.
        case longAudio(urls: [URL], hours: Double)
    }

    struct ExportedResult: Equatable {
        let item: QueueItem
        let document: TranscriptDocument
        let url: URL?
    }

    static let stopConfirmationThreshold = 0.10
    static let longAudioThresholdHours = 4.0
    /// Measured on an M1 Max with large-v3-turbo (ADR-002); used for the "about N min" estimate only.
    static let estimatedRealTimeFactor = 0.063
    static let uiRefreshInterval: TimeInterval = 1

    private(set) var items: [QueueItem] = []
    var confirmation: Confirmation?
    var selected: ExportedResult?
    private(set) var needsModel = false
    var isDragOver = false
    private(set) var exportedURLs: [UUID: URL] = [:]
    private(set) var exportErrors: [UUID: String] = [:]
    private(set) var etaSeconds: [UUID: TimeInterval] = [:]

    private let queue: FileQueue
    private let settings: FilesSettings
    private let modelStore: ModelStore
    private let makeExporter: () -> TranscriptExporter
    private let now: () -> Date
    private var estimators: [UUID: ETAEstimator] = [:]
    private var lastRender: [UUID: Date] = [:]
    private var eventTask: Task<Void, Never>?

    init(queue: FileQueue, settings: FilesSettings, modelStore: ModelStore,
         exporter: @escaping () -> TranscriptExporter, now: @escaping () -> Date = { Date() }) {
        self.queue = queue
        self.settings = settings
        self.modelStore = modelStore
        self.makeExporter = exporter
        self.now = now
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await queue.subscribe()
            self.items = await queue.items
            for await event in stream {
                guard !Task.isCancelled else { break }
                self.apply(event)
            }
        }
    }

    deinit { eventTask?.cancel() }

    // MARK: Derived text (design 1c / MW-06x)

    var headerTitle: String {
        items.isEmpty ? "" : "Queue · \(items.count) \(items.count == 1 ? "file" : "files")"
    }

    var headerSubtitle: String {
        var parts: [String] = []
        let total = items.compactMap(\.duration).reduce(0, +)
        if total > 0 { parts.append("\(Self.hoursMinutes(total)) of audio") }
        let done = items.filter { if case .done = $0.status { true } else { false } }.count
        let running = items.filter { if case .running = $0.status { true } else { false } }.count
        let failed = items.filter { if case .failed = $0.status { true } else { false } }.count
        if done > 0 { parts.append("\(done) done") }
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) need\(failed == 1 ? "s" : "") attention") }
        return parts.joined(separator: " · ")
    }

    var queuedCount: Int { items.filter { $0.status == .queued }.count }

    var transcribeButtonTitle: String {
        "Transcribe \(queuedCount) \(queuedCount == 1 ? "file" : "files") as \(settings.outputFormat.displayName)"
    }

    var canTranscribe: Bool { queuedCount > 0 && !needsModel }

    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }

    // MARK: Actions

    func refreshModelState() async {
        needsModel = await modelStore.installedModels(role: .speech).isEmpty
    }

    func addFiles(_ urls: [URL]) async {
        var total: TimeInterval = 0
        for url in urls where SupportedAudio.isSupported(url) {
            total += (try? await AudioDurationReaderBox.shared.duration(of: url)) ?? 0
        }
        let hours = total / 3600
        if hours > Self.longAudioThresholdHours {
            confirmation = .longAudio(urls: urls, hours: hours)
            return
        }
        await queue.add(urls)
    }

    func confirmLongAudio() async {
        guard case .longAudio(let urls, _) = confirmation else { return }
        confirmation = nil
        await queue.add(urls)
    }

    func cancelConfirmation() { confirmation = nil }

    func transcribeAll() async {
        await refreshModelState()
        guard canTranscribe else { return }
        await queue.start()
    }

    func requestStop(_ item: QueueItem) async {
        if case .running(let progress) = item.status, progress > Self.stopConfirmationThreshold {
            confirmation = .stop(item, progress: progress)
        } else {
            await queue.cancel(id: item.id)
        }
    }

    func confirmStop() async {
        guard case .stop(let item, _) = confirmation else { return }
        confirmation = nil
        await queue.cancel(id: item.id)
    }

    func remove(_ item: QueueItem) async { await queue.remove(id: item.id) }
    func retry(_ item: QueueItem) async { await queue.retry(id: item.id); await queue.start() }

    func open(_ item: QueueItem) {
        guard case .done(let document) = item.status else { return }
        selected = ExportedResult(item: item, document: document, url: exportedURLs[item.id])
    }

    func closeResult() { selected = nil }
    func exported(for item: QueueItem) -> URL? { exportedURLs[item.id] }

    /// "about 3 min left" for a running row, throttled to one update per second (design 3d).
    func etaText(for item: QueueItem) -> String? {
        guard let seconds = etaSeconds[item.id] else { return nil }
        if seconds < 60 { return "about \(Int(seconds.rounded())) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    static func estimatedMinutes(forHours hours: Double) -> Int {
        Int((hours * 60 * estimatedRealTimeFactor).rounded(.up))
    }

    // MARK: Events

    private func apply(_ event: FileQueueEvent) {
        switch event {
        case .added(let item):
            items.append(item)
        case .changed(let item):
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            if case .running(let progress) = item.status {
                var estimator = estimators[item.id] ?? ETAEstimator()
                estimator.record(progress: progress, at: now().timeIntervalSince1970)
                estimators[item.id] = estimator
                let last = lastRender[item.id] ?? .distantPast
                guard now().timeIntervalSince(last) >= Self.uiRefreshInterval || progress >= 1 else { return }
                lastRender[item.id] = now()
                etaSeconds[item.id] = estimator.secondsRemaining
            } else {
                estimators[item.id] = nil
                etaSeconds[item.id] = nil
                lastRender[item.id] = nil
            }
            items[index] = item
        case .removed(let id):
            items.removeAll { $0.id == id }
            exportedURLs[id] = nil
            exportErrors[id] = nil
        case .finished(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            if case .done(let document) = item.status {
                do {
                    exportedURLs[item.id] = try makeExporter().export(document, format: settings.outputFormat, timestamps: settings.timestamps)
                } catch {
                    exportErrors[item.id] = error.localizedDescription
                }
            }
        case .idle:
            break
        }
    }
}

/// Duration reads for the > 4 h check happen before the queue sees the files; one shared reader.
enum AudioDurationReaderBox {
    static let shared: any AudioDurationProviding = VoxFlowAudio.AudioDurationReader()
}
```
(`FilesViewModel` gets `durations: any AudioDurationProviding` injected instead of the `AudioDurationReaderBox` global — replace the box with an `init` parameter `durations:`; tests pass `FakeAudioDuration`. The box shown above must NOT be implemented; it is here only to make the dependency explicit.)

`v2/VoxFlow/Files/ResultViewModel.swift`:
```swift
import Foundation
import VoxFlowCore
import VoxFlowFiles

protocol Pasteboard { func setString(_ string: String) }
protocol FileRevealing { func reveal(_ url: URL) }

/// The transcript result screen (design 2f / MW-06r).
@Observable @MainActor
final class ResultViewModel {
    let document: TranscriptDocument
    let autoDetectedLanguage: Bool
    var format: OutputFormat { didSet { rerender() } }
    var timestamps: Bool { didSet { rerender() } }
    var searchText = ""
    private(set) var rendered = ""
    private(set) var savedURL: URL?
    private(set) var exportMessage: String?

    private let makeExporter: () -> TranscriptExporter
    private let pasteboard: any Pasteboard
    private let revealer: any FileRevealing

    init(document: TranscriptDocument, format: OutputFormat, timestamps: Bool, autoDetectedLanguage: Bool, savedURL: URL?,
         exporter: @escaping () -> TranscriptExporter, pasteboard: any Pasteboard, revealer: any FileRevealing) {
        self.document = document
        self.format = format
        self.timestamps = timestamps
        self.autoDetectedLanguage = autoDetectedLanguage
        self.savedURL = savedURL
        self.makeExporter = exporter
        self.pasteboard = pasteboard
        self.revealer = revealer
        if let savedURL { exportMessage = "Saved to \(Self.abbreviate(savedURL))" }
        rerender()
    }

    var visibleSegments: [TranscriptSegment] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return document.transcript.segments }
        return document.transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    /// "1:32:10 · 13,842 words · EN (auto) · whisper-large-v3-turbo · took 4 min 12 s on this Mac"
    var metaLine: String {
        let words = NumberFormatter.localizedString(from: NSNumber(value: document.wordCount), number: .decimal)
        let language = (document.transcript.language ?? "auto").uppercased() + (autoDetectedLanguage ? " (auto)" : "")
        return "\(TimeCode.short(document.audioDuration)) · \(words) words · \(language) · \(document.modelID) · took \(Self.took(document.processingTime)) on this Mac"
    }

    var otherFormats: [OutputFormat] { OutputFormat.allCases.filter { $0 != format } }

    func copy() { pasteboard.setString(rendered) }

    @discardableResult
    func exportAlso(_ other: OutputFormat) throws -> URL {
        let url = try makeExporter().export(document, format: other, timestamps: timestamps)
        exportMessage = "Saved to \(Self.abbreviate(url))"
        return url
    }

    func reveal() { if let savedURL { revealer.reveal(savedURL) } }

    private func rerender() { rendered = TranscriptRenderer.render(document, format: format, timestamps: timestamps) }

    static func took(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
```

`v2/VoxFlowTests/FilesViewModelTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("FilesViewModel") @MainActor
struct FilesViewModelTests {
    static let a = URL(fileURLWithPath: "/tmp/interview-raw.m4a")
    static let b = URL(fileURLWithPath: "/tmp/standup-0906.mp3")
    static let bad = URL(fileURLWithPath: "/tmp/meeting-notes.pages")

    static func doc(_ url: URL) -> TranscriptDocument {
        TranscriptDocument(sourceURL: url, transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "ok")!], language: "en"),
                           modelID: "m", audioDuration: 60, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }

    struct Harness {
        let dir = TemporaryDirectory()
        let transcriber = FakeFileTranscriber()
        let durations: FakeAudioDuration
        let settings = FilesSettings(store: InMemoryKeyValueStore())
        let store: ModelStore
        let queue: FileQueue
        let viewModel: FilesViewModel

        init(durations: [URL: TimeInterval] = [a: 2892, b: 724], installedModel: Bool = true) async throws {
            self.durations = FakeAudioDuration(durations)
            let downloader = FakeModelDownloader()
            let payload = Data(repeating: 1, count: 100)
            let model = ModelDescriptor(id: "m", displayName: "m", role: .speech, downloadURL: URL(string: "https://x/m.bin")!,
                                        sizeInBytes: 100, sha256: SHA256File.hexDigest(of: payload), languagesSummary: "", isDefault: true)
            store = ModelStore(directory: dir.file("models"), catalog: [model], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
            if installedModel {
                await downloader.serve(payload, at: model.downloadURL)
                for try await _ in await store.install(id: "m") {}
            }
            queue = FileQueue(transcriber: transcriber, durations: self.durations, supportedExtensions: SupportedAudio.extensions,
                              options: { TranscriptionOptions() })
            let exportDir = dir.file("Transcripts")
            viewModel = FilesViewModel(queue: queue, settings: settings, modelStore: store, durations: self.durations,
                                       exporter: { TranscriptExporter(directory: exportDir) })
            await viewModel.refreshModelState()
        }

        /// Lets the view model's event task apply everything the queue published so far.
        func settle() async {
            await queue.waitUntilIdle()
            for _ in 0..<50 { await Task.yield() }
        }
    }

    @Test("under 4 h adds directly; over 4 h asks first (3e)")
    func longAudioConfirmation() async throws {
        let h = try await Harness(durations: [Self.a: 3 * 3600, Self.b: 2 * 3600])
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        #expect(h.viewModel.items.count == 1)
        await h.viewModel.addFiles([Self.b])
        await h.settle()
        #expect(h.viewModel.confirmation == .longAudio(urls: [Self.b], hours: 2))   // 3 h already + 2 h? No: threshold is per drop
        // The rule is per drop: a single drop over 4 h asks. Re-check with a 5 h file.
    }
```
(The test above is deliberately wrong to show the rule; write the real tests as follows.)

Real `FilesViewModelTests` cases (write in full):
1. `longAudioPerDrop`: durations `[a: 5 * 3600]` → `addFiles([a])` sets `.longAudio(urls: [a], hours: 5)` and `items.isEmpty`; `confirmLongAudio()` then adds; `cancelConfirmation()` path leaves items empty.
2. `headerTexts`: add `a`, `b`, `bad`; script `a` → failure `.decodeFailed("corrupt")`, `b` → document; `transcribeAll()`; `settle()`; expect `headerTitle == "Queue · 3 files"`, `headerSubtitle == "1 h 0 min of audio · 1 done · 2 need attention"` (durations 2892 + 724 = 3616 s = 60 min → "1 h"; adjust the expected string to what `hoursMinutes` produces and assert that exact string) — note `bad` fails on add (unsupported).
3. `transcribeButton`: two queued → "Transcribe 2 files as TXT"; set `settings.outputFormat = .srt` → "… as SRT"; `canTranscribe` true; with `installedModel: false` → `needsModel` true and `canTranscribe` false; `transcribeAll()` leaves `queue.isRunning == false`.
4. `stopRule`: hold `a`; start; wait until held; the running item's progress is 0.75 (fake steps reported before parking) → `requestStop(item)` sets `.stop(item, progress: 0.75)`; `confirmStop()` cancels → item `.cancelled`. Then a second harness with `transcriber.setProgressSteps([0.05])` → `requestStop` cancels immediately without confirmation.
5. `autoExportAndOpen`: script `a` → document; `settings.outputFormat = .srt`; `transcribeAll()`; `settle()`; `exported(for: item)!.lastPathComponent == "interview-raw.srt"` and the file exists; `open(item)` sets `selected?.url` to it; `closeResult()` clears.
6. `etaThrottle`: with an injected clock (`now` closure over a `TestClock`), running progress events at t=0 (0), t=0.2 (0.25), t=1.1 (0.5) → `etaText` is nil after the first two (no second elapsed / no rate) and non-nil after the third; assert the string format "about N s left".

`v2/VoxFlowTests/ResultViewModelTests.swift` (write in full): `FakePasteboard`/`FakeRevealer` classes; `rendered` changes with `format`; `copy()` writes the rendered text; `searchText = "attention"` filters; `metaLine` for the design example (5530 s, 13_842 words, "en", auto, 252 s) == "1:32:10 · 13,842 words · EN (auto) · whisper-large-v3-turbo · took 4 min 12 s on this Mac"; `exportAlso(.vtt)` writes a file into the temp exporter dir and sets `exportMessage` starting with "Saved to"; `reveal()` forwards `savedURL`.

#### Task 4 — full code

`v2/VoxFlow/Settings/ModelsViewModel.swift`:
```swift
import Foundation
import VoxFlowCore
import VoxFlowModels

/// Settings › Models (design ST-03, ST-03v, ST-03d, ST-03o, SYS-DISK). Rows mirror `ModelStore`; alerts are data.
@Observable @MainActor
final class ModelsViewModel {
    struct Row: Identifiable, Equatable {
        let model: ModelDescriptor
        var state: ModelState
        var isDefault: Bool
        var id: String { model.id }
        var sizeText: String { ModelsViewModel.gigabytes(model.sizeInBytes) }
        var subtitle: String { "\(sizeText) · \(model.languagesSummary)" }
        var isAvailable: Bool { !model.sha256.isEmpty }   // the Qwen row ships in phase 5
    }

    enum Alert: Equatable {
        case insufficientSpace(ModelDescriptor, required: Int64, available: Int64)
        case removeModel(ModelDescriptor)
        case cannotRemoveOnlyModel(ModelDescriptor)
        case downloadFailed(ModelDescriptor, reason: String)
        case offline(ModelDescriptor, bytesWritten: Int64, total: Int64)
    }

    private(set) var speechRows: [Row] = []
    private(set) var styleRows: [Row] = []
    var alert: Alert?
    private(set) var footerText = ""

    private let store: ModelStore
    private let catalog: [ModelDescriptor]
    private var installs: [String: Task<Void, Never>] = [:]

    init(store: ModelStore, catalog: [ModelDescriptor] = ModelCatalog.all) {
        self.store = store
        self.catalog = catalog
    }

    func refresh() async {
        var speech: [Row] = [], style: [Row] = []
        let defaultSpeech = await store.defaultModel(role: .speech)?.id
        let defaultStyle = await store.defaultModel(role: .style)?.id
        var installedBytes: Int64 = 0
        for model in catalog {
            let state = await store.state(of: model.id)
            if state == .installed { installedBytes += model.sizeInBytes }
            let row = Row(model: model, state: state, isDefault: (model.role == .speech ? defaultSpeech : defaultStyle) == model.id)
            if model.role == .speech { speech.append(row) } else { style.append(row) }
        }
        speechRows = speech
        styleRows = style
        footerText = "\(Self.gigabytes(installedBytes)) in \(Self.abbreviate(store.directory)). Downloads happen only when you press Download — VoxFlow never checks for or fetches anything on its own."
    }

    func download(_ model: ModelDescriptor) async {
        guard installs[model.id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await state in await store.install(id: model.id) {
                    self.setState(state, for: model.id)
                }
            } catch ModelStoreError.insufficientDiskSpace(let required, let available) {
                self.alert = .insufficientSpace(model, required: required, available: available)
            } catch ModelStoreError.downloadInterrupted(let written) {
                self.alert = .offline(model, bytesWritten: written, total: model.sizeInBytes)
            } catch ModelStoreError.checksumMismatch {
                self.alert = .downloadFailed(model, reason: "The download didn't verify (checksum mismatch). Nothing was installed and the file was deleted.")
            } catch ModelStoreError.http(let status) {
                self.alert = .downloadFailed(model, reason: "The server answered \(status).")
            } catch is CancellationError {
                // Pause: the partial stays; refresh() shows .paused
            } catch {
                self.alert = .downloadFailed(model, reason: String(describing: error))
            }
            self.installs[model.id] = nil
            await self.refresh()
        }
        installs[model.id] = task
        await task.value
    }

    func pause(_ model: ModelDescriptor) { installs[model.id]?.cancel() }
    func resume(_ model: ModelDescriptor) async { await download(model) }

    func requestRemove(_ model: ModelDescriptor) async {
        let others = await store.installedModels(role: model.role).filter { $0.id != model.id }
        if model.role == .speech, others.isEmpty { alert = .cannotRemoveOnlyModel(model) } else { alert = .removeModel(model) }
    }

    func confirmRemove() async {
        guard case .removeModel(let model) = alert else { return }
        alert = nil
        do { try await store.remove(id: model.id) } catch { alert = .downloadFailed(model, reason: String(describing: error)) }
        await refresh()
    }

    /// SYS-DISK: "Use the 480 MB model" — start the smallest speech model instead.
    func useSmallerModelInstead() async {
        guard case .insufficientSpace = alert else { return }
        alert = nil
        if let small = catalog.filter({ $0.role == .speech }).min(by: { $0.sizeInBytes < $1.sizeInBytes }) { await download(small) }
    }

    func dismissAlert() { alert = nil }

    private func setState(_ state: ModelState, for id: String) {
        if let index = speechRows.firstIndex(where: { $0.id == id }) { speechRows[index].state = state }
        if let index = styleRows.firstIndex(where: { $0.id == id }) { styleRows[index].state = state }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1 ? String(format: "%.1f GB", gb) : "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    static func abbreviate(_ url: URL) -> String { ResultViewModel.abbreviate(url) }

    /// "744 MB of 1.2 GB · 1 min left" for a downloading row (ETA from the row's ETAEstimator in the view).
    static func progressText(written: Int64, total: Int64) -> String {
        "\(gigabytes(written)) of \(gigabytes(total))"
    }
}
```

`v2/VoxFlowTests/ModelsViewModelTests.swift` (write in full using `FakeModelDownloader`, `FakeFreeSpace`, `InMemoryKeyValueStore`, `TemporaryDirectory`, a two-model speech catalog `big` (default, 300 000 B) / `small` (100 000 B) and one style row with empty sha256):
1. `refreshReflectsDisk`: fresh store → both speech rows `.notInstalled`, style row `isAvailable == false`; after installing `big` via the store, `refresh()` shows `.installed` with `isDefault` and `footerText` starts with "0.3 MB in" (300 000 B → "0 MB"? use `gigabytes` output: 300000 B → "0 MB"; make the catalog sizes 1.6 GB / 480 MB with payloads sized... too big. Ruling: assert `footerText.hasSuffix("never checks for or fetches anything on its own.")` and contains `abbreviate(store.directory)`; test `gigabytes` separately: 1_624_555_275 → "1.6 GB", 487_601_967 → "488 MB", 744_000_000 → "744 MB").
2. `downloadStates`: `download(big)` → observed states include `.downloading`, `.verifying`, ends `.installed`; `alert == nil`.
3. `insufficientSpace`: `FakeFreeSpace(available: 300_000 + ModelStore.reserveBytes - 1)` → `alert == .insufficientSpace(big, required:, available:)` with the exact numbers; `useSmallerModelInstead()` starts `small` (downloader calls contain small's URL) and it installs.
4. `checksumMismatch`: serve wrong bytes → `alert == .downloadFailed(big, reason: "The download didn't verify (checksum mismatch). Nothing was installed and the file was deleted.")`; row back to `.notInstalled`.
5. `offlineThenResume`: `setFailAfterBytes(131_072)` → `alert == .offline(big, bytesWritten: 131_072, total: 300_000)`; row `.paused(...)` after `refresh()`; `resume(big)` completes; downloader `calls.map(\.resumedFrom) == [0, 131_072]`.
6. `pauseKeepsPartial`: `setBlockAfterBytes(131_072)`, start `download(big)` in a `Task`, `waitUntilBlocked()`, `pause(big)`, await the task → no alert, row `.paused(bytesWritten: 131_072, total: 300_000)`.
7. `removeRules`: only `big` installed → `requestRemove(big)` → `.cannotRemoveOnlyModel(big)`; install `small` → `requestRemove(big)` → `.removeModel(big)`; `confirmRemove()` → `big` `.notInstalled`, `small` `isDefault`.
