# VoxFlow v2 Phase 3b — Dictation HUD: fn hotkey, Flow Bar, Accessibility insertion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The second UI happy path of the spec (§7): hold fn in any text field, speak, release, and the recognized text is inserted; when Accessibility insertion is impossible the text lands on the clipboard (FB-04b). The Flow Bar (FB-01…FB-12) renders every `FlowBarState` from phase 3a. Dictations are saved to the encrypted history. Onboarding, the History page and the dictation-related Settings tabs are phase 3c (separate plan and PR).

**Architecture:** Everything in the app target `VoxFlow/Dictation/` and `VoxFlow/FlowBar/`. `DictationCoordinator` (`@Observable @MainActor`) owns the phase-3a `DictationController`, mirrors its `currentAndChanges()` stream into observable state for SwiftUI, keeps the waveform levels (via a `MeteredMicrophone` decorator) and the elapsed counter, and saves finished dictations. `PreflightBuilder` answers the machine's `Preflight` question from AppKit facts (frontmost app, secure input, microphone permission, model readiness). `AccessibilityTextInserter` captures the focused element at fn-down and writes `kAXSelectedTextAttribute` on insert, else pastes to the clipboard. `FnKeyMonitor` turns `NSEvent` flag changes into `fnDown`/`fnUp` and forwards esc / any key only while the HUD is active. `FlowBarPanel` is a non-activating `NSPanel` hosting `FlowBarView`. `ModelLoader` (shared with Files) tracks which model is loaded in the single `WhisperCppEngine`.

**Tech Stack:** SwiftUI + AppKit (`NSPanel`, `NSEvent` monitors, `NSWorkspace`, `NSPasteboard`), ApplicationServices (AX), Carbon (`IsSecureEventInputEnabled`), AVFoundation (`AVCaptureDevice` authorization), Swift Testing, XcodeGen.

**Spec:** design spec §1 (dictation loop), §7 (UI happy path 2); canvas FB-01…FB-12, 3d "Flow Bar" (pill 40 pt, dark HUD material, bottom-center of the display with the key window, appear 160 ms spring scale 0.96→1, width animates 200 ms, 14 bars at 60 fps from RMS, tabular timer, idle pill hides after 6 s), 3e "Secure input", "Focus changes mid-dictation", "Permission revoked later". Issue #110 (UI half, part 1). Phase 3a APIs: `DictationController`, `FlowBarState`, `Preflight`, `MicrophoneAccess`, `ModelReadiness`, `HotkeyMode`, `FlowBarConfig`, `WindowedTranscriber`, `MicrophoneSource`, `DictationStore`, `HistoryKeyProviders`, `RetentionRunner`.

**Rulings taken in this plan (record in the ledger, do not re-decide):**
1. **fn is read with `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`** (plus a local monitor for our own windows). Per Apple, key-related global monitors need Accessibility trust; no CGEventTap, no Input Monitoring. The spike could not disprove this (the shell already had both permissions); if the owner's manual spike run shows Input Monitoring is required, phase 3c's onboarding adds that step — nothing else changes.
2. **The focus target is captured at fn-down** inside the preflight closure (`AccessibilityTextInserter.captureFocus()`), so a focus change mid-dictation still inserts into the original field; if that element is gone or not text-editable at insert time → clipboard (3e).
3. **Insertion writes `kAXSelectedTextAttribute`** on the captured element (replaces the selection, or inserts at the caret). No synthetic ⌘V. Editable = the element's role is one of `AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`, or `AXSelectedText` is settable on it.
4. **Permission prompts happen lazily in 3b**: the first fn-down asks for Microphone (`AVCaptureDevice.requestAccess`) and Accessibility (`AXIsProcessTrustedWithOptions` with the prompt option) if not determined; denial shows FB-07 with "Open Settings". Onboarding (3c) makes this friendly.
5. **The language chip shows the detected code** ("EN", "EN?" when low confidence) and is not clickable in 3b; the FB-11 popover and ⌥L cycling come with the Hotkeys/General settings in phase 4.
6. **Idle pill**: the panel shows on the first non-idle state and hides 6 s after returning to idle (3d), or immediately when the machine enters `.idle` from a dismiss timer — the design's "hides after 6 s without focus in an editable field" is approximated as "6 s in idle".
7. **History save** happens for every `.inserted`/`.copied` when `keepHistory` is on (default on). Storage errors are logged (`os.Logger`) and never surface in the HUD.
8. **Excluded apps** are matched by bundle identifier from a list in `DictationSettings`; the Privacy UI to edit it is 3c. Default list: `com.1password.1password`, `com.apple.keychainaccess`.
9. **One model loader**: `ModelLoader` actor replaces the private `loadedModelID` in `LazyModelFileTranscriber` so Files and dictation share one loaded-model fact and never reload needlessly.
10. **Hotkey mode default** is push-to-talk (the design's idle hint follows `DictationSettings.hotkeyMode`); both gestures are always active (3a machine).

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated` in the app target (the existing test-only `FakeSystemSettingsOpener` exception stays).
- Views hold no business rules: every decision (copy per state, editable-role classification, fn transition decoding, save mapping, hide timing) lives in a testable type in `VoxFlow/Dictation` or `VoxFlow/FlowBar` with a Swift Testing test in `VoxFlowTests`.
- Copy follows the canvas verbatim: "Hold fn to dictate" / "Press fn to dictate", "Cleaning up…" + "on this Mac", "Taking longer…", "✓ Inserted into {app}" + "{n} words", "✓ Copied — no text field here" + "⌘V", "Didn't catch that" + "Try again" + "fn", "✕ Discarded", "Microphone access needed" + "Open Settings", "Can't type here · Open Settings" (final review I-3: this Accessibility-denied variant is not reachable from any code path in this PR — see the Accessibility-denied follow-up issue), "Speech model not installed" + "Download 1.6 GB", "Dictation is off in {app}", "Loading model…" + "keep talking", "15:00 · limit reached", "Copy raw transcript".
- Timings from `FlowBarConfig` (3a) are not duplicated in the app; the HUD only renders.
- **Design reference is the rendered canvas**, not its text: `scripts/render_design.sh` produces `.superpowers/design/canvas.pdf` (12 pages). Every UI task's implementer and reviewer compares against the relevant pages; Task 4 renders the HUD states to PNG for that comparison.
- Global key monitoring forwards only fn transitions, esc, and "any key pressed" booleans to the coordinator. No key codes or characters are stored or logged.
- No network. Audio never written to disk.
- Commits: Conventional Commits, owner-authored, no attribution trailers. Branch `feature/110-phase3b-dictation-ui` from `develop`; PR into `develop`.
- Verification per task: `cd VoxFlowKit && swift test --filter VoxFlowTestSupport` where touched, and from the repo root `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`. At the end the manual e2e in Task 5.

---

### Task 1: Settings, permissions, preflight, model loader (no UI)

**Files:**
- Modify: `VoxFlowKit/Package.swift` — `VoxFlowTestSupport` target dependencies become `["VoxFlowCore", "VoxFlowDictation"]`.
- Move: `VoxFlowKit/Tests/VoxFlowDictationTests/Fakes.swift` → `VoxFlowKit/Sources/VoxFlowTestSupport/FakeDictationTranscriber.swift` (make the type and its members `public`, keep `Gate` public in TestSupport too as `Gate.swift`; delete the duplicate `Gate` in `WindowedTranscriberTests.swift` and import `VoxFlowTestSupport` there).
- Modify: `project.yml` — app + test target dependencies add products `VoxFlowDictation`, `VoxFlowStorage`; app `info.properties` add `NSMicrophoneUsageDescription: "VoxFlow listens only while you hold fn. Audio never leaves this Mac."`.
- Create: `VoxFlow/Dictation/DictationSettings.swift`, `VoxFlow/Dictation/Permissions.swift`, `VoxFlow/Dictation/FrontmostApp.swift`, `VoxFlow/Dictation/PreflightBuilder.swift`, `VoxFlow/Dictation/ModelLoader.swift`
- Modify: `VoxFlow/Files/LazyModelFileTranscriber.swift` — use `ModelLoader`.
- Test: `VoxFlowTests/DictationSettingsTests.swift`, `VoxFlowTests/PreflightBuilderTests.swift`, `VoxFlowTests/ModelLoaderTests.swift`; adjust `VoxFlowTests/LazyModelFileTranscriberTests.swift` to construct a `ModelLoader`.

**Interfaces:**
- `DictationSettings` (`@Observable @MainActor`, `init(store: any KeyValueStore)`): `hotkeyMode: HotkeyMode` ("dictation.hotkeyMode", default `.pushToTalk`), `silenceStop: TimeInterval` ("dictation.silenceStop", default 3, clamped by `FlowBarConfig(silenceStop:)`), `language: String?` ("dictation.language", nil = auto), `keepHistory: Bool` ("privacy.keepHistory", default true), `encryptHistory: Bool` ("privacy.encryptHistory", default true), `retentionDays: Int` ("privacy.retentionDays", default 30), `excludedBundleIDs: [String]` ("privacy.excludedApps", comma-separated, default `["com.1password.1password", "com.apple.keychainaccess"]`); `flowBarConfig: FlowBarConfig`; `transcriptionOptions: TranscriptionOptions`; `snapshot: DictationSettingsSnapshot` (Sendable, `Mutex`-boxed like `OptionsSnapshot`) exposing `excludedBundleIDs`, `keepHistory`, `transcriptionOptions` for non-main-actor readers.
- `PermissionState` enum: `.notDetermined, .granted, .denied`. `protocol PermissionChecking: Sendable { func microphone() -> PermissionState; func requestMicrophone() async -> PermissionState; func accessibilityTrusted(prompt: Bool) -> Bool; func openMicrophoneSettings(); func openAccessibilitySettings() }`. `SystemPermissions: PermissionChecking` (AVCaptureDevice `.audio`; `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt])`; URLs `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` / `?Privacy_Accessibility`). Test fake `FakePermissions` in `VoxFlowTests/Fakes/`.
- `FrontmostApp` struct (`name: String?`, `bundleID: String?`); `protocol FrontmostAppProviding: Sendable { func frontmostApp() -> FrontmostApp; func secureInputEnabled() -> Bool }`; `WorkspaceFrontmostApp` (NSWorkspace.shared.frontmostApplication; `IsSecureEventInputEnabled()`).
- `ModelLoader` (actor): `init(store: ModelStore, engine: any SpeechEngine)`; `func readiness() async -> ModelReadiness` (`.loaded` when `loadedModelID == store.defaultModel(role: .speech)?.id`; `.installedNotLoaded` when the default is `.installed`; `.notInstalled(sizeBytes:)` otherwise, using the catalog's default speech model size); `func ensureLoaded() async throws` (loads when needed; throws `FileTranscriptionError.noModelInstalled` / `.engineFailed`); `var loadedModelID: String?`.
- `PreflightBuilder` (Sendable struct): `init(frontmost: any FrontmostAppProviding, permissions: any PermissionChecking, modelLoader: ModelLoader, settings: DictationSettingsSnapshot, captureFocus: @Sendable () -> Void)`; `func preflight() async -> Preflight`: excluded app when the frontmost bundle id is in the list → `excludedApp = name ?? bundleID`; `secureInput`; microphone: `.notDetermined` → `await requestMicrophone()`; `.denied` → `.denied`; `.granted`; model: `await modelLoader.readiness()`; calls `captureFocus()` last, only when the result has no gate (excluded/secure/mic denied/model missing all skip it).

- [ ] **Step 1: Failing tests**

`VoxFlowTests/DictationSettingsTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("DictationSettings")
@MainActor
struct DictationSettingsTests {
    @Test("defaults match the design; values persist and clamp")
    func defaults() {
        let store = InMemoryKeyValueStore()
        let s = DictationSettings(store: store)
        #expect(s.hotkeyMode == .pushToTalk)
        #expect(s.silenceStop == 3)
        #expect(s.language == nil)
        #expect(s.keepHistory && s.encryptHistory && s.retentionDays == 30)
        #expect(s.excludedBundleIDs == ["com.1password.1password", "com.apple.keychainaccess"])
        s.hotkeyMode = .handsFree
        s.silenceStop = 42
        s.excludedBundleIDs = ["com.example.a", "com.example.b"]
        s.language = "de"
        let reloaded = DictationSettings(store: store)
        #expect(reloaded.hotkeyMode == .handsFree)
        #expect(reloaded.silenceStop == 10)                       // clamped through FlowBarConfig
        #expect(reloaded.flowBarConfig.silenceStop == 10)
        #expect(reloaded.excludedBundleIDs == ["com.example.a", "com.example.b"])
        #expect(reloaded.transcriptionOptions.language == "de")
        #expect(reloaded.snapshot.excludedBundleIDs == ["com.example.a", "com.example.b"])
    }
}
```

`VoxFlowTests/PreflightBuilderTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("PreflightBuilder")
struct PreflightBuilderTests {
    func builder(app: FrontmostApp = FrontmostApp(name: "Mail", bundleID: "com.apple.mail"), secure: Bool = false,
                 mic: PermissionState = .granted, requestResult: PermissionState = .granted,
                 readiness: ModelReadiness = .loaded, excluded: [String] = ["com.1password.1password"]) async
        -> (PreflightBuilder, FakePermissions, Mutex<Int>) {
        let permissions = FakePermissions(microphone: mic, requestResult: requestResult, accessibility: true)
        let loader = FakeModelReadiness(readiness)
        let captured = Mutex(0)
        let builder = PreflightBuilder(frontmost: FakeFrontmost(app: app, secure: secure), permissions: permissions,
                                       readiness: { await loader.readiness() },
                                       settings: DictationSettingsSnapshot(excludedBundleIDs: excluded, keepHistory: true, options: TranscriptionOptions()),
                                       captureFocus: { captured.withLock { $0 += 1 } })
        return (builder, permissions, captured)
    }

    @Test("happy path: everything granted, model loaded, focus captured once")
    func happy() async {
        let (b, _, captured) = await builder()
        let p = await b.preflight()
        #expect(p == Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded))
        #expect(captured.withLock { $0 } == 1)
    }

    @Test("excluded app and secure input gate before permissions; focus is not captured")
    func gates() async {
        let (a, _, capA) = await builder(app: FrontmostApp(name: "1Password", bundleID: "com.1password.1password"))
        #expect(await a.preflight().excludedApp == "1Password")
        #expect(capA.withLock { $0 } == 0)
        let (s, _, _) = await builder(secure: true)
        #expect(await s.preflight().secureInput)
    }

    @Test("not-determined microphone permission is requested once; denied stays denied")
    func microphone() async {
        let (b, perms, cap) = await builder(mic: .notDetermined, requestResult: .granted)
        #expect(await b.preflight().microphone == .granted)
        #expect(perms.requests == 1)
        #expect(cap.withLock { $0 } == 1)
        let (d, _, capD) = await builder(mic: .denied)
        #expect(await d.preflight().microphone == .denied)
        #expect(capD.withLock { $0 } == 0)
    }

    @Test("model readiness is passed through")
    func model() async {
        let (b, _, cap) = await builder(readiness: .notInstalled(sizeBytes: 1_624_555_275))
        #expect(await b.preflight().model == .notInstalled(sizeBytes: 1_624_555_275))
        #expect(cap.withLock { $0 } == 0)
    }
}

struct FakeFrontmost: FrontmostAppProviding {
    let app: FrontmostApp; let secure: Bool
    func frontmostApp() -> FrontmostApp { app }
    func secureInputEnabled() -> Bool { secure }
}

actor FakeModelReadiness {
    let value: ModelReadiness
    init(_ value: ModelReadiness) { self.value = value }
    func readiness() -> ModelReadiness { value }
}
```
`FakePermissions` (in `VoxFlowTests/Fakes/FakePermissions.swift`): `final class FakePermissions: PermissionChecking, Sendable` with `Mutex` state: `microphone`, `requestResult`, `accessibility: Bool`, counters `requests`, `openedMicrophoneSettings`, `openedAccessibilitySettings`, `prompted`.

Note: `PreflightBuilder.init` takes `readiness: @Sendable () async -> ModelReadiness` (not the actor) so tests need no `ModelStore`; `AppServices` passes `{ await modelLoader.readiness() }`.

`VoxFlowTests/ModelLoaderTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("ModelLoader")
struct ModelLoaderTests {
    func store(installed: Bool) async throws -> (ModelStore, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let model = ModelCatalog.all.first { $0.role == .speech && $0.isDefault }!
        if installed { try Data(repeating: 0, count: 8).write(to: dir.url.appendingPathComponent(model.fileName)) }
        let store = ModelStore(directory: dir.url, downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 1 << 40),
                               settings: InMemoryKeyValueStore())
        return (store, dir)
    }

    @Test("readiness: not installed → size; installed → installedNotLoaded; after ensureLoaded → loaded (engine loaded once)")
    func readiness() async throws {
        let (missing, _) = try await store(installed: false)
        let engine = FakeSpeechEngine(script: [])
        #expect(await ModelLoader(store: missing, engine: engine).readiness() == .notInstalled(sizeBytes: 1_624_555_275))

        let (present, _) = try await store(installed: true)
        let loader = ModelLoader(store: present, engine: engine)
        #expect(await loader.readiness() == .installedNotLoaded)
        try await loader.ensureLoaded()
        try await loader.ensureLoaded()
        #expect(await loader.readiness() == .loaded)
        #expect(await engine.loadedModelURL?.lastPathComponent == "ggml-large-v3-turbo.bin")
    }
}
```
Check how `ModelStore` decides `.installed` (size match or marker) in `ModelStore.swift` and write the fixture accordingly (the phase-2 tests in `VoxFlowTests/LazyModelFileTranscriberTests.swift` already do this — copy their helper). If `FakeSpeechEngine` has no `loadCount`, assert on `loadedModelURL` only.

- [ ] **Step 2: Run** `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test -only-testing:VoxFlowTests 2>&1 | tail -20` — compile failure.

- [ ] **Step 3: Implementation**

`VoxFlow/Dictation/DictationSettings.swift`:
```swift
import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation

/// Sendable view of the settings the dictation loop reads off the main actor.
struct DictationSettingsSnapshot: Sendable, Equatable {
    var excludedBundleIDs: [String]
    var keepHistory: Bool
    var options: TranscriptionOptions
}

final class DictationSettingsBox: Sendable {
    private let box: Mutex<DictationSettingsSnapshot>
    init(_ initial: DictationSettingsSnapshot) { box = Mutex(initial) }
    var current: DictationSettingsSnapshot { box.withLock { $0 } }
    func update(_ s: DictationSettingsSnapshot) { box.withLock { $0 = s } }
}

/// Dictation and privacy choices (design ST-02 mode, ST-04 silence, ST-05 history/excluded apps).
@Observable @MainActor
final class DictationSettings {
    static let defaultExcluded = ["com.1password.1password", "com.apple.keychainaccess"]
    private let store: any KeyValueStore
    let box: DictationSettingsBox

    var hotkeyMode: HotkeyMode { didSet { store.set(hotkeyMode.rawValue, forKey: "dictation.hotkeyMode") } }
    var silenceStop: TimeInterval {
        didSet {
            silenceStop = FlowBarConfig(silenceStop: silenceStop).silenceStop
            store.set(String(silenceStop), forKey: "dictation.silenceStop")
        }
    }
    var language: String? { didSet { store.set(language, forKey: "dictation.language"); sync() } }
    var keepHistory: Bool { didSet { store.set(keepHistory ? "1" : "0", forKey: "privacy.keepHistory"); sync() } }
    var encryptHistory: Bool { didSet { store.set(encryptHistory ? "1" : "0", forKey: "privacy.encryptHistory") } }
    var retentionDays: Int { didSet { store.set(String(retentionDays), forKey: "privacy.retentionDays") } }
    var excludedBundleIDs: [String] { didSet { store.set(excludedBundleIDs.joined(separator: ","), forKey: "privacy.excludedApps"); sync() } }

    init(store: any KeyValueStore) {
        self.store = store
        hotkeyMode = store.string(forKey: "dictation.hotkeyMode").flatMap(HotkeyMode.init(rawValue:)) ?? .pushToTalk
        silenceStop = FlowBarConfig(silenceStop: store.string(forKey: "dictation.silenceStop").flatMap(Double.init) ?? 3).silenceStop
        language = store.string(forKey: "dictation.language")
        keepHistory = store.string(forKey: "privacy.keepHistory") != "0"
        encryptHistory = store.string(forKey: "privacy.encryptHistory") != "0"
        retentionDays = store.string(forKey: "privacy.retentionDays").flatMap(Int.init) ?? 30
        excludedBundleIDs = store.string(forKey: "privacy.excludedApps").map { $0.split(separator: ",").map(String.init) } ?? Self.defaultExcluded
        box = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        sync()
    }

    var flowBarConfig: FlowBarConfig { FlowBarConfig(silenceStop: silenceStop) }
    var transcriptionOptions: TranscriptionOptions { TranscriptionOptions(language: language) }
    var snapshot: DictationSettingsSnapshot { box.current }

    private func sync() {
        box.update(DictationSettingsSnapshot(excludedBundleIDs: excludedBundleIDs, keepHistory: keepHistory, options: transcriptionOptions))
    }
}
```
(An empty stored string for excluded apps must decode as `[]`, not `[""]` — filter empties.)

`VoxFlow/Dictation/Permissions.swift`:
```swift
import AppKit
import ApplicationServices
import AVFoundation

enum PermissionState: Sendable, Equatable { case notDetermined, granted, denied }

protocol PermissionChecking: Sendable {
    func microphone() -> PermissionState
    func requestMicrophone() async -> PermissionState
    func accessibilityTrusted(prompt: Bool) -> Bool
    func openMicrophoneSettings()
    func openAccessibilitySettings()
}

struct SystemPermissions: PermissionChecking {
    func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func requestMicrophone() async -> PermissionState { await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied }
    func accessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
    func openMicrophoneSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
    func openAccessibilitySettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
    private func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }
}
```

`VoxFlow/Dictation/FrontmostApp.swift`:
```swift
import AppKit
import Carbon.HIToolbox

struct FrontmostApp: Sendable, Equatable { var name: String?; var bundleID: String? }

protocol FrontmostAppProviding: Sendable {
    func frontmostApp() -> FrontmostApp
    func secureInputEnabled() -> Bool
}

struct WorkspaceFrontmostApp: FrontmostAppProviding {
    func frontmostApp() -> FrontmostApp {
        let app = NSWorkspace.shared.frontmostApplication
        return FrontmostApp(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
    func secureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
}
```

`VoxFlow/Dictation/ModelLoader.swift`:
```swift
import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels

/// The one place that knows which speech model the engine holds (ruling 9). Files and dictation share it.
actor ModelLoader {
    private let store: ModelStore
    private let engine: any SpeechEngine
    private(set) var loadedModelID: String?

    init(store: ModelStore, engine: any SpeechEngine) { self.store = store; self.engine = engine }

    func readiness() async -> ModelReadiness {
        guard let model = await store.defaultModel(role: .speech) else {
            let size = ModelCatalog.all.first { $0.role == .speech && $0.isDefault }?.sizeInBytes ?? 0
            return .notInstalled(sizeBytes: size)
        }
        return loadedModelID == model.id ? .loaded : .installedNotLoaded
    }

    /// Loads the default speech model if it is not the one already in the engine.
    func ensureLoaded() async throws {
        guard let model = await store.defaultModel(role: .speech) else { throw FileTranscriptionError.noModelInstalled }
        guard loadedModelID != model.id else { return }
        do { try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName)) }
        catch { throw FileTranscriptionError.engineFailed("model load failed: \(error)") }
        loadedModelID = model.id
    }
}
```
`LazyModelFileTranscriber` becomes: `init(loader: ModelLoader, store: ModelStore, engine:, decoder:)`; `transcribe` does `try await loader.ensureLoaded()` then resolves `model` for the id and delegates to `FileTranscriber` as before. Keep its existing tests green by constructing the loader in them.

`VoxFlow/Dictation/PreflightBuilder.swift`:
```swift
import Foundation
import VoxFlowDictation

/// Answers "may we listen right now?" from AppKit facts (design FB-07, FB-08, FB-10, 3e "Secure input").
struct PreflightBuilder: Sendable {
    let frontmost: any FrontmostAppProviding
    let permissions: any PermissionChecking
    let readiness: @Sendable () async -> ModelReadiness
    let settings: DictationSettingsSnapshot
    /// Called last, only when no gate applies — the inserter remembers the focused element (ruling 2).
    let captureFocus: @Sendable () -> Void

    func preflight() async -> Preflight {
        let app = frontmost.frontmostApp()
        if let id = app.bundleID, settings.excludedBundleIDs.contains(id) {
            return Preflight(excludedApp: app.name ?? id, secureInput: false, microphone: .granted, model: .loaded)
        }
        if frontmost.secureInputEnabled() {
            return Preflight(excludedApp: nil, secureInput: true, microphone: .granted, model: .loaded)
        }
        var mic = permissions.microphone()
        if mic == .notDetermined { mic = await permissions.requestMicrophone() }
        guard mic == .granted else {
            return Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded)
        }
        let model = await readiness()
        if case .notInstalled = model {
            return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: model)
        }
        captureFocus()
        return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: model)
    }
}
```
Note the builder is constructed per `AppServices` with a snapshot read at call time: `AppServices` passes `settings: settingsBox.current` by building the `PreflightBuilder` inside the `preflight` closure (so edits in Settings apply to the next fn-down).

- [ ] **Step 4: Run** the app scheme tests — PASS; `cd VoxFlowKit && swift test` — PASS (TestSupport move compiles; Dictation tests still green).

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit project.yml VoxFlow/Dictation VoxFlow/Files/LazyModelFileTranscriber.swift VoxFlowTests
git commit -m "feat(app): dictation settings, permissions, preflight and a shared model loader"
```

---
### Task 2: Accessibility inserter, fn key decoder, metered microphone

**Files:**
- Create: `VoxFlow/Dictation/AccessibilityTextInserter.swift`, `VoxFlow/Dictation/FnKeyDecoder.swift`, `VoxFlow/Dictation/FnKeyMonitor.swift`, `VoxFlow/Dictation/MeteredMicrophone.swift`
- Test: `VoxFlowTests/EditableRoleTests.swift`, `VoxFlowTests/FnKeyDecoderTests.swift`, `VoxFlowTests/MeteredMicrophoneTests.swift`

**Interfaces:**
- `enum EditableRole { static func isEditable(role: String?, selectedTextSettable: Bool) -> Bool }` — true for `AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`, or when settable.
- `final class AccessibilityTextInserter: TextInserting, Sendable` — `init(permissions: any PermissionChecking, pasteboard: any Pasteboard)`; `func captureFocus()` (stores the system-wide focused `AXUIElement` + frontmost app name in a `Mutex`; no-op when not trusted); `func insert(_ text: String) async -> InsertionResult`: trusted && captured element still editable && `AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute, text)` == `.success` → `.inserted(appName:)`; otherwise `pasteboard.setString(text)` → `.copiedToClipboard`. `AXUIElement` is a `CFTypeRef`; box it in a small `final class FocusTarget: Sendable`-free holder inside the `Mutex` (CF types are not `Sendable` — wrap in a `struct` marked with a `nonisolated(unsafe)`-free approach: store `AXUIElement?` inside `Mutex<AXUIElement?>`; if the compiler rejects, keep the element in a `@MainActor`-confined property and make `captureFocus`/`insert` hop to the main actor — AX calls are fine on the main thread and the controller awaits `insert` anyway).
- `struct FnKeyDecoder { mutating func decode(flags: NSEvent.ModifierFlags) -> FnTransition? }` with `enum FnTransition { case down, up }` — emits `.down` on the first flags with `.function`, `.up` when it clears, ignores repeats.
- `@MainActor final class FnKeyMonitor` — `init(onFn: @escaping (FnTransition) -> Void, onEscape: @escaping () -> Void, onAnyKey: @escaping () -> Void, isHUDActive: @escaping () -> Bool)`; `start()` installs global + local `.flagsChanged` monitors and a global `.keyDown` monitor that calls `onEscape` for keyCode 53 and `onAnyKey` for any other key **only while `isHUDActive()`**; `stop()` removes them. No key data is retained.
- `final class MeteredMicrophone: MicrophoneCapturing, Sendable` — `init(base: any MicrophoneCapturing, onLevel: @Sendable (Float) -> Void)`; forwards every event, calling `onLevel(chunk.rms)` per chunk.

- [ ] **Step 1: Failing tests**

`VoxFlowTests/EditableRoleTests.swift`:
```swift
import Testing
@testable import VoxFlow

@Suite("EditableRole")
struct EditableRoleTests {
    @Test("text roles or a settable selection are editable; others are not", arguments: [
        ("AXTextField", false, true), ("AXTextArea", false, true), ("AXComboBox", false, true), ("AXSearchField", false, true),
        ("AXWebArea", true, true), ("AXList", false, false), ("AXButton", false, false), (nil as String?, false, false),
    ])
    func classify(role: String?, settable: Bool, expected: Bool) {
        #expect(EditableRole.isEditable(role: role, selectedTextSettable: settable) == expected)
    }
}
```

`VoxFlowTests/FnKeyDecoderTests.swift`:
```swift
import AppKit
import Testing
@testable import VoxFlow

@Suite("FnKeyDecoder")
struct FnKeyDecoderTests {
    @Test("down on first fn flag, up when it clears, repeats ignored, other modifiers ignored")
    func transitions() {
        var d = FnKeyDecoder()
        #expect(d.decode(flags: [.function]) == .down)
        #expect(d.decode(flags: [.function]) == nil)
        #expect(d.decode(flags: [.function, .shift]) == nil)
        #expect(d.decode(flags: [.shift]) == .up)
        #expect(d.decode(flags: []) == nil)
        #expect(d.decode(flags: [.command]) == nil)
    }
}
```

`VoxFlowTests/MeteredMicrophoneTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("MeteredMicrophone", .timeLimit(.minutes(1)))
struct MeteredMicrophoneTests {
    @Test("forwards events and reports each chunk's RMS")
    func forwards() async throws {
        let base = FakeMicrophone()
        let levels = Mutex<[Float]>([])
        let metered = MeteredMicrophone(base: base) { levels.withLock { $0.append($1) } }
        let task = Task { () -> [MicrophoneEvent] in
            var out: [MicrophoneEvent] = []
            for try await e in metered.start() { out.append(e); if out.count == 2 { break } }
            return out
        }
        await base.waitUntilCapturing()
        base.emit(rms: 0.5, seconds: 0.01)
        base.emit(rms: 0.25, seconds: 0.01)
        let events = try await task.value
        #expect(events.count == 2)
        #expect(levels.withLock { $0 }.map { ($0 * 100).rounded() / 100 } == [0.5, 0.25])
        await base.waitUntilStopped()
    }
}
```

- [ ] **Step 2: Run** the app tests — compile failure.

- [ ] **Step 3: Implementation**

`FnKeyDecoder.swift`:
```swift
import AppKit

enum FnTransition: Equatable { case down, up }

/// Turns modifier-flag snapshots into fn press/release edges (design 3d "Hotkey timing" feeds the machine).
struct FnKeyDecoder {
    private var isDown = false
    mutating func decode(flags: NSEvent.ModifierFlags) -> FnTransition? {
        let now = flags.contains(.function)
        defer { isDown = now }
        if now && !isDown { return .down }
        if !now && isDown { return .up }
        return nil
    }
}
```

`FnKeyMonitor.swift`:
```swift
import AppKit

/// Global fn / esc / any-key monitoring (ruling 1). Requires Accessibility trust; without it the
/// global monitors return nil and only our own windows deliver events.
@MainActor
final class FnKeyMonitor {
    private var decoder = FnKeyDecoder()
    private var monitors: [Any] = []
    private let onFn: (FnTransition) -> Void
    private let onEscape: () -> Void
    private let onAnyKey: () -> Void
    private let isHUDActive: () -> Bool

    init(onFn: @escaping (FnTransition) -> Void, onEscape: @escaping () -> Void, onAnyKey: @escaping () -> Void, isHUDActive: @escaping () -> Bool) { … }

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in
            guard let self, let t = decoder.decode(flags: event.modifierFlags) else { return }
            onFn(t)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any)
        let keys: (NSEvent) -> Void = { [weak self] event in
            guard let self, isHUDActive() else { return }
            if event.keyCode == 53 { onEscape() } else { onAnyKey() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
    }

    func stop() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll() }
}
```
`NSEvent` monitor handlers run on the main thread; with `@MainActor` on the class the closures must be `@Sendable`-compatible — use `MainActor.assumeIsolated`? **No** (constraint). Instead capture `self` weakly and hop with `Task { @MainActor in … }` if the compiler demands it; the handlers are documented to run on the main thread so a plain `@MainActor`-isolated closure passed as `@Sendable` compiles under Swift 6 when the class is `@MainActor` and the closure only touches main-actor state through `self`. Report what the compiler accepted.

`AccessibilityTextInserter.swift`:
```swift
import AppKit
import ApplicationServices
import Synchronization
import VoxFlowCore

enum EditableRole {
    static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static func isEditable(role: String?, selectedTextSettable: Bool) -> Bool {
        selectedTextSettable || role.map(roles.contains) == true
    }
}

/// Writes dictated text into the field that had focus at fn-down (rulings 2–3); clipboard otherwise (FB-04b).
@MainActor
final class AccessibilityTextInserter: TextInserting {
    private let permissions: any PermissionChecking
    private let pasteboard: any Pasteboard
    private var target: AXUIElement?
    private var appName: String?

    init(permissions: any PermissionChecking, pasteboard: any Pasteboard) { … }

    nonisolated func captureFocus() { Task { @MainActor in self.capture() } }

    private func capture() {
        target = nil; appName = NSWorkspace.shared.frontmostApplication?.localizedName
        guard permissions.accessibilityTrusted(prompt: true) else { return }
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return }
        target = (element as! AXUIElement)
    }

    nonisolated func insert(_ text: String) async -> InsertionResult {
        await MainActor.run { self.performInsert(text) }
    }

    private func performInsert(_ text: String) -> InsertionResult {
        defer { target = nil }
        if let target, permissions.accessibilityTrusted(prompt: false), Self.isEditable(target) {
            let status = AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString)
            if status == .success { return .inserted(appName: appName) }
        }
        pasteboard.setString(text)
        return .copiedToClipboard
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return EditableRole.isEditable(role: role as? String, selectedTextSettable: settable.boolValue)
    }
}
```
`TextInserting` requires `Sendable`; a `@MainActor` class is implicitly `Sendable`. `captureFocus` is fire-and-forget by design: it runs before the first audio chunk arrives (the preflight is awaited before the machine starts capture, and the main-actor hop completes within the same run-loop turn); if a review wants it synchronous, make `captureFocus` `async` and await it in `PreflightBuilder`.

`MeteredMicrophone.swift`:
```swift
import Foundation
import VoxFlowCore

/// Passes microphone events through and reports each chunk's RMS for the 14-bar waveform.
final class MeteredMicrophone: MicrophoneCapturing, Sendable {
    private let base: any MicrophoneCapturing
    private let onLevel: @Sendable (Float) -> Void
    init(base: any MicrophoneCapturing, onLevel: @escaping @Sendable (Float) -> Void) { … }

    func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        let upstream = base.start()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .chunk(let c) = event { onLevel(c.rms) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run** app tests — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(app): Accessibility inserter, fn key monitor and metered microphone"`

---

### Task 3: `DictationCoordinator` and history saving

**Files:**
- Create: `VoxFlow/Dictation/DictationCoordinator.swift`, `VoxFlow/Dictation/HistoryWriter.swift`
- Test: `VoxFlowTests/DictationCoordinatorTests.swift`, `VoxFlowTests/HistoryWriterTests.swift`

**Interfaces:**
- `HistoryWriter` (Sendable struct): `init(store: DictationStore?, settings: DictationSettingsBox, now: @Sendable () -> Date)`; `static func draft(from result: DictationResult, appName: String?, now: Date) -> DictationDraft` (`language = result.language?.code`, `style = nil`, `duration = result.duration`); `func save(_ result: DictationResult, appName: String?) async` — no-op when `keepHistory` is off or `store == nil`; inserts on a detached task (store is blocking); errors logged with `Logger(subsystem: "dev.artemsem.voxflow", category: "history")`.
- `DictationCoordinator` (`@Observable @MainActor`): `init(controller: DictationController, settings: DictationSettings, now: @escaping () -> Date = Date.init)`; observable `state: FlowBarState` (mirrors `currentAndChanges()`), `levels: [Float]` (last 14 RMS values, newest last, initial 14 zeros), `elapsed: TimeInterval` (updated 10×/s from `controller.elapsed` while listening/processing), `hotkeyMode: HotkeyMode` (from settings), `isHUDActive: Bool` (state != .idle); `func fn(_ t: FnTransition)`, `func escape()`, `func anyKey()`, `func copyRaw()`, `func openSettingsForCurrentError()` (delegates to `PermissionChecking` open methods for `.micUnavailable(.denied)` / `.error` "Can't type here"; for `.modelNotInstalled` sets `navigation.settingsTab = .models`, `navigation.page = .settings`, `requestMainWindow = true` — inject `Navigation` and `PermissionChecking`); `func reportLevel(_ rms: Float)` (called from `MeteredMicrophone.onLevel` via `Task { @MainActor in }`); `func start()` begins mirroring; `deinit`-safe: the mirroring task is held in a `Mutex` box and cancelled in `deinit` (pattern from `FilesViewModel`).

- [ ] **Step 1: Failing tests**

`VoxFlowTests/HistoryWriterTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
@testable import VoxFlow

@Suite("HistoryWriter")
struct HistoryWriterTests {
    let result = DictationResult(text: "hello there", rawText: "hello there", segments: [],
                                 language: LanguageDetection(code: "en", confidence: 0.9), duration: 2.5, lowConfidence: false)

    @Test("draft mapping: language code, no style, duration and time carried over")
    func draft() {
        let d = HistoryWriter.draft(from: result, appName: "Mail", now: Date(timeIntervalSince1970: 42))
        #expect(d == DictationDraft(text: "hello there", rawText: "hello there", appName: "Mail", style: nil, language: "en", duration: 2.5,
                                    createdAt: Date(timeIntervalSince1970: 42)))
    }

    @Test("saves when keepHistory is on; skips when off")
    func save() async throws {
        let store = try DictationStore(inMemoryWith: nil)
        let on = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        await HistoryWriter(store: store, settings: on, now: { Date() }).save(result, appName: "Mail")
        #expect(try store.count() == 1)
        let off = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: false, options: TranscriptionOptions()))
        await HistoryWriter(store: store, settings: off, now: { Date() }).save(result, appName: "Mail")
        #expect(try store.count() == 1)
    }
}
```

`VoxFlowTests/DictationCoordinatorTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("DictationCoordinator", .timeLimit(.minutes(1)))
@MainActor
struct DictationCoordinatorTests {
    func make(preflight: Preflight = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded))
        -> (DictationCoordinator, FakeMicrophone, FakeClock, FakePermissions, Navigation) {
        let mic = FakeMicrophone(), clock = FakeClock(), permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let transcriber = FakeDictationTranscriber(result: DictationResult(text: "hi there", rawText: "hi there", segments: [], language: nil, duration: 1, lowConfidence: false))
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { preflight }, loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { _, _ in }, copyToClipboard: { _ in })
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let navigation = Navigation()
        let c = DictationCoordinator(controller: controller, settings: settings, permissions: permissions, navigation: navigation)
        c.start()
        return (c, mic, clock, permissions, navigation)
    }

    /// Waits until the coordinator's observable state satisfies `predicate` (observation-driven, no sleeps).
    func wait(_ c: DictationCoordinator, until predicate: @escaping (FlowBarState) -> Bool) async {
        while !predicate(c.state) { await Task.yield() }
    }

    @Test("mirrors controller state: fn down → armed; HUD active; levels roll")
    func mirrors() async {
        let (c, mic, _, _, _) = make()
        #expect(c.state == .idle && !c.isHUDActive && c.levels.count == 14)
        c.fn(.down)
        await wait(c) { if case .armed = $0 { true } else { false } }
        #expect(c.isHUDActive)
        await mic.waitUntilCapturing()
        c.reportLevel(0.4)
        #expect(c.levels.count == 14 && c.levels.last == 0.4)
        c.escape()
        await wait(c) { $0 == .discarded }
    }

    @Test("open settings routes by state: mic denied → Microphone pane; model missing → Settings › Models")
    func openSettings() async {
        let (denied, _, _, perms, _) = make(preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded))
        denied.fn(.down)
        await wait(denied) { $0 == .micUnavailable(.denied) }
        denied.openSettingsForCurrentError()
        #expect(perms.openedMicrophoneSettings == 1)

        let (missing, _, _, _, nav) = make(preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .notInstalled(sizeBytes: 1)))
        missing.fn(.down)
        await wait(missing) { $0 == .modelNotInstalled(sizeBytes: 1) }
        missing.openSettingsForCurrentError()
        #expect(nav.page == .settings && nav.settingsTab == .models && nav.requestMainWindow)
    }
}
```
The `wait` helper spins on `Task.yield()` — acceptable here because the suite has a time limit and the predicate flips within a few hops; do not add sleeps.

- [ ] **Step 2: Run** — compile failure.

- [ ] **Step 3: Implementation** — `HistoryWriter.swift`:
```swift
import Foundation
import os
import VoxFlowDictation
import VoxFlowStorage

struct HistoryWriter: Sendable {
    let store: DictationStore?
    let settings: DictationSettingsBox
    let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "history")

    static func draft(from result: DictationResult, appName: String?, now: Date) -> DictationDraft {
        DictationDraft(text: result.text, rawText: result.rawText, appName: appName, style: nil,
                       language: result.language?.code, duration: result.duration, createdAt: now)
    }

    func save(_ result: DictationResult, appName: String?) async {
        guard settings.current.keepHistory, let store else { return }
        let draft = Self.draft(from: result, appName: appName, now: now())
        await Task.detached(priority: .utility) {
            do { _ = try store.insert(draft) } catch { Self.log.error("history insert failed: \(String(describing: error))") }
        }.value
    }
}
```

`DictationCoordinator.swift`:
```swift
import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation

/// Main-actor mirror of `DictationController` for the HUD (FB-01…FB-12) — state, waveform levels, elapsed time.
@Observable @MainActor
final class DictationCoordinator {
    static let barCount = 14
    private let controller: DictationController
    private let settings: DictationSettings
    private let permissions: any PermissionChecking
    private let navigation: Navigation
    private let mirror = Mutex<Task<Void, Never>?>(nil)
    private var ticker: Task<Void, Never>?

    private(set) var state: FlowBarState = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationCoordinator.barCount)
    private(set) var elapsed: TimeInterval = 0
    var hotkeyMode: HotkeyMode { settings.hotkeyMode }
    var isHUDActive: Bool { state != .idle }

    init(controller: DictationController, settings: DictationSettings, permissions: any PermissionChecking, navigation: Navigation) { … }

    func start() {
        let task = Task { [weak self, controller] in
            for await s in await controller.currentAndChanges() {
                guard let self else { return }
                await MainActor.run { self.apply(s) }
            }
        }
        mirror.withLock { $0?.cancel(); $0 = task }
    }

    deinit { mirror.withLock { $0?.cancel() }; }

    private func apply(_ s: FlowBarState) {
        state = s
        switch s {
        case .listening, .processing: startTicker()
        default: stopTicker(); elapsed = 0; if case .idle = s { levels = Array(repeating: 0, count: Self.barCount) }
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self, controller] in
            while !Task.isCancelled {
                let e = await controller.elapsed ?? 0
                guard let self else { return }
                self.elapsed = e
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func stopTicker() { ticker?.cancel(); ticker = nil }

    func fn(_ t: FnTransition) {
        Task { [controller] in switch t { case .down: await controller.fnDown(); case .up: await controller.fnUp() } }
    }
    func escape() { Task { [controller] in await controller.escape() } }
    func anyKey() { Task { [controller] in await controller.anyKey() } }
    func copyRaw() { Task { [controller] in await controller.copyRaw() } }

    func reportLevel(_ rms: Float) {
        levels.removeFirst(); levels.append(min(1, rms * 8))   // ×8: speech RMS ≈ 0.02–0.1 → visible bars
    }

    func openSettingsForCurrentError() {
        switch state {
        case .micUnavailable(.denied), .micUnavailable(.noDevice): permissions.openMicrophoneSettings()
        case .error: permissions.openAccessibilitySettings()
        case .modelNotInstalled:
            navigation.settingsTab = .models; navigation.page = .settings; navigation.requestMainWindow = true
        default: break
        }
    }
}
```
The ticker's `Task.sleep` is the one intentional sleep in production code (a 10 Hz UI clock, never in tests: tests do not assert on `elapsed`).

- [ ] **Step 4: Run** app tests — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(app): dictation coordinator and history writer"`

---
### Task 4: Flow Bar panel, view and presenter

**Files:**
- Create: `VoxFlow/FlowBar/FlowBarContent.swift` (pure state → copy mapping), `VoxFlow/FlowBar/FlowBarView.swift`, `VoxFlow/FlowBar/WaveformView.swift`, `VoxFlow/FlowBar/FlowBarPanel.swift`, `VoxFlow/FlowBar/FlowBarPresenter.swift`
- Modify: `VoxFlow/Design/Palette.swift` — add `hudBackground` (`Color(white: 0.11).opacity(0.92)`), `hudText` (white), `hudSecondary` (white 0.6), `recording` (`#ff453a`), `amber` (`#ffd60a`).
- Test: `VoxFlowTests/FlowBarContentTests.swift`, `VoxFlowTests/FlowBarPresenterTests.swift`

**Interfaces:**
- `struct FlowBarContent: Equatable` — mirrors the pill's three zones in the canvas (rendered reference: `.superpowers/design/canvas.pdf` pages 8–9 "2a Flow Bar — edge states", page 11 "1a Flow Bar", page 4 FB-12/TT-01):
  - `leading: Leading` — `enum Leading: Equatable { case dot(DotColor), spinner, check, cross, excluded }` with `enum DotColor { case idle, recording, warning, error }` (idle grey, recording red `#ff453a`, warning amber `#ffd60a` for FB-05/FB-08, error red for FB-07; `.check` green `#30d158` for FB-04/FB-04b; `.cross` grey for FB-06; `.excluded` = SF Symbol `rectangle.slash` for FB-10).
  - `title: String`, `subtitle: String?` (dimmed, same line: "on this Mac", "42 words", "keep talking").
  - `showsWaveform: Bool`, `timer: String?` (m:ss tabular; `timerIsAmber: Bool` when `elapsed ≥ 870`).
  - `trailing: Trailing?` — `enum Trailing: Equatable { case keycap(String), languageChip(String), button(Button) }`; `enum Button: Equatable { case openSettings, download(sizeText: String), tryAgain, copyRaw }`. Keycaps are the small dark rounded labels ("fn", "⌘V", "fn stop" → `.keycap("fn")` with subtitle "stop"); `.languageChip("EN")` / `"EN?"` / `"AUTO"` is the chip right of the timer with a divider; `.button(.download)` is the only accent-blue control, `.button(.openSettings)` / `.tryAgain` / `.copyRaw` are darker pills (`.tryAgain` renders "Try again" + a tiny "fn" keycap).
  - `static func make(state: FlowBarState, elapsed: TimeInterval, mode: HotkeyMode) -> FlowBarContent`; `static func timerText(_:)` ("0:04", "1:24", "15:00"); `static func sizeText(_:)` ("1.6 GB", "480 MB").
- `WaveformView(levels: [Float])` — 14 bars, 3 pt wide, 2 pt gap, heights 4…20 pt, `.animation(.linear(duration: 0.05))`.
- `FlowBarView(coordinator: DictationCoordinator)` — pill: `Capsule` fill `Palette.hudBackground`, 40 pt tall, horizontal padding 14, content per `FlowBarContent`; buttons call `coordinator.openSettingsForCurrentError()` / `coordinator.copyRaw()` / for `.tryAgain` nothing (fn is the action, the button is a hint per FB-05) / `.download` → `openSettingsForCurrentError()`; width animates `.easeOut(duration: 0.2)`, content `.transition(.opacity)` 120 ms.
- `FlowBarPanel: NSPanel` — `init()` with `styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView]`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`, `isMovableByWindowBackground = false`; `func present(on screen: NSScreen)` positions the panel bottom-center: `x = screen.visibleFrame.midX - width/2`, `y = screen.visibleFrame.minY + 24`; `contentView = NSHostingView(rootView:)`; `func show()` (`orderFrontRegardless()` + scale/fade 160 ms via `NSAnimationContext`), `func hide()` (fade 120 ms then `orderOut`).
- `@MainActor final class FlowBarPresenter` — `init(coordinator: DictationCoordinator, panel: any FlowBarPanelling, now: @escaping () -> Date = Date.init, idleHideDelay: TimeInterval = 6)` with `protocol FlowBarPanelling: AnyObject { var isVisible: Bool { get }; func show(); func hide() }`; `func observe()` uses `withObservationTracking` on `coordinator.state` (re-registering after each change) — or a simpler `Task` polling the coordinator's `AsyncStream`? Use the observation approach: `func stateChanged(to: FlowBarState)` (public for tests) with the rule: non-idle → `show()` if hidden and cancel any pending hide; idle → schedule `hide()` after `idleHideDelay` via a `Task` holding a cancellable sleep (production) — for tests inject `scheduleHide: (TimeInterval, @escaping () -> Void) -> AnyCancellable`-style closure `Scheduler`; the plan's test uses a `FakeScheduler` that stores the block and runs it on demand.

- [ ] **Step 1: Failing tests**

`VoxFlowTests/FlowBarContentTests.swift`:
```swift
import Testing
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlow

@Suite("FlowBarContent")
struct FlowBarContentTests {
    @Test("copy per state matches the canvas")
    func copy() {
        let idle = FlowBarContent.make(state: .idle, elapsed: 0, mode: .pushToTalk)
        #expect(idle.leading == .dot(.idle) && idle.title == "Hold fn to dictate" && idle.trailing == .keycap("fn") && !idle.showsWaveform)
        #expect(FlowBarContent.make(state: .idle, elapsed: 0, mode: .handsFree).title == "Press fn to dictate")

        let listening = FlowBarContent.make(state: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: LanguageDetection(code: "en", confidence: 0.4))), elapsed: 4, mode: .pushToTalk)
        #expect(listening.leading == .dot(.recording) && listening.showsWaveform && listening.timer == "0:04" && listening.trailing == .languageChip("EN?"))
        let handsFree = FlowBarContent.make(state: .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)), elapsed: 84, mode: .pushToTalk)
        #expect(handsFree.trailing == .keycap("fn") && handsFree.subtitle == "stop" && handsFree.timer == "1:24")

        let processing = FlowBarContent.make(state: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: "")), elapsed: 1, mode: .pushToTalk)
        #expect(processing.leading == .spinner && processing.title == "Cleaning up…" && processing.subtitle == "on this Mac")
        let longer = FlowBarContent.make(state: .processing(Processing(startedAt: 0, takingLonger: true, limitReached: false, partialText: "")), elapsed: 9, mode: .pushToTalk)
        #expect(longer.title == "Taking longer…")

        #expect(FlowBarContent.make(state: .inserted(appName: "Mail", words: 42, limitReached: false), elapsed: 0, mode: .pushToTalk)
                == FlowBarContent(leading: .check, title: "Inserted into Mail", subtitle: "42 words", showsWaveform: false,
                                  timer: nil, timerIsAmber: false, trailing: nil))
        #expect(FlowBarContent.make(state: .inserted(appName: nil, words: 3, limitReached: true), elapsed: 0, mode: .pushToTalk).subtitle == "15:00 · limit reached")
        #expect(FlowBarContent.make(state: .inserted(appName: nil, words: 1, limitReached: false), elapsed: 0, mode: .pushToTalk).title == "Inserted")
        let copied = FlowBarContent.make(state: .copied, elapsed: 0, mode: .pushToTalk)
        #expect(copied.leading == .check && copied.title == "Copied — no text field here" && copied.trailing == .keycap("⌘V"))
        let didnt = FlowBarContent.make(state: .didntCatch(rawAvailable: false), elapsed: 0, mode: .pushToTalk)
        #expect(didnt.leading == .dot(.warning) && didnt.title == "Didn't catch that" && didnt.trailing == .button(.tryAgain))
        #expect(FlowBarContent.make(state: .didntCatch(rawAvailable: true), elapsed: 0, mode: .pushToTalk).trailing == .button(.copyRaw))
        #expect(FlowBarContent.make(state: .discarded, elapsed: 0, mode: .pushToTalk) == FlowBarContent(leading: .cross, title: "Discarded", subtitle: nil, showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil))
        let mic = FlowBarContent.make(state: .micUnavailable(.denied), elapsed: 0, mode: .pushToTalk)
        #expect(mic.leading == .dot(.error) && mic.title == "Microphone access needed" && mic.trailing == .button(.openSettings))
        #expect(FlowBarContent.make(state: .micUnavailable(.inUse(by: nil)), elapsed: 0, mode: .pushToTalk).title == "Microphone in use by another app")
        #expect(FlowBarContent.make(state: .micUnavailable(.noDevice), elapsed: 0, mode: .pushToTalk).title == "No microphone")
        let model = FlowBarContent.make(state: .modelNotInstalled(sizeBytes: 1_624_555_275), elapsed: 0, mode: .pushToTalk)
        #expect(model.leading == .dot(.warning) && model.title == "Speech model not installed" && model.trailing == .button(.download(sizeText: "1.6 GB")))
        #expect(FlowBarContent.make(state: .excluded(app: "1Password"), elapsed: 0, mode: .pushToTalk) == FlowBarContent(leading: .excluded, title: "Dictation is off in 1Password", subtitle: nil, showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil))
        let loading = FlowBarContent.make(state: .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk)
        #expect(loading.leading == .spinner && loading.title == "Loading model…" && loading.subtitle == "keep talking")
        let err = FlowBarContent.make(state: .error("Couldn't load the speech model"), elapsed: 0, mode: .pushToTalk)
        #expect(err.leading == .dot(.error) && err.title == "Couldn't load the speech model" && err.trailing == .button(.openSettings))
        #expect(FlowBarContent.make(state: .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk).showsWaveform)
    }

    @Test("timer and size formatting")
    func formats() {
        #expect(FlowBarContent.timerText(4) == "0:04")
        #expect(FlowBarContent.timerText(84) == "1:24")
        #expect(FlowBarContent.timerText(900) == "15:00")
        #expect(FlowBarContent.sizeText(1_624_555_275) == "1.6 GB")
        #expect(FlowBarContent.sizeText(487_601_967) == "480 MB")
    }
}
```
`.armed`/`.tapped` render like listening without the timer (the capture is already running).

`VoxFlowTests/FlowBarPresenterTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowDictation
@testable import VoxFlow

@Suite("FlowBarPresenter")
@MainActor
struct FlowBarPresenterTests {
    final class FakePanel: FlowBarPanelling {
        var isVisible = false; var shows = 0; var hides = 0
        func show() { isVisible = true; shows += 1 }
        func hide() { isVisible = false; hides += 1 }
    }
    final class FakeScheduler: HideScheduling {
        var pending: (() -> Void)?; var cancelled = 0
        func schedule(after: TimeInterval, _ block: @escaping () -> Void) { pending = block }
        func cancel() { pending = nil; cancelled += 1 }
        func fire() { pending?(); pending = nil }
    }

    @Test("shows on first non-idle state, hides 6 s after idle, cancels the hide when activity resumes")
    func lifecycle() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6)
        presenter.stateChanged(to: .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        #expect(panel.shows == 1 && panel.isVisible)
        presenter.stateChanged(to: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        #expect(panel.shows == 1)
        presenter.stateChanged(to: .idle)
        #expect(panel.isVisible && scheduler.pending != nil)
        presenter.stateChanged(to: .armed(Pending(downAt: 7, fnIsDown: true, resolvedMode: nil)))
        #expect(scheduler.cancelled == 1 && scheduler.pending == nil && panel.shows == 1)
        presenter.stateChanged(to: .idle)
        scheduler.fire()
        #expect(!panel.isVisible && panel.hides == 1)
    }
}
```
`FlowBarPresenter` takes the coordinator separately for production (`bind(to:)` uses `withObservationTracking`); the tests drive `stateChanged(to:)` directly.

- [ ] **Step 2: Run** — compile failure.

- [ ] **Step 3: Implementation** — `FlowBarContent.make` is a `switch` over `FlowBarState` producing the copy in the test (the test is the spec). `timerText`: `String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)`. `sizeText`: ≥ 1e9 → one decimal "GB" (`1.6 GB`), else `MB` rounded to ten (`480 MB`) — mirror `ModelsViewModel.gigabytes` if it already formats the same; reuse it if so. `HideScheduling` production implementation `TaskHideScheduler` uses a cancellable `Task` with `Task.sleep` (UI timing; not used in tests). `FlowBarPresenter.bind(to coordinator:)`:
```swift
func bind(to coordinator: DictationCoordinator) {
    func track() {
        withObservationTracking { _ = coordinator.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stateChanged(to: coordinator.state)
                track()
            }
        }
    }
    stateChanged(to: coordinator.state)
    track()
}
```
`FlowBarPanel` conforms to `FlowBarPanelling`; `present(on:)` is called by `show()` using `NSScreen.main ?? NSScreen.screens.first`. `FlowBarView` uses `@Environment(DictationCoordinator.self)`? Simpler: `FlowBarView(coordinator:)` stored property; the hosting view is created once in `AppServices` with the coordinator.

- [ ] **Step 4: Design-fidelity renders.** Add `VoxFlowTests/FlowBarRenderTests.swift`: `@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))`, `@MainActor`, one test that builds `FlowBarView` for every `FlowBarState` in the copy test (idle PTT, idle hands-free, listening EN?, listening hands-free 1:24, processing, taking longer, inserted Mail 42, copied, didn't catch, didn't catch raw, discarded, mic denied, mic in use, no device, model missing, excluded, loading, error, armed) with a fixed 14-level waveform, renders each with `ImageRenderer(content:)` at `scale = 2` on a 420×80 canvas with the desktop-grey background from the canvas (`#d9dbe0`), and writes `.superpowers/design/renders/FlowBar-<n>-<state>.png` (create the directory). Run it: `VOXFLOW_RENDER=1 xcodebuild -scheme VoxFlow -destination 'platform=macOS' test -only-testing:VoxFlowTests/FlowBarRenderTests`. Then compare each PNG side by side with `.superpowers/design/canvas.pdf` pages 8–9 and 11 (use the Read tool on the PNGs and the PDF pages): pill height 40 pt, dark material, leading indicator, text weight/size (13 pt semibold title, 13 pt regular dimmed subtitle), keycap/chip/button styling, spacing. Fix the view until they match; list residual differences in the report. The reviewer repeats the comparison.
- [ ] **Step 5: Run** app tests — PASS; launch the app (`open build/…/VoxFlow.app` or via Xcode) and confirm the panel appears when fn is pressed (Task 5 does the full e2e).
- [ ] **Step 6: Commit** `git commit -m "feat(app): Flow Bar panel, view and presenter"`

---

### Task 5: Wiring, menu bar status, manual e2e, PR

**Files:**
- Modify: `VoxFlow/App/AppServices.swift` — add `dictationSettings`, `modelLoader`, `dictationStore: DictationStore?` (`try? DictationStore(databaseURL: DictationStore.defaultURL, keyProvider: settings.encryptHistory ? HistoryKeyProviders.default() : nil)`; on `StorageError.keyLost` log and fall back to `nil` store this launch), `retention: RetentionRunner?` (started in `live()`), `inserter: AccessibilityTextInserter`, `dictationController: DictationController`, `dictation: DictationCoordinator`, `flowBar: FlowBarPresenter`, `fnMonitor: FnKeyMonitor`; `live()` wires: `MeteredMicrophone(base: MicrophoneSource()) { rms in Task { @MainActor in coordinator.reportLevel(rms) } }`, `WindowedTranscriber(engine: engine)`, `SystemMonotonicClock()`, preflight closure building `PreflightBuilder` with `settings.box.current` and `inserter.captureFocus`, `loadModel: { try await modelLoader.ensureLoaded() }`, `options: { settingsBox.current.options }`, `onSave: { r, app in await historyWriter.save(r, appName: app) }`, `copyToClipboard: { SystemPasteboard().setString($0) }`; `LazyModelFileTranscriber` gets the shared `modelLoader`.
- Modify: `VoxFlow/App/AppDelegate.swift` — `applicationDidFinishLaunching`: `AppServices.shared.dictation.start()`, `flowBar.bind(to:)`, `fnMonitor.start()`.
- Modify: `VoxFlow/App/MenuBarContent.swift` — status line follows `dictation.state`: idle → "Ready · on-device"; listening → "Listening…"; processing → "Cleaning up…"; add a "Hotkey: Hold fn / Double-tap fn" static line from `hotkeyMode`.
- Modify: `README.md` (What works today: dictation via fn, permissions needed), `CHANGELOG.md` (Unreleased: Flow Bar, fn hotkey, Accessibility insertion, history saving).
- Test: `VoxFlowTests/AppServicesWiringTests.swift` — constructs `AppServices.live()`? No (touches the real mic/keychain). Instead a test for the menu bar status mapping `MenuBarStatus.text(for:)` (pure) — add `VoxFlow/App/MenuBarStatus.swift`.

- [ ] **Step 1: Test** `MenuBarStatusTests`: `.idle` → "Ready · on-device", `.listening` → "Listening…", `.processing` → "Cleaning up…", `.inserted` → "Ready · on-device".
- [ ] **Step 2: Wire** as listed; `xcodegen generate && xcodebuild … build test` green; `cd VoxFlowKit && swift test` green; `python3 -m unittest discover -s scripts/tests` green.
- [ ] **Step 3: Manual e2e (owner's Mac; record the outcome verbatim in the PR):**
  0. **The VoxFlow window is frontmost at launch** (M-15): click into TextEdit (or another text field) *before* the first fn press — a fn press while VoxFlow itself is focused captures its own, non-editable focus and the dictation lands on the clipboard instead of in a text field.
  1. Build and launch `VoxFlow.app` from DerivedData (`xcodebuild -scheme VoxFlow -destination 'platform=macOS' build` then `open` the product).
  2. Open TextEdit, click into a document, hold fn ≥ 1 s, say "testing one two three", release. Expected: HUD shows Listening with waveform and timer, then "Cleaning up… on this Mac", then "✓ Inserted into TextEdit · 4 words"; the words appear in TextEdit; the HUD hides ~1.5 s later.
  3. First run: the microphone prompt appears on the first fn-down; Accessibility prompt appears once; after granting both (System Settings), repeat step 2.
  4. Click the desktop (no text field), hold fn, speak, release → "✓ Copied — no text field here · ⌘V"; ⌘V in TextEdit pastes the text.
  5. Hold fn, press esc → "✕ Discarded".
  6. Double-tap fn, speak, stay silent 3 s → processing → inserted.
  7. `sqlite3 ~/Library/Application\ Support/VoxFlow/voxflow.sqlite 'select count(*), encrypted from dictations'` → rows exist and `encrypted = 1`.
  If step 2 shows the HUD but no fn events arrive at all with Accessibility granted, ruling 1 is wrong: note it in the PR and file the Input Monitoring follow-up; do not add CGEventTap in this PR.
- [ ] **Step 4: Commit** `git commit -m "feat(app): wire dictation into AppServices, menu bar status"` and docs `docs: dictation in README/CHANGELOG`.
- [ ] **Step 5: PR into `develop`** with the template: Summary, Testing (commands + counts + the manual e2e transcript), checklist; footer `Part of #110.` On #110 tick "Holding fn in a real text field inserts recognized text…" only if the manual e2e passed on the owner's Mac; otherwise leave it unticked and say why.

---

## Self-review

- **Spec coverage:** §7 happy path 2 (Tasks 2–5); FB-01…FB-12 copy (Task 4, test is the spec); 3d Flow Bar geometry/animations (Task 4 panel/view); 3e secure input / focus change / permission revoked (Tasks 1–2: preflight, capture-at-start, lazy prompts → FB-07); history save (Task 3). Out: onboarding ONB-*, History page MW-02, Settings tabs, FB-11 popover, ⌥L, MB-00 hint, notifications — 3c/phase 4.
- **Type consistency:** `DictationSettingsSnapshot`/`DictationSettingsBox` used identically in Tasks 1, 3, 5; `PreflightBuilder(readiness:)` closure form in test and `AppServices`; `FakePermissions` fields (`requests`, `openedMicrophoneSettings`) used in Tasks 1 and 3; `FlowBarPanelling`/`HideScheduling` in Task 4; `FnTransition` in Tasks 2–3; `FakeDictationTranscriber` public in TestSupport after Task 1's move (Task 3's test imports it).
- **Placeholders:** `{ … }` marks member-wise initializers only.
