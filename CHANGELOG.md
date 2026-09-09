# Changelog

All notable changes to VoxFlow are recorded here. The format follows Conventional Commits and semantic
versioning.

## Unreleased

### Added
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

### Fixed
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
