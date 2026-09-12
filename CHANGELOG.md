# Changelog

All notable changes to VoxFlow are recorded here. The format follows Conventional Commits and semantic
versioning.

## Unreleased

### Added
- Files cleanup optionally improves transcripts up to 150 words with the shared local style model,
  preserving segment timing and updating the displayed word count; rules remain the fallback.
- Microphone changes reach dictation and Settings › Audio live. Missing input stops capture;
  switching devices preserves pending audio and transcript timing across the restart gap.
- Settings → Audio offers optional noise suppression with honest minimum/standard/maximum audio
  reduction, plus a five-second microphone record/playback test that keeps audio only in memory.
- Expanded History highlights the actual removed fillers and low-confidence raw words, with
  persisted cleanup counts and token-derived confidence; older rows show only available metadata.
- Name a reported exclusive microphone owner in the Flow Bar and automatically retry a still-active
  dictation gesture when the device is released, with fresh privacy and target checks. Cancel,
  push-to-talk release, and re-insertion stop the wait; another dictation shortcut supersedes it.
- Right-click an inserted History transcript word to add it to Dictionary, with the same validation
  and case/diacritic-insensitive duplicate handling as the Dictionary page.
- Accessibility-denied dictation keeps text on the clipboard and shows “Can't type here” with
  a direct Open Settings action; missing fields and failed insertion have distinct clipboard hints.
- History groups entries by local calendar day, keeps active edits visible across midnight, and
  matches the canvas day surfaces and Mail, Slack, Notes and Xcode tile colors.
- Record Push-to-talk, Hands-free, Cancel and Re-insert last shortcuts in Settings, with saved
  bindings, system/VoxFlow conflict checks, and live keyboard monitoring suspended while recording.
- Re-insert the last dictation into a fresh privacy-checked target without adding duplicate history;
  the session result remains available with history disabled. Escape cancels pending preparation.
- Configured shortcuts appear in HUD hints. fn guidance opens Keyboard settings to choose
  “Do Nothing”, without changing system preferences through private APIs.
- Snippet `cursor` / `{cursor}` placeholders position the caret after insertion, including Unicode
  text. Targets without settable selection keep the inserted text and their normal caret behavior.
- Sidebar request-byte counter persists URLSession measurements from model downloads; its help
  explains the tracking start and excluded traffic.
- History cards match the canvas surfaces, compact actions and divided transcript columns.
- The macOS application and Dock now use the blue four-bar VoxFlow icon from the design canvas.
- History app and calendar-date filters, plus "Search all time" without clearing the query or app.
- Files results: Sentences / Short / Long segmentation controls preview, search, cleanup and all
  exports without re-transcribing. Original transcript data remains available when switching back.
- Persist output-folder access with security-scoped bookmarks, migrate usable path-only settings,
  retain access through exports, and explain fallback to Transcripts when a saved folder is unavailable.
- Inline History editing with Save/Cancel, preserving the raw transcript and encryption.
- Dictation logic: microphone capture, Flow Bar state machine, windowed transcription,
  encrypted history with 30-day retention (no UI yet — phase 3b).
- Dictation wired end-to-end: hold (or double-tap) fn anywhere to dictate. The floating Flow Bar
  HUD shows listening/processing/result; recognized text is inserted into the focused field via
  Accessibility, or copied to the clipboard when there isn't one; finished dictations save to
  encrypted history (Privacy toggle permitting); the menu bar status line follows dictation state.
  Requires Microphone and Accessibility permission, granted on first use.
- First-launch onboarding: a five-step window (welcome, permissions, hotkey mode, model, try it)
  with buttons to grant Microphone and open System Settings for Accessibility, a hands-free/push-
  to-talk choice, model download (or "Installed" when one already is), and a scratchpad to try
  dictation before the main window opens. Progress and completion persist across relaunches.
- History page: search, expand a row for the full transcript, Copy, Delete with Undo; a "Try it"
  entry point from onboarding inserts into a scratchpad without writing a History row.
- Settings › Hotkeys (mode + shortcuts), Audio (input device, silence-stop duration, hands-free)
  and Privacy (encrypt-history-at-rest toggle, retention) — live, editing them applies immediately.
- Launch wiring: `HistoryService` opens (and starts retention) once at every real launch; the
  XCTest host skips that open, dictation start, Flow Bar binding and the fn/esc monitor so running
  tests never opens the microphone, installs global monitors or touches the Keychain.
- Dictionary page: add names, terms, products and places with an optional phonetic hint and
  "Also fix it when I type it wrong"; duplicate detection is case- and diacritic-insensitive.
  "Learn names from Contacts" imports first + last names locally (permission prompt, denied/
  granted/importing states, re-imports when Contacts changes, entries removed if the toggle
  turns off).
- Snippets page: create a trigger (`/sig`) and a multiline body with `cursor`/`date`/`clipboard`/
  `app` placeholders, an optional "Only in {app}" scope, and a "Say 'snippet' before the trigger"
  toggle to avoid accidental expansion; triggers work by typing (`/sig`) or speaking ("slash sig").
- Styles page: choose a default rewrite tone (Formal, Casual, Very casual, Verbatim) plus
  per-app overrides by bundle id, and global "Remove filler words" / "Auto-punctuate and
  capitalize" toggles.
- Rule-based styling pipeline (`RuleStyler`, `SnippetExpander`, `StyleResolver` — see ADR-005):
  dictation is styled and snippet-expanded after the speech engine returns; History stores the
  raw engine text, the styled text, and the resolved style's name.
- Dictionary words feed the speech engine as `TranscriptionOptions.vocabulary` (most-used first,
  capped at 64) so recognised names/terms get spelled right without a manual correction pass.
- `dictionary`, `snippets` and `app_style_overrides` tables added to the shared VoxFlow SQLite
  database (unencrypted — only dictation text is sensitive, per ADR-004).
- Home page: today's words/dictations/speaking pace/time saved, a 7-day word chart with a streak,
  the last 4 dictations, and a first-run Setup card (permissions, speech model, hotkey) that
  reappears whenever a permission is later revoked.
- Settings › General: launch at login (`SMAppService`), show in menu bar, play sounds on
  dictation start/end, appearance (Light/Dark/System), Flow Bar position, dictation language.
- Settings › MCP Server (UI only this phase — the server itself ships in 2.4): endpoint and access
  token with Copy/Regenerate (a confirmation alert first), which tools are exposed.
- Native `--mcp-stdio` transport for client-launched local MCP sessions, with bounded framing,
  shared tool/privacy policies, protocol-only stdout and capture cleanup on client shutdown.
- Menu bar: a window-style dropdown (status, hands-free toggle, today's stats, quick actions, a
  language picker, a footer) replaces the plain menu; a first-run hint introduces it once, after
  onboarding finishes.
- Pause: "Pause dictation for 1 hour" from the menu bar or the Flow Bar pill — fn does nothing
  while paused; the pill shows "Paused · N min left" and hides itself after 3 s; the menu bar
  header reads "Paused until 10:41" until Resume.
- Completion notifications: a model finishing its download, or a file finishing transcription,
  posts a system notification while VoxFlow's window isn't the frontmost one — never for an
  error — and clicking it opens Settings › Models or the Files result. See
  [ADR-006](docs/adr/006-menu-bar-and-notifications.md).
- On-device style cleanup (Qwen2.5 3B Instruct via llama.cpp, Settings › Models): the Formal,
  Casual and Very casual tones are rewritten by a local LLM on top of the existing rule pass
  (fillers, auto-punctuation), with deterministic (greedy) sampling and automatic fallback to
  rule-based styling whenever the model is absent, still loading, the text is too long, generation
  is slow, or the output fails validation. The model loads lazily, warms up once at launch, and
  releases its memory after five idle minutes or macOS memory pressure; the next styled request
  reloads it automatically. See
  [ADR-007](docs/adr/007-llm-styling-on-llama-cpp.md).
- "Re-style ▾" on History rows: pick Formal, Casual, Very casual or Verbatim from a popover to
  rewrite a past dictation into another tone without re-recording; the row updates in place and
  the result is copied to the clipboard.
- Files result view: "Apply {Style} cleanup" checkbox rewrites every segment of a finished
  transcript through the rule-based pipeline (instant, no re-processing) — the preview, Copy,
  Save as… and "Also export" all reflect the cleaned text while it's checked.
- Loopback MCP server (Settings › MCP Server): Cursor, or Claude Desktop via `mcp-remote`, can
  connect over `127.0.0.1` with the token from Settings and use `transcribe_file`, `dictate` and
  `search_history` (off by default) as tools. A floating approval dialog (name + pid, "Always
  allow"/"Allow once"/"Deny") gates every new client, keyed on process name and executable path so
  a relaunched client keeps its approval; Connected clients lists who's approved with Revoke;
  regenerating the token disconnects and de-approves everyone. `transcribe_file` is bounded by a
  path policy (inside the home directory, not under `~/Library`, a supported extension);
  `search_history` skips unreadable rows the same way History does; `dictate` runs one hands-free
  capture through the same path the hotkey uses, so the Flow Bar shows it and the result is
  inserted and saved normally. Answers both the current MCP protocol revision and the older
  `initialize` handshake real clients speak today. Never opens an outbound connection of its own.
  See [ADR-008](docs/adr/008-loopback-mcp-server.md) and
  [docs/runbooks/connect-an-mcp-client.md](docs/runbooks/connect-an-mcp-client.md).

### Fixed

- Confirm quitting during file transcription or dictation; “Finish, then quit” waits for exports and dictation history to finish saving.
- Files previews follow the selected output format, retain the source filename extension, and keep
  a compact header. Searching the preview leaves the complete copy/export transcript intact.
- Live dictation limits model readiness and styling to the remaining processing time, falling back
  to rule cleanup after a slow final speech window instead of adding a fresh eight-second wait.
- Models settings and download hints share the same decimal size labels, including 480 MB for Small.
- Snippets preserve authored spacing, clipboard indentation and attachment characters while keeping
  cursor offsets correct. Dictionary usage counts symbol names and flexible phrase spacing, and
  vocabulary ranking favors user entries over contacts when usage is tied.
- File decoding reports progress and responds to Stop between read/conversion chunks instead of
  finishing the entire decode before observing cancellation.
- Long files decode on demand with bounded detection/window buffers; full recordings no longer
  accumulate as PCM in memory, and no temporary audio file is written.
- MCP startup and stop races: concurrent first callers share initialization, and an older operation
  cannot restart a disabled server or overwrite a newer endpoint and setting.
- Stopping the MCP listener cancels pending binding; old waiting callers cannot restart it or
  interfere with a later explicit start. Default unit tests no longer probe or bind loopback sockets.
- Hosted tests no longer construct live app scenes or services, preventing Home and menu-bar
  refreshes from opening the real history database and prompting for its Keychain key.
- CI selects the arm64 Mac destination and rejects warnings from build/test logs regardless of letter case.
- Style-model loading rejects missing, non-file and unreadable paths before starting the native
  backend, avoiding unnecessary GPU initialization and Metal compiler warnings in failure-path tests.
- Long file jobs yield the speech engine between bounded windows, with queued dictation taking
  priority instead of waiting for the entire file to finish.
- Files and Settings show “Loading into memory…” while the shared speech model prepares for first
  use, before transcription progress begins; concurrent Files and dictation callers share one load.
- Settings › General's appearance and Flow Bar position now apply at launch, not only once
  Settings has been opened at least once.
- The Flow Bar HUD and the menu bar's "Paused until 10:41" now read the same clock instead of two
  independently-started ones that could disagree by however long apart they were created.

## 2.0.0 — 2026-09-08

VoxFlow 2 is a from-scratch native macOS rewrite (Swift 6, SwiftUI, whisper.cpp on Metal). It replaces
the .NET 9 / Mac Catalyst implementation, which is archived on the `v1` branch and tag `v1.0.0-final`.

### Added
- File transcription: drop or open audio/video files (MP3, WAV, M4A/AAC, FLAC, AIFF, CAF, MP4, MOV),
  a queue with progress and ETA, stop and long-audio confirmations, per-file error rows.
- Output formats TXT, SRT, VTT, JSON and Markdown, saved to `~/Transcripts` and re-exportable
  without re-processing (`docs/formats.md`).
- Result view with segments, search, Copy, Save as… and Reveal in Finder.
- Settings › Models: download, pause/resume, checksum verification and removal of Whisper
  large-v3-turbo and Whisper small.
- On-device speech engine over the pinned whisper.cpp v1.9.2 XCFramework; language auto-detection;
  per-segment confidence.

### Changed
- Everything: new architecture (SwiftPM package `VoxFlowKit` + thin SwiftUI app), new CI ladder
  that runs only the tests a change can affect, GitFlow branching.

### Removed
- Speaker labeling / diarization, Intel Mac and Mac Catalyst support, the CLI and the MCP server
  (the MCP server returns in 2.4; the CLI is not planned).

### Not yet
- Dictation into other apps (2.1), main window pages beyond Files (2.2), style cleanup (2.3),
  MCP (2.4), signed and notarized builds (build from source for now).
