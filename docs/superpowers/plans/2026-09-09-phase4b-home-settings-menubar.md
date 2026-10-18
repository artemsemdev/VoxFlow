# VoxFlow v2 Phase 4b — Home, Settings › General & MCP (UI), menu bar, notifications, Pause — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish #111: the Home page (MW-01, MW-01e) with real stats, Settings › General (ST-01) and Settings › MCP Server (ST-06, ST-06r — UI only, no server), the menu bar (MB-00…04) with the FB-09 "Paused" state, and completion-only notifications (MB-03, MB-04). After this every sidebar page and Settings tab exists.

**Architecture:** `StatsService` (app) computes Home/menu-bar numbers from new `DictationStore` aggregate queries (today's words/dictations/duration, last-7-days words per day, streak). `GeneralSettings` / `MCPSettings` persist ST-01/ST-06 choices; appearance, Flow Bar position, launch-at-login (`SMAppService`) and sounds are applied by small adapters behind protocols. The menu bar moves from a plain `MenuBarExtra` menu to `MenuBarExtra(…, .window)` with a SwiftUI dropdown (toggle, stats, items, footer) and a status glyph; MB-00 is a small floating hint panel. `FlowBarMachine` gains `.paused(until:)` (FB-09). `NotificationCoordinator` posts `UNUserNotificationCenter` notifications only for completions while the main window is not frontmost.

**Tech Stack:** SwiftUI + AppKit (`MenuBarExtra` window style, `NSPanel`, `NSAppearance`, `SMAppService`, `NSSound`), `UserNotifications`, GRDB aggregates, Swift Testing, XcodeGen.

**Spec:** design spec §1; canvas 1c MW-01 + 3c MW-01e (PDF pages 3, 11–12), ST-01, ST-06/06a/06r (text extraction; PDF page 5 ST-06a/06r alerts), 1b MB-01 (page 11), 2b MB-02/MB-03/MB-04 (page 8), MB-00 (page 4), FB-09 (page 8), 3d "Notifications"/"Toggles"/"Main window", 3e "MCP port busy" (phase 6). Issue #111 (part 2).

**Rulings (binding):**
1. **Stats definitions** (canvas shows numbers only): *Words today* = sum of `words` for dictations since local midnight; *Dictations* = count today; *Speaking pace* = words ÷ (total dictation minutes) over today, "—" when no dictation; *Time saved* = words ÷ 40 (typing at 40 wpm) − dictation minutes, floored at 0, shown as "N min"; *This week* = words per local day for the last 7 days ending today, total = sum; *streak* = consecutive days ending today with ≥ 1 dictation ("12-day streak"; hidden when 0). "Recent" = last 4 dictations (History rows); "See all" → History.
2. **Greeting**: "Good morning" (<12), "Good afternoon" (<18), "Good evening"; name = first token of `NSFullUserName()`; date line "Monday, September 7" (long weekday, month day, current locale) + " · N-day streak" when ≥ 2.
3. **MW-01e first run**: shown while there are no dictations; Setup card rows reflect live status (Microphone & Accessibility granted → green / red with "Open Settings"; Speech model → installed name or "Download" link to Settings › Models; Hotkey · hold fn / double-tap fn → "Change" → Settings › Hotkeys); "Try it here" scratchpad uses `EphemeralScope` (not saved); stats placeholders "—" / "0". 3e "Permission revoked later": the Setup card returns on MW-01 whenever a permission is missing.
4. **Settings › General**: Launch at login via `SMAppService.mainApp` (register/unregister; toggle snaps back on failure per 3d "Toggles"); Show in menu bar → `MenuBarExtra(isInserted:)`; Play sounds → `NSSound` "Tink"/"Pop" system sounds on `.listening` enter and `.inserted`/`.copied`; Appearance Light/Dark/System → `NSApp.appearance`; Flow Bar position → `FlowBarPanel` anchor (Bottom center / Top center / Bottom left / Bottom right); Dictation language picker (Auto-detect + the seven canvas languages) → `DictationSettings.language`. No accent-colour control (not in canvas).
5. **Settings › MCP Server is UI only**: `MCPSettings` persists enabled (default ON per canvas — ruling: default **OFF** until phase 6 ships the server; the toggle shows "Server arrives in a later release" as a footnote), endpoint text `http://127.0.0.1:7331/mcp` with Copy, token `vf_` + 32 hex stored in the Keychain (`KeychainKeyProvider`-style item, masked display `vf_••••••••••••7c2e`), Regenerate → ST-06r alert ("Regenerate and copy" copies the new token), tools list with toggles (`transcribe_file`/`dictate` ON, `search_history` OFF), Connected clients empty state "No clients yet — connect Claude Desktop or Cursor with the token above." ST-06a alert is phase 6.
6. **Menu bar**: `MenuBarExtra` with `.menuBarExtraStyle(.window)` and a template glyph (three bars, drawn in code until #141 ships the icon asset); dropdown per MB-01 (header + status dot/colour from `MenuBarStatus`, "Hands-free mode" toggle bound to `hotkeyMode`, stats row from `StatsService`, items with shortcuts, "Language: {name} ▸" submenu = the same picker as General, footer "No network connections · N models on disk · {mode}"); MB-02 variant when paused ("Paused until 10:41" amber, "Resume dictation" prominent) or downloading (progress from `ModelsViewModel`, "62%"). MB-00 hint = a small non-activating panel below the menu bar at the right, shown once after onboarding (`onboarding.hintShown`), auto-dismiss 10 s or on first dictation, "Got it".
7. **Pause (FB-09)**: `FlowBarEvent.pause(seconds:)` / `.resume` / `.timer(.pauseEnd)`; state `.paused(until: TimeInterval)`; fn-down while paused → `[]` (ignored); the pill shows "Paused · 58 min left" + "Resume" and hides after 3 s (`FlowBarPresenter` pausedHideDelay 3 s); resume from the pill button or the menu bar; the coordinator exposes `pause(for:)`, `resume()`, `pausedUntil: Date?`.
8. **Notifications**: `UNUserNotificationCenter` authorization requested on the first completion; post only when `NSApp.isActive == false || main window not key`; MB-03 "{Model} installed. Ready to use offline." (click → Settings › Models), MB-04 "{file} transcribed · {duration} · {FORMAT} saved to ~/Transcripts" (click → the Files result for that row); never for errors; `NotificationPosting` protocol with a fake for tests.
9. **⌘1–7 and menu shortcuts**: History ⌥⌘H, Open ⌘O, Settings ⌘, — via the app's `.commands`.

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated`.
- Views hold no rules; every number/string decision in a tested type. Copy verbatim from the canvas (quoted per task). Design reference `.superpowers/design/canvas.pdf`; render tests (`VOXFLOW_RENDER=1`) per UI task; implementer + reviewer compare.
- Blocking storage off the main actor; no sleeps in non-render tests.
- Commits: Conventional Commits, owner-authored, no attribution. Branch `feature/111-phase4b-home-settings-menubar` from `develop` (after PR #149 merges); PR into `develop`.
- Verification per task: `cd VoxFlowKit && swift test` where the package changed; `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`.

---

### Task 1: Stats — storage aggregates, `StatsService`, FB-09 Pause in the machine

**Files:**
- Modify: `VoxFlowKit/Sources/VoxFlowStorage/DictationStore.swift` (+ tests): `func stats(since: Date) throws -> DictationStats` (`count`, `words`, `duration`), `func wordsPerDay(days: Int, endingAt: Date, calendar: Calendar) throws -> [DayWords]` (`date`, `words`; zero-filled), `func streak(endingAt: Date, calendar: Calendar) throws -> Int`.
- Modify: `VoxFlowKit/Sources/VoxFlowDictation/{FlowBarMachine,FlowBarConfig,DictationController}.swift` (+ tests): `.paused(until:)`, events `.pause(seconds:)`, `.resume`, timer `.pauseEnd`; controller `pause(for:)`, `resume()`; `FlowBarState.paused` is dismissable-like but *not* retried by fn-down (fn ignored); `FlowBarContent` (app, Task 4) renders it.
- Create: `VoxFlow/Home/StatsService.swift` (`@Observable @MainActor`; `today: HomeStats` (words, dictations, paceWPM?, minutesSaved), `week: [DayWords]`, `weekTotal`, `streak`, `recent: [DictationRecord]`; `refresh() async` (off-main via `HistoryService.database`), refresh hooks after every history write/delete and at launch; pure helpers `HomeStats.minutesSaved(words:minutes:)`, `pace(words:minutes:)`, `Greeting.text(hour:)`, `Greeting.dateLine(date:streak:locale:)`).
- Test: storage aggregates (fixed dates across midnight, calendar with a fixed time zone), machine pause tests (fn ignored, timer ends → idle, resume → idle, HUD effects), `StatsServiceTests` (pure helpers + a seeded temp database).

- [ ] Tests → implementation → commit `feat: dictation stats aggregates, StatsService and the Paused HUD state`

### Task 2: Home page (MW-01, MW-01e)

**Files:** `VoxFlow/Home/{HomeViewModel,HomePage,StatCard,WeekChart,SetupCard,RecentList}.swift`; `MainWindow` routes `.home`; `AppServices` builds the VM; tests + `HomeRenderTests`.
**Copy:** stat labels "Words today" / "Time saved" (unit "min") / "Speaking pace" (unit "wpm") / "Dictations"; "Recent" + "See all"; "This week" + "{n} words"; card "Everything stays on your Mac": Speech → on-device model, Cleanup → on-device LLM, History → encrypted on disk, Network → none; header chip "{Push-to-talk|Hands-free} · fn"; first run: "Welcome, {Name}" / "Everything is set up. Your stats appear after the first dictation." / Setup rows "Microphone & Accessibility" · "Granted", "Speech model" · "{model}", "Hotkey · hold fn" · "Change"; "Try it here" / "Hold fn and say anything. Release to see it appear." / "This scratchpad isn't saved to History."
**Design:** PDF page 11–12 (MW-01), page 3 (MW-01e). Chart: 7 bars, day letters, today accent-coloured.
- [ ] VM tests (greeting/date line, chip, first-run switching, setup rows from permissions/model/hotkey, See all navigation, recent rows meta reuse from History); renders; commit `feat(app): Home page with stats, recent, week chart and first-run setup`

### Task 3: Settings › General and Settings › MCP Server (UI)

**Files:** `VoxFlow/Settings/{GeneralSettings,GeneralViewModel,GeneralSettingsView,MCPSettings,MCPViewModel,MCPSettingsView}.swift`, adapters `VoxFlow/System/{LoginItem,AppearanceApplier,SoundPlayer}.swift` (protocols + real impls), `VoxFlow/FlowBar/FlowBarPanel.swift` (position enum), `VoxFlow/App/VoxFlowApp.swift` (`MenuBarExtra(isInserted:)`), `SettingsPage` routes; tests + `SettingsRenderTests` additions.
**Copy (ST-01):** "Launch at login", "Show in menu bar", "Play sounds when dictation starts and ends", "Appearance" (Light / Dark / System), "Flow Bar position" (Bottom center …), "Dictation language" (Auto-detect, English, Español, Français, Deutsch, 日本語, Português). **(ST-06):** "Enable MCP server" / "Lets local AI clients use VoxFlow as a tool. Listens on localhost only."; "Endpoint" `http://127.0.0.1:7331/mcp` + "Copy"; "Access token" `vf_••••••••••••7c2e` + "Regenerate"; "Tools exposed": `transcribe_file` — "Transcribe an audio file at a path; returns text or SRT", `dictate` — "Start a dictation and return the cleaned-up text", `search_history` — "Search past dictations — off by default"; "Connected clients"; ST-06r: "Regenerate the access token?" / "Claude Desktop and Cursor will be disconnected until you paste the new token into them." / "Regenerate and copy" / "Cancel".
- [ ] VM tests (login toggle snap-back on failure with a fake, appearance applied, position persisted and applied, language, sounds on state transitions with a fake player; token generation/masking/regenerate copies, tool toggles persist, enabled default OFF); renders; commit `feat(app): Settings › General and MCP Server (UI)`

### Task 4: Menu bar (MB-00…02), Paused pill (FB-09)

**Files:** `VoxFlow/MenuBar/{MenuBarView,MenuBarViewModel,MenuBarGlyph,MenuBarHintPanel}.swift`, `VoxFlow/App/VoxFlowApp.swift` (`MenuBarExtra` window style + glyph), `VoxFlow/FlowBar/{FlowBarContent,FlowBarPresenter}.swift` (paused content + 3 s hide), `DictationCoordinator` (`pause(for:)`, `resume()`, `pausedUntil`), onboarding `finish()` → `hintShown` flow; tests + renders.
**Copy:** header "VoxFlow" + "● Ready · on-device" / "● Paused until 10:41" / "Listening…" / "Cleaning up…"; "Hands-free mode" toggle; "{1,240} words today" · "{18 min} saved"; items "Open VoxFlow ⌘O", "History ⌥⌘H", "Pause dictation for 1 hour", "Language: {name} ▸", "Settings… ⌘,", "Quit VoxFlow ⌘Q"; footer "No network connections · {N} models on disk · {mode}"; MB-02 "Resume dictation", "Downloading {model}" + "{62}%"; MB-00 "VoxFlow lives here" / "Hold fn in any text field to dictate. Click this icon for stats, pause and settings." / "Got it"; FB-09 pill "Paused · 58 min left" + "Resume".
**Design:** PDF page 11 (MB-01), page 8 (MB-02, FB-09), page 4 (MB-00).
- [ ] VM tests (status/dot/mode/stats/footer text, pause for 1 h → `pausedUntil`, "until 10:41" formatting, resume, download variant, hint once), machine/presenter tests for the paused pill; renders; commit `feat(app): menu bar dropdown, paused state and first-run hint`

### Task 5: Notifications (MB-03, MB-04) + shortcuts + wiring + docs + PR

**Files:** `VoxFlow/Notifications/{NotificationPosting,NotificationCoordinator,UserNotifications+Posting}.swift`, `VoxFlow/App/{AppServices,AppDelegate,VoxFlowApp}.swift` (commands ⌘O/⌥⌘H/⌘,), `README.md`, `CHANGELOG.md`, `docs/adr/006-menu-bar-and-notifications.md` (why window-style MenuBarExtra, MB-00 approximation, notification rules), plan Task 5 owner checklist; tests.
- `NotificationCoordinator(posting:, frontmost: () -> Bool, navigation:)` subscribes to `ModelStore` install completions (via `ModelsViewModel`/store events) and `FileQueue.finished`; posts only when not frontmost; click routing; tests with fakes (frontmost true → nothing; false → one post with the exact copy; click routes).
- [x] Tests → implementation → commits `feat(app): completion notifications for model installs and file transcriptions`, `refactor(app): fold phase 4b services into AppServices; apply appearance and Flow Bar position at launch`, `fix(app): File › Open… on ⇧⌘O; wire token copy and the first-run hint`, `docs: ADR-006 menu bar and notifications; README/CHANGELOG; phase 4b checklist` — `NotificationCoordinatorTests` (9 tests: frontmost posts nothing for both kinds, backgrounded posts the exact MB-03/MB-04 copy, a failed transcription never posts, an already-installed model never fires spuriously, both routes click correctly, `durationText` formatting) plus the full `VoxFlowTests`/`swift test`/`scripts/tests` suites (see task report for counts) all green.
- Owner checklist (manual, run once in the built app before opening the PR):
  - [ ] Home stats change after two real dictations
  - [ ] the first-run Setup card reappears on Home after revoking a granted permission
  - [ ] Settings › General: login/appearance/position/sounds toggles apply live; login snaps back if `SMAppService` registration is denied
  - [ ] Settings › MCP Server: endpoint Copy, token Copy, Regenerate (with its confirmation) all work
  - [ ] menu bar dropdown: every item navigates correctly; "Pause dictation for 1 hour" → the Flow Bar pill reads "Paused · N min left" and hides itself after 3 s; Resume (from the pill or the dropdown) clears it
  - [ ] with the main window backgrounded, a model finishing its download shows a system notification reading "{model} installed. Ready to use offline.", and clicking it opens Settings › Models
  - [ ] with the main window backgrounded, a file finishing transcription shows a system notification reading "{file} transcribed · {duration} · {FORMAT} saved to ~/Transcripts", and clicking it opens that file's Files result
- PR into `develop`: `Closes #111` after ticking the criteria the tests + checklist confirm.

## Self-review
- Coverage: MW-01/01e (T2), ST-01/ST-06/06r (T3), MB-00…02 + FB-09 (T4), MB-03/04 (T5), 3d rules (toggles snap back, notifications only when not frontmost). Deferred: ST-06a client alert + real server (phase 6), Re-style (5), ST-02r/02c shortcut recording (follow-up), accent colour (not in canvas).
- Consistency: `StatsService` consumed by Home (T2) and the menu bar (T4); `MenuBarStatus` extended, not duplicated; pause API from T1 used by T4; `EphemeralScope` reused for the Home scratchpad.
