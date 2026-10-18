# ADR-006: Menu bar, the first-run hint, Pause, and completion notifications

Status: Accepted · Date: 2026-09-09

## Context

Phase 4b (#111 part 2) adds the menu bar (design MB-00…04) — a status item with a
dropdown showing dictation state, today's stats, quick actions and a language
picker — plus FB-09 "Pause dictation for 1 hour" and MB-03/MB-04 completion
notifications for a finished model download or file transcription. All four
pieces share one constraint: none of it may interrupt what the user is doing.
The dropdown must not steal focus from whatever's being dictated into; the
first-run hint must introduce the menu bar once, unobtrusively, then get out of
the way; Pause must degrade the fn hotkey to a no-op without the HUD nagging
about it; and a notification must never fire for something the user is already
looking at.

## Decision

- **`MenuBarExtra(..., .window)`, not a plain `Menu`.** AppKit's classic
  `NSMenu`-backed `MenuBarExtra` content can only hold `Button`/`Toggle`/
  `Picker`-shaped items — no free-form layout, no custom stats row, no colored
  status dot. `.menuBarExtraStyle(.window)` renders arbitrary SwiftUI
  (`MenuBarView`) in a borderless panel instead, which is what MB-01/MB-02's
  canvas (header + status dot, stats row, a "Language: {name} ▸" submenu-style
  disclosure, a footer) actually needs. The status item's own glyph
  (`MenuBarGlyph`) is drawn in code — a template image built from three bars —
  rather than shipping an asset, until #141 lands the real icon.
- **MB-00's hint is a small floating `NSPanel`, not a native onboarding
  callout.** SwiftUI has no supported way to attach a callout to an
  `MenuBarExtra` status item's frame (its `NSStatusItem` isn't exposed).
  `MenuBarHintPanel` approximates the canvas's "VoxFlow lives here" bubble as a
  non-activating panel positioned under the status item's known screen
  location instead — close enough to read as attached, without pretending to
  be a first-class `NSPopover` anchored to the item (which would need private
  API to reach). It shows once, gated by `OnboardingState.hintShown` and
  `GeneralSettings.showInMenuBar` (`MenuBarHintPolicy.shouldShow` — the latter
  guard is review M4: without it, turning the menu bar item off before
  finishing onboarding got a hint pointing at an empty menu bar), triggered by
  `OnboardingViewModel.onFinished`
  (wired from `OnboardingWindow.onAppear` to
  `MenuBarServices.shared.showHintIfNeeded()`), and dismisses itself after 10 s
  or on the first sign of an actual dictation (`MenuBarHintPolicy.shouldDismiss`),
  whichever comes first — "Got it" is the third way out.
- **Pause (FB-09) lives in the same state machine as everything else, not a
  side flag.** `FlowBarState.paused(until:)` is reachable from `.idle` or any
  dismissable state via `.pause(seconds:)`; a `.pauseEnd` timer (real seconds,
  driven by the same `MonotonicClock` as every other Flow Bar timer) returns it
  to `.idle`, or `.resume` clears it early. `.paused` is deliberately *not*
  dismissable the way `.inserted`/`.copied` are: an fn-down while paused
  produces no HUD effects at all (ruling 7) rather than being treated as a
  retry — the whole point of pausing is that fn stops doing anything.
  `FlowBarPresenter` still auto-hides the *pill* 3 s after entering `.paused`
  (`pausedHideDelay`, shorter than the normal 6 s `idleHideDelay`) — the status
  stays true (`dictation.pausedUntil` and the menu bar's "Paused until 10:41"
  header don't go anywhere), only the on-screen pill stops crowding the
  screen. Resuming briefly re-shows the pill as a confirmation if it had
  already auto-hidden. `DictationCoordinator.pause(for:)`/`resume()`/
  `pausedUntil` are the one place both the pill and the menu bar dropdown read
  from, so the two can't disagree about whether — or until when — VoxFlow is
  paused. `DictationCoordinator.isHUDActive` (`FnKeyMonitor`'s gate for its
  *global* `.keyDown` handler) excludes `.paused` (review I1): before FB-09
  every non-idle state was seconds long, but a hold can last up to an hour,
  and leaving `.paused` "HUD active" meant every keystroke in every app, for
  the whole pause, forwarded into the dictation actor for no visible effect.
  The pill itself is unaffected — `FlowBarPresenter` shows/hides off `state`,
  never off `isHUDActive`.
- **Notifications are completion-only, and only when nobody's looking.**
  `NotificationCoordinator` posts MB-03 (a model finishing an install) and
  MB-04 (a file finishing transcription) through `NotificationPosting` — never
  for an error; a failed download already has its own alert
  (`ModelsViewModel.Alert`), and a failed transcription already has its own
  inline MW-06x row, so a system notification on top would be a second,
  redundant interruption for the same fact. A notification is skipped
  entirely when `NSApp.isActive && the main window is key` — Settings or
  Onboarding being key while the app is active still counts as "away", since
  the person isn't looking at Files or Home either, which is where the
  notification would take them.
  - MB-04 subscribes to `ExportCoordinator.onExported` — the export's own
    success signal, not `FileQueue.subscribe()`'s `.finished(item)` directly.
    `ExportCoordinator` and `NotificationCoordinator` used to be two
    independent subscribers to the same queue event with no delivery-order
    guarantee, so a notification could post before the export had written
    anything, with a hard-coded "~/Transcripts", and even when the export
    itself then failed (review I2, phase 4b fix round). Subscribing to the
    export's outcome instead means the body is always built from the file's
    real destination (`FilesSettings.outputFolder`, abbreviated the same way
    Finder/Save panels do) and never fires when the export failed.
  - MB-03 has no equivalent standalone event: `ModelStore.install(id:)`
    returns a fresh `AsyncThrowingStream` per call, and the one already in
    flight is fully consumed inside `ModelsViewModel.download(_:)`. Rather
    than have two independent consumers race over the same producer, or wire
    a second event bus through `ModelStore` for a single subscriber,
    `NotificationCoordinator` watches `ModelsViewModel`'s own `@Observable`
    `speechRows`/`styleRows` (the same rows Settings › Models and the menu
    bar's MB-02 "Downloading…" already read) via `withObservationTracking`,
    and diffs each row's state against what it held the last time this fired.
    A row is reported exactly once, on the transition into `.installed` —
    never for a row that was already installed before the coordinator started
    (seeded at `start()`), and never twice for the same install.
  - `UNUserNotificationCenter` authorization (`.alert` + `.sound`) is
    requested lazily, the first time something actually needs to post — never
    at launch, and never for a completion that never posts because the main
    window was frontmost. The result isn't otherwise cached by contract
    (`NotificationPosting.authorize()` makes no promise about repeat-call
    cost); `NotificationCoordinator` itself only calls it once per run.
  - A click routes back through `UserNotificationsPoster`'s delegate, which
    resolves the clicked notification's id to the `NotificationRoute` it was
    posted with and hands it to `NotificationCoordinator.handleRoute(_:)` —
    `.settingsModels` opens Settings › Models, `.filesResult(itemID:)` opens
    Files and selects that row via `FilesViewModel.open(_:)` (falling back to
    just opening Files if the row's since been removed from the queue).

## Consequences

- The window-style `MenuBarExtra` trades away the free "click closes the
  dropdown, standard menu keyboard navigation" behavior a plain `Menu` gets
  for free — `MenuBarView` has to be a normal SwiftUI view with its own
  buttons and hit-testing, and hasn't been given the accessibility pass a
  native menu would get automatically. Acceptable for phase 4b; worth
  revisiting once VoiceOver-style navigation of the dropdown is asked for.
- The hint panel is a good-enough approximation, not pixel-perfect: it
  guesses the status item's screen position from `NSStatusItem.button` at
  show time rather than tracking it live, so a status item that moves
  (another app rearranging the menu bar) mid-hint could leave the panel
  pointing at the wrong spot for the rest of that 10 s window. Rare enough in
  practice not to be worth a live position-tracking loop for a one-time,
  short-lived hint.
- Watching `ModelsViewModel`'s rows instead of a dedicated `ModelStore` event
  means MB-03 is coupled to whatever `ModelsViewModel` happens to expose —
  if a future refactor stops routing installs through
  `ModelsViewModel.download(_:)`, this diff-based detection silently stops
  firing rather than failing loudly. Documented here specifically so that
  refactor doesn't miss it.
- "Frontmost" is checked at the moment a completion happens, not re-checked
  when the notification is about to be *displayed* a moment later by the OS —
  a person switching to VoxFlow in the half-second between the check and the
  banner appearing sees a notification for something they're now looking at.
  Treated as acceptable jitter rather than a bug worth chasing.

## Related

- [ADR-003](003-dictation-state-machine.md) — the base `FlowBarState` machine
  FB-09's `.paused` extends.
- Design canvas pages 4 (MB-00), 8 (MB-02, FB-09), 11 (MB-01); controller
  ruling 8/9 in the phase 4b plan header
  (`docs/superpowers/plans/2026-09-09-phase4b-home-settings-menubar.md`).
