# VoxFlow v2 Phase 3c — Onboarding, History page, dictation Settings, live settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish phase 3 (#110): first-launch onboarding ONB-01…05 with the permission-denied branch and the model download step; the History page MW-02 (list, search, detail, delete with undo, empty states) reading the encrypted store; the Settings tabs the dictation loop reads — Hotkeys (ST-02), Audio (ST-04, silence stop + device), Privacy (ST-05 incl. excluded apps and Delete all); and the plumbing that makes those settings take effect without a relaunch.

**Architecture:** `HistoryService` (`@Observable @MainActor`) owns the `DictationStore` for the app's lifetime — it reopens the store when the encryption toggle flips, restarts `RetentionRunner` when the retention changes, and exposes async read/delete operations that run the blocking SQLite/AES work off the main actor. `DictationController` gains `updateConfig(_:)` so the silence-stop setting reaches the machine. `OnboardingViewModel`, `HistoryViewModel`, `HotkeysViewModel`, `AudioViewModel`, `PrivacyViewModel` are `@Observable @MainActor` classes with every decision testable; views are thin and match the rendered canvas.

**Tech Stack:** SwiftUI (macOS 15 grouped forms), AppKit bridges (`NSOpenPanel` for excluded apps, `NSAlert`-style destructive confirmations as SwiftUI alerts), Swift Testing, XcodeGen.

**Spec:** design spec §1, §5; canvas: onboarding 1d + 2g (rendered PDF pages 10–12: ONB-01 "Speak. It types.", ONB-02/02a permissions, ONB-05 "You're set. Try it."), text report for ONB-03/ONB-04/ONB-04a/SYS-DISK; History 2e (page 9: MW-02 row + MW-02d detail + MW-02s), 2d empty states (page 9: MW-02e "No dictations yet"), page 4 (MW-02n no results, T-01 undo toast); Settings ST-02/ST-04/ST-04n/ST-05/ST-05d (text report + page 6 ST-04n + page 9 ST-05d). Issue #110 (last part).

**Rulings taken in this plan (record in the ledger, do not re-decide):**
1. **Live settings:** `DictationController.updateConfig(_:)` applies the new `FlowBarConfig` immediately when the machine is `.idle`, otherwise on the next return to idle. `encryptHistory` toggles reopen the store (`HistoryService.reopen()`); rows keep the mode they were written in (ADR-004); `retentionDays` restarts the runner. Phase 3b's `AppServices` wiring changes accordingly.
2. **Onboarding is shown on first launch instead of the main window** (`onboarding.completed` false): `AppDelegate` opens the onboarding window and does not open the main window until "Start using VoxFlow"; quitting mid-way resumes at the saved step (3e "Onboarding abandoned"); a completed permission is never asked twice.
3. **MB-00 menu-bar hint** (after ONB-05) is phase 4 (menu bar polish) — the onboarding ends by opening the main window on Home.
4. **ONB-05 "Try it"** uses a scratchpad `TextEditor` inside the onboarding window; the result chip "✓ Inserted · N words · X s" comes from observing `DictationCoordinator.state` (`.inserted(words:)`) and the elapsed processing time; the scratchpad is not saved to History (the view model sets a `suppressHistory` flag on `HistoryWriter` for that dictation).
5. **History search** is the store's in-memory search; filters "All apps" / date chips are phase 4 (needs the Home stats work); the search field and the two empty states ship now.
6. **Re-style** in History rows/detail is present but disabled with the design's label (phase 5); "Edit" in the detail is phase 4.
7. **Hotkeys tab** shows the mode picker and the three fixed rows (fn hold / fn fn / esc); recording a custom shortcut (ST-02r/ST-02c) is phase 4. "Re-insert last dictation ⌥⌘V" is phase 4.
8. **Audio tab**: input device name (read-only, from `AVCaptureDevice.default(for: .audio)`), live input level from `DictationCoordinator.levels` only while listening (a "Test microphone" button that opens the mic for 3 s is phase 4), silence stop 1…10 s, ST-04n banner when no device.
9. **Privacy tab**: intro copy + the two stats lines (static "0" / "none" — the network counter is phase 6's MCP work), Keep history, Delete after, Encrypt at rest, Never record in (add via `NSOpenPanel` limited to `.app`, remove), Delete all history… → ST-05d confirmation.
10. **Unreadable rows** (encrypted while the toggle is off) render as "Encrypted — turn on 'Encrypt history at rest' to read" with the row's meta line intact.

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated` in the app target.
- Views hold no business rules; every decision in a view model with a Swift Testing test in `VoxFlowTests`; no sleeps in tests (`FakeClock` drives waits).
- Copy verbatim from the canvas (quoted in the tasks). Design reference is the rendered canvas `.superpowers/design/canvas.pdf` (run `scripts/render_design.sh` if missing); each UI task's implementer and reviewer compare the built screen with the pages named in that task. Screens are screenshot-able through the opt-in render tests (`VOXFLOW_RENDER=1`) added per task.
- Blocking storage work never runs on the main actor.
- Commits: Conventional Commits, owner-authored, no attribution trailers. Branch `feature/110-phase3c-onboarding-history` from `develop`; PR into `develop`.
- Verification per task: `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`; package `swift test` where touched.

---

### Task 1: Live settings — `DictationController.updateConfig`, `HistoryService`, wiring

**Files:**
- Modify: `VoxFlowKit/Sources/VoxFlowDictation/DictationController.swift` (+ `FlowBarMachine.swift`: `config` stays `public var`), `VoxFlowKit/Tests/VoxFlowDictationTests/DictationControllerTests.swift`
- Create: `VoxFlow/Dictation/HistoryService.swift`
- Modify: `VoxFlow/Dictation/HistoryWriter.swift` (store comes from the service), `VoxFlow/Dictation/DictationSettings.swift` (change hooks), `VoxFlow/App/AppServices.swift`
- Test: `VoxFlowTests/HistoryServiceTests.swift`, `VoxFlowTests/HistoryWriterTests.swift` (adjust), `VoxFlowTests/DictationSettingsTests.swift` (hooks)

**Interfaces:**
- `DictationController.updateConfig(_ config: FlowBarConfig)` (actor method): if `machine.state == .idle` → `machine.config = config`; else store `pendingConfig` and apply inside `apply`/`handle` when the state becomes `.idle`. Test: change silence stop mid-listening → the running silence timer keeps the old value; after the dictation ends the next hands-free run uses the new one (assert via the `.startTimer(.silence, seconds:)` effect order? the controller test observes states — simpler: `await controller.config.silenceStop` accessor added for tests).
- `HistoryService` (`@Observable @MainActor`): `init(url: URL, settings: DictationSettings, keyProvider: @escaping @Sendable () -> any HistoryKeyProviding, clock: any MonotonicClock)`; `private(set) var store: DictationStore?`, `private(set) var status: Status` (`.ready`, `.disabled(reason: String)` — keyLost / open failure); `var storeBox: HistoryStoreBox` (Sendable `Mutex<DictationStore?>` for `HistoryWriter`); `func reopen()` (rebuilds the store with/without the key provider per `settings.encryptHistory`, restarts retention); `func fetch(limit: Int) async -> [DictationRecord]`, `func search(_ q: String) async -> [DictationRecord]`, `func delete(id: Int64) async`, `func deleteAll() async`, `func count() async -> Int`, `func reinsert(_ record: DictationRecord) async -> DictationRecord?` (for undo: re-insert with the original `createdAt`); all run on `Task.detached(priority: .userInitiated)`.
- `DictationSettings`: `var onConfigChange: ((FlowBarConfig) -> Void)?`, `var onHistorySettingsChange: (() -> Void)?` invoked from the relevant `didSet`s (`silenceStop` → config; `encryptHistory`, `retentionDays` → history).
- `AppServices`: `historyService` replaces `dictationStore`/`retention`; `dictationSettings.onConfigChange = { config in Task { await controller.updateConfig(config) } }`; `onHistorySettingsChange = { historyService.reopen() }`; `HistoryWriter(storeBox: historyService.storeBox, settings:, now:)`.

- [ ] **Step 1: Failing tests** — package: `DictationControllerTests.updateConfigAppliesWhenIdle` (start with silence 3; `updateConfig(FlowBarConfig(silenceStop: 5))` while listening hands-free; `await controller.config.silenceStop == 3` still; finish; then `== 5`). App: `HistoryServiceTests` — in a temp dir: `insert` via the store, `fetch` returns it; `settings.encryptHistory = false` → `reopen()` → `fetch` returns the row flagged `isUnreadable`; `deleteAll` → `count == 0`; `reinsert` restores a deleted record with the same `createdAt`; `keyLost` path: prepopulate encrypted rows, provide a key provider with `isNewlyCreated: true` → `status == .disabled("history key lost")` and `store == nil`. `DictationSettingsTests`: hooks fire with the new config / on encrypt toggle.
- [ ] **Step 2: Run** — compile failure.
- [ ] **Step 3: Implementation** per the interfaces; `HistoryService.reopen()` cancels the old `RetentionRunner` (`await stop()`), then opens; open failures set `status`.
- [ ] **Step 4: Run** all — PASS.
- [ ] **Step 5: Commit** `feat(app): live dictation settings — controller updateConfig, HistoryService`

---

### Task 2: Onboarding (ONB-01…05, ONB-02a)

**Files:**
- Create: `VoxFlow/Onboarding/OnboardingState.swift`, `OnboardingViewModel.swift`, `OnboardingWindow.swift`, `OnboardingSteps.swift` (one `View` per step), `OnboardingModelStep.swift`
- Modify: `VoxFlow/App/VoxFlowApp.swift` (scene `Window("Welcome to VoxFlow", id: OnboardingWindowID.onboarding)` 700×520, `.windowResizability(.contentSize)`), `VoxFlow/App/AppDelegate.swift` (first launch → onboarding), `VoxFlow/MainWindow/Navigation.swift` (`requestOnboarding`), `VoxFlow/Dictation/HistoryWriter.swift` (`suppressNext` flag via a `Mutex<Bool>`)
- Test: `VoxFlowTests/OnboardingViewModelTests.swift`, `VoxFlowTests/OnboardingRenderTests.swift` (opt-in)

**Design (rendered PDF pages 10–12, 2g on page 10):** window 700×520, light background, traffic lights; centred content; page dots at the bottom-centre (4 dots for ONB-01…04; ONB-05 shows the 4th filled); primary button bottom-right (blue, "Get started" / "Continue" / "Start using VoxFlow"), "Back" bottom-left from step 2.
- ONB-01: app icon (blue rounded square with the waveform glyph — draw it as a `RoundedRectangle` + three bars until the asset lands via #141), title "Speak. It types." (34 pt bold), body "VoxFlow turns your voice into clean text in any app — entirely on this Mac. Nothing you say ever leaves it.", three green-dot chips "On-device models" "Works offline" "No account".
- ONB-02: title "Two permissions, both local", subtitle "macOS asks for these; VoxFlow uses them only on this Mac." Two rows in a card: Microphone — "To hear you. Audio never leaves memory." — status "Granted" (green) or button "Allow…"; Accessibility — "To type into whichever app you're using." — "Open System Settings…" + hint "System Settings → Privacy & Security → Accessibility → enable VoxFlow." Both granted → Continue enabled → ONB-03.
- ONB-02a (Accessibility denied after the user came back): amber row "Accessibility — not granted" / "Without it VoxFlow can't type for you. It will copy text to the clipboard instead." with "Try again"; disclosure "Why this permission? Accessibility is how macOS lets an app insert text into another app's field. VoxFlow reads nothing from your screen — only writes what you dictated."; buttons "Back" / "Continue with clipboard".
- ONB-03: "How do you want to start?" / "Both use the fn key. You can change this anytime." Two selectable cards: Push-to-talk (keycap "fn") "Hold fn while you speak. Release and the text is inserted. Precise, nothing runs on its own."; Hands-free (keycaps "fn" "fn") "Double-tap fn to start, tap once to stop. Best for longer thoughts. Stops after 3 s of silence." Continue → ONB-04.
- ONB-04: "Download your speech model" / "This is the only download VoxFlow ever makes." Row: "Whisper large-v3-turbo" + badge "RECOMMENDED" / "1.6 GB · 99 languages · tuned for Apple Silicon" / button Download → progress "612 MB of 1.6 GB" + "about 2 min left" + Pause; hint "Have an 8 GB Mac? Use the 480 MB model instead." (link switches the row to Whisper small); footer "You can start dictating as soon as it finishes — no sign-in, no internet needed after this." Uses `ModelsViewModel` (rows, download/pause/resume, alerts SYS-DISK/offline ONB-04a). Complete (state `.installed`) → auto-advance to ONB-05.
- ONB-05: green check disc, "You're set. Try it." / "Hold fn, say a sentence, let go." Scratchpad `TextEditor` (placeholder empty, 3 lines tall, blue focus ring), result chip "✓ Inserted · 11 words · 0.6 s" appears after the first `.inserted`, footer "That never left this Mac. Neither will anything else.", button "Start using VoxFlow".

**Interfaces:**
- `enum OnboardingStep: Int, CaseIterable { welcome, permissions, hotkey, model, tryIt }`.
- `OnboardingState(store:)`: `step` ("onboarding.step"), `completed` ("onboarding.completed"), `accessibilitySkipped` ("onboarding.clipboardFallback").
- `OnboardingViewModel(state:permissions:settings:models: ModelsViewModel, dictation: DictationCoordinator, historyWriter: HistoryWriter, clock: any MonotonicClock)`: `step`, `microphone: PermissionState`, `accessibilityGranted: Bool`, `showsAccessibilityDenied: Bool`, `canContinue: Bool`, `hotkeyMode`, `selectedModelID`, `modelRow: ModelsViewModel.Row?`, `tryItResult: String?`; actions `next()`, `back()`, `requestMicrophone() async`, `openAccessibilitySettings()` (starts a 1 s polling task using `clock.sleep` until trusted or the step changes), `tryAgainAccessibility()`, `continueWithClipboard()`, `choose(_ mode:)`, `useSmallerModel()`, `download()`, `pause()`, `finish()` (sets completed, `navigation.requestMainWindow = true`, closes onboarding via a `dismiss` closure). Observes `dictation.state` for `.inserted(words:)` while on `.tryIt` → `tryItResult = "✓ Inserted · \(words) words · \(String(format: "%.1f", elapsed)) s"` and calls `historyWriter.suppressNext()` when the try-it dictation starts (state `.armed`).
- `AppDelegate.applicationDidFinishLaunching`: if `!onboardingState.completed` → `navigation.requestOnboarding = true` and close the main window if SwiftUI opened it (`NSApp.windows.first { $0.identifier?.rawValue == MainWindowID.main }?.close()`); `VoxFlowApp` observes `requestOnboarding` → `openWindow(id: OnboardingWindowID.onboarding)`.

- [ ] **Step 1: Failing tests** — `OnboardingViewModelTests` (FakePermissions, InMemoryKeyValueStore, FakeClock, a `ModelsViewModel` over a temp `ModelStore` with `FakeModelDownloader`, a `DictationCoordinator` built like `DictationCoordinatorTests`): fresh state starts at `.welcome`; `next()` order; permissions step: `canContinue` only when mic granted and (accessibility granted or skipped); `openAccessibilitySettings()` polls — advance the fake clock 1 s after `FakePermissions.accessibility = true` → `accessibilityGranted`; `tryAgainAccessibility` when still false → `showsAccessibilityDenied`; `continueWithClipboard` → `.hotkey` and `accessibilitySkipped` persisted; `choose(.handsFree)` → `settings.hotkeyMode == .handsFree`; model step: `download()` drives the fake downloader → row `.installed` → step `.tryIt`; `useSmallerModel()` selects the small model; resume at persisted step on init; `finish()` sets completed and requests the main window.
- [ ] **Step 2: Run** — compile failure.
- [ ] **Step 3: Implementation** — view model + views per the design section; `OnboardingRenderTests` renders each step at 700×520 (opt-in) to `.superpowers/design/renders/Onboarding-<step>.png`; compare with PDF pages 10–12 and iterate (title sizes, chips, cards, dots, buttons).
- [ ] **Step 4: Run** — PASS; render + compare; report residuals.
- [ ] **Step 5: Commit** `feat(app): onboarding ONB-01…05 with permission branches and model download`

---

### Task 3: History page (MW-02, MW-02d, MW-02e, MW-02n, T-01)

**Files:**
- Create: `VoxFlow/History/HistoryViewModel.swift`, `HistoryPage.swift`, `HistoryRowView.swift`, `HistoryDetailView.swift`, `HistoryEmptyView.swift`, `UndoToastView.swift`
- Modify: `VoxFlow/MainWindow/MainWindow.swift` (route `.history`), `VoxFlow/App/AppServices.swift` (`historyViewModel`)
- Test: `VoxFlowTests/HistoryViewModelTests.swift`, `VoxFlowTests/HistoryRenderTests.swift` (opt-in)

**Design (PDF page 9 "2e", page 9 "2d" MW-02e, page 4 MW-02n + T-01):** search field "Search your dictations" at the top (chips "All apps ⇅" and "This week ⇅" rendered disabled — phase 4); rows: leading app initial in a coloured rounded square (S purple, M blue, N orange, X blue — derive colour from the app name hash; initial = first letter), first line = text (single line, truncated), meta line "Slack · 9:26 AM · 0:09 · 15 words · EN" (app · time · m:ss · words · language; style label after words when present); trailing actions on hover/selection: "Copy", "Re-style ▾" (disabled, phase 5), "Delete". Clicking a row expands MW-02d inline: two columns "WHAT YOU SAID" (raw text, dimmed) and "INSERTED" (text), footnote "Audio was not saved." Empty state MW-02e: clock icon, "No dictations yet", "Hold fn in any text field and start talking. Everything you dictate shows up here, on this Mac only.", button "Try it in a scratchpad" (opens onboarding's try-it step? → phase 4; here it focuses a scratchpad sheet — ruling: opens a small sheet with a `TextEditor` titled "Scratchpad", same suppress-history behaviour as ONB-05). History off: same view with title "History is off" and body "Turn on 'Keep dictation history' in Settings → Privacy." + button "Open Privacy settings". No results MW-02n: "No dictations match "{query}"" / "Search covers inserted text and the raw transcript. Try fewer words, or widen the date filter." buttons "Clear search" / "Search all time" (the second is a no-op until phase 4 filters; render it disabled). Delete → row collapses immediately, toast T-01 "Dictation deleted" + "Undo ⌘Z" for 6 s, then permanent. Footer line under the list: "History is encrypted on this Mac and kept for 30 days. Change in Settings → Privacy." (days from settings; "encrypted" only when the toggle is on).

**Interfaces:**
- `HistoryViewModel(service: HistoryService, settings: DictationSettings, navigation: Navigation, clock: any MonotonicClock)`: `records: [DictationRecord]`, `query: String` (didSet → debounced 150 ms search via clock), `expandedID: Int64?`, `pendingDeletion: (record: DictationRecord, index: Int)?`, `toastVisible`, `emptyState: EmptyState?` (`.noDictations`, `.historyOff`, `.noResults(query)`), `footerText`; actions `load() async`, `toggleExpanded(id:)`, `copy(record)` (pasteboard), `delete(record)` (removes locally, deletes in the store, arms the 6 s undo timer via `clock.sleep`), `undo()` (reinsert via service, restores position), `clearSearch()`, `openPrivacySettings()`; `static func metaLine(for:)`, `static func initial(for appName:)`, `static func color(for appName:)`.

- [ ] **Step 1: Failing tests** — with an in-memory `HistoryService` (Task 1) + `FakeClock`: `load` lists newest first; `metaLine` formatting ("Slack · 9:26 AM · 0:09 · 15 words · Very casual · EN" with a fixed `Date` and locale-independent time via a `DateFormatter` set to `en_US_POSIX` + `h:mm a`); search debounce (`query = "num"`, advance 0.15 s → results); `delete` → record gone locally, toast visible, `undo` within 6 s restores at the same index; advance 6 s → permanent (`count` in service == n-1); `emptyState` rules (no rows → `.noDictations`; `keepHistory == false` → `.historyOff`; query with 0 hits → `.noResults`); unreadable rows render text "Encrypted — turn on 'Encrypt history at rest' to read"; footer text with 30 days + encryption on/off.
- [ ] **Step 2: Run** — compile failure.
- [ ] **Step 3: Implementation**; render test for the list with 4 seeded rows + the expanded detail + the three empty states → `.superpowers/design/renders/History-*.png`; compare with pages 9 and 4; iterate.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(app): History page with search, detail, delete with undo, empty states`

---

### Task 4: Settings › Hotkeys, Audio, Privacy

**Files:**
- Create: `VoxFlow/Settings/HotkeysSettingsView.swift`, `AudioSettingsView.swift`, `AudioViewModel.swift`, `PrivacySettingsView.swift`, `PrivacyViewModel.swift`, `VoxFlow/Dictation/InputDevice.swift` (`InputDeviceProviding` + `AVCaptureDevice` impl)
- Modify: `VoxFlow/Settings/SettingsPage.swift` (route the three tabs), `VoxFlow/App/AppServices.swift`
- Test: `VoxFlowTests/AudioViewModelTests.swift`, `VoxFlowTests/PrivacyViewModelTests.swift`, `VoxFlowTests/SettingsRenderTests.swift` (opt-in)

**Design (text report + PDF page 6 ST-04n, page 9 ST-05d; macOS 15 grouped forms):**
- Hotkeys (ST-02): rows "Push-to-talk — Hold to dictate, release to insert — [fn] hold", "Hands-free — Press to start, press again to stop — [fn][fn] double-tap", "Cancel — Discard the current dictation — [esc]", "Re-insert last dictation — Useful when the wrong field had focus — [⌥⌘V]" (disabled, phase 4); a "Default mode" picker (Push-to-talk / Hands-free) bound to `DictationSettings.hotkeyMode`; footer "Click any shortcut to record a new one. Default mode is currently {mode} — change it in Tweaks or here." (recording is phase 4: rows are not clickable yet).
- Audio (ST-04): "Input device" (name or "None available"), "Input level" meter (14-bar `WaveformView` reuse, live while listening, flat otherwise), "Noise suppression — Filters keyboard and fan noise before recognition" toggle (persisted, no effect until phase 4 — label it "coming soon"? No: ruling — omit the two toggles not wired yet (Noise suppression, Duck other audio) to avoid dead controls; add them in phase 4), "Stop after silence — Hands-free mode only" picker 1…10 s bound to `silenceStop`, ST-04n banner "No microphone found / Connect a microphone or headset. VoxFlow picks it up automatically." + "Open Sound Settings" when no device.
- Privacy (ST-05): header "Everything stays on your Mac" / "VoxFlow has no account, no analytics and no cloud. Audio is processed in memory and discarded. The only outgoing connection it can make is a model download you start yourself."; stats "Network requests since install: 0" / "Audio stored: none"; toggles "Keep dictation history — Text only — audio is never saved", "Delete history after" picker (7 days / 30 days / 90 days / 1 year / Never), "Encrypt history at rest — Key stored in the Secure Enclave" (subtitle "Key stored in the Keychain" when `HistoryKeyProviders.select` says keychain); "Never record in" list of app names with bundle ids (resolve names via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` + `Bundle.displayName`), "+ Add" (NSOpenPanel `/Applications`, `.application` type) and remove buttons; "Delete all history…" → ST-05d alert "Delete all dictation history?" / "{n} items will be removed from this Mac. There is no cloud copy, so this can't be undone." Delete (destructive) / Cancel.

**Interfaces:**
- `AudioViewModel(devices: any InputDeviceProviding, settings:, dictation: DictationCoordinator)`: `deviceName: String?`, `hasDevice`, `silenceStop` (binding to settings), `levels`, `openSoundSettings()`.
- `PrivacyViewModel(settings:, history: HistoryService, apps: any InstalledAppsProviding, permissionsOpener…)`: `excludedApps: [(bundleID, name)]`, `addApp() async` (panel → bundle id), `remove(bundleID)`, `requestDeleteAll() async` (counts), `confirmDeleteAll() async`, `alert: Alert?`, `encryptionSubtitle`.

- [ ] **Step 1: Failing tests** — `AudioViewModelTests` (fake device provider: name / none → `hasDevice`; silence binding clamps); `PrivacyViewModelTests` (add/remove excluded apps persist through settings; `requestDeleteAll` alert text with the count; `confirmDeleteAll` empties the service; subtitle from the key-provider choice).
- [ ] **Step 2–4:** implement, render each tab (`Settings-hotkeys/audio/privacy.png`), compare with the canvas (the Settings tabs are interactive in the canvas HTML and not on the PDF pages — use the text report's copy and the grouped-form look of ST-03 on the PDF as the visual baseline), tests green.
- [ ] **Step 5: Commit** `feat(app): Settings › Hotkeys, Audio, Privacy`

---

### Task 5: Wiring, docs, manual checklist, PR

- Modify: `VoxFlow/App/AppServices.swift` (view models), `VoxFlow/MainWindow/MainWindow.swift`, `README.md`, `CHANGELOG.md`, `SETUP.md` (first-launch onboarding; how to reset: `defaults delete dev.artemsem.voxflow` keys `voxflow.onboarding.*`).
- Manual checklist (owner): reset onboarding keys → launch → walk ONB-01…05 (grant Microphone via the button, Accessibility via System Settings, choose a mode, download or skip if installed, try-it inserts into the scratchpad) → main window opens on Home → History shows the try-it? No: suppressed — dictate once in TextEdit → History row appears → expand → Copy → Delete → Undo → Settings › Privacy toggle encryption off → rows show "Encrypted — …" → toggle on → readable again; Audio: change silence stop to 5 s, hands-free dictation stops after 5 s of silence.
- Verification: full `xcodebuild … build test`, `swift test`, scripts; PR into `develop` with the template; on #110 tick the criteria the manual run confirmed; comment.

#### Manual checklist (owner runs this on a real Mac)

1. Quit VoxFlow. Reset onboarding: `defaults delete dev.artemsem.voxflow voxflow.onboarding.completed`,
   `voxflow.onboarding.step`, `voxflow.onboarding.clipboardFallback` (see SETUP.md).
2. Launch VoxFlow. The onboarding window opens, not the main window.
3. ONB-01: welcome screen shows.
4. ONB-02: permissions screen — click the Microphone button, grant it in the macOS prompt; click
   the Accessibility button, grant it in System Settings and return to VoxFlow.
   - ONB-02a: if Accessibility is denied instead, confirm the clipboard-fallback branch renders and
     can be chosen to proceed.
5. ONB-03: hotkey screen — choose a mode (push-to-talk or hands-free).
6. ONB-04: model screen — if no model is installed, start a download and watch it complete; if one
   is already installed, confirm the screen shows "Installed" instead of a download control.
   - ONB-04a/SYS-DISK: if disk space is low, confirm the low-space alert appears instead of a stuck
     download.
7. ONB-05: try-it screen — dictate once; confirm the recognized text is inserted into the
   onboarding scratchpad (not into any other app, and not saved to History).
8. Finish onboarding. The main window opens on Home.
9. Click into a TextEdit document, dictate once for real (fn press/hold or hands-free per the mode
   chosen in step 5). Confirm the text is inserted into TextEdit.
10. Open History. Confirm a new row appears for the TextEdit dictation (and only one — the
    onboarding try-it in step 7 must not have created a row).
11. Expand the row: confirm the full transcript renders.
12. Click Copy: confirm the transcript is on the clipboard.
13. Click Delete: confirm the row disappears and an Undo affordance appears; click Undo: confirm
    the row comes back.
14. Open Settings › Privacy. Turn "Encrypt history at rest" off. Confirm History rows now render as
    "Encrypted — …" (unreadable without the toggle on).
15. Turn encryption back on. Confirm History rows render as readable transcripts again.
16. Open Settings › Audio. Change "Stop after silence" to 5 s. Start a hands-free dictation, go
    silent, and confirm it stops automatically after about 5 seconds.
17. Open Settings › Hotkeys. Switch the default mode (push-to-talk ↔ hands-free). Trigger dictation
    and confirm the Flow Bar HUD's idle hint text follows the newly selected mode.

---

## Self-review

- **Spec coverage:** ONB-01…05 + ONB-02a + ONB-04a/SYS-DISK (via ModelsViewModel alerts) — Task 2; MW-02/02d/02e/02n/T-01 — Task 3; ST-02 (mode + fixed rows), ST-04 (+ ST-04n), ST-05 (+ ST-05d) — Task 4; §5 retention/encryption toggles live — Task 1. Deferred by ruling: MB-00, filters/date chips, Re-style (5), Edit, ST-02r/02c, "Test microphone", noise/duck toggles, network counter.
- **Type consistency:** `HistoryService` API used by Tasks 2 (writer box), 3, 4; `DictationSettings` hooks (Task 1) consumed by `AppServices` only; `OnboardingState` keys; `DictationCoordinator.state` observed in Tasks 2 and 4.
- **Placeholders:** none — each task's tests enumerate the behaviours; views follow the quoted copy and the PDF pages.
