# VoxFlow

[![CI](https://github.com/artemsemdev/VoxFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/artemsemdev/VoxFlow/actions/workflows/ci.yml)
[![CodeQL](https://github.com/artemsemdev/VoxFlow/actions/workflows/codeql.yml/badge.svg)](https://github.com/artemsemdev/VoxFlow/actions/workflows/codeql.yml)

Native macOS transcription that never leaves your Mac. Swift 6, SwiftUI, whisper.cpp on Metal.
macOS 15+, Apple Silicon.

VoxFlow 2.0 is a from-scratch rewrite. Version 2.0.0 ships **file transcription**; dictation into
any app, style cleanup with a local LLM and an MCP server follow in 2.x (see the roadmap).

**Status: 2.0.0 released · 2.1.0 (dictation) in progress.**

## What works today (2.0.0)

- Drop audio or video files on the window or the Dock icon, use Finder's Open With, or File › Open.
  MP3, WAV, M4A/AAC, FLAC, AIFF, CAF, MP4, MOV are accepted; anything else is rejected on drop.
- A queue with progress and an ETA, Stop with a confirmation above 10 %, a confirmation for drops
  over four hours, failed rows that never stall the queue, a "2×" badge for duplicate drops.
- Transcripts saved to `~/Transcripts` in the format you chose — TXT, SRT, VTT, JSON or Markdown —
  and re-exported to any other format instantly, without re-processing. Spec: [docs/formats.md](docs/formats.md).
- A result view with Sentences / Short / Long segment lengths, search, Copy, Save as… and Reveal in
  Finder. Preview and export share the chosen segmentation without running recognition again.
- Settings › Models: download Whisper large-v3-turbo (default, 1.6 GB) or Whisper small (480 MB),
  pause and resume, checksum verification before a model counts as installed, remove.
- Everything on this Mac: audio is processed in memory and discarded; the only network action is a
  model download you start. No account, no analytics.

### Dictation (`develop`, in progress toward 2.2.0)

- Hold fn anywhere to dictate (double-tap for hands-free); a floating Flow Bar HUD shows listening,
  processing and the result. Recognized text is inserted into the focused field via Accessibility,
  or copied to the clipboard when there isn't a text field; finished dictations save to encrypted
  history unless the Privacy toggle turns that off.
- File transcription yields the shared speech engine between ten-second windows; pending
  dictation takes priority over the next file window. One model remains loaded for both paths.
- Needs Microphone and Accessibility permission, and Contacts (optional — only prompted if you turn
  on "Learn names from Contacts" on the Dictionary page). First launch walks a five-step onboarding
  window (welcome, permissions, hotkey mode, model, try it) with buttons to grant each permission
  and a scratchpad to try dictation before the main window opens; SETUP.md explains how to reset it.
- VoxFlow's own window is frontmost at launch, so click into the text field you want to dictate
  into (e.g. TextEdit) before the first fn press, or the dictation lands on the clipboard instead.
- History page: search past dictations and filter by app or date, expand a row for the full
  transcript, Edit, Copy, Delete with Undo; right-click an inserted word to add it to Dictionary.
  The expanded row shows the resolved style. Settings › Hotkeys records
  Push-to-talk, Hands-free, Cancel and Re-insert last bindings, checks known system/VoxFlow conflicts,
  and updates the live monitor and HUD hints. Re-insert uses a fresh privacy-checked target and
  supports the current session with history disabled. fn guidance opens Keyboard settings. Audio
  (input device, silence-stop, hands-free) and Privacy (encrypt-at-rest toggle, retention) are
  built.
- Home page: today's words/dictations/speaking pace/time saved, a 7-day word chart with a streak,
  your last 4 dictations, and (before your first dictation) a Setup card that tracks permissions,
  the speech model and your hotkey live. Settings › General: launch at login, show in menu bar,
  start/end sounds, appearance (Light/Dark/System), Flow Bar position, dictation language.
- Settings › MCP Server: a loopback-only MCP server (`127.0.0.1`, tokened) that Cursor or Claude
  Desktop (via `mcp-remote`) can connect to and use as a tool — `transcribe_file`, `dictate` and
  `search_history` (off by default). A floating approval dialog gates every new client by name and
  process, Connected clients lists who's approved with Revoke, and a path policy keeps
  `transcribe_file` to files inside your home directory that you'd already open yourself. See
  [docs/runbooks/connect-an-mcp-client.md](docs/runbooks/connect-an-mcp-client.md) and
  [ADR-008](docs/adr/008-loopback-mcp-server.md).
- Menu bar: click the status item for today's stats, a hands-free toggle, quick actions (History,
  Settings, the language picker) and "Pause dictation for 1 hour" — fn does nothing while paused,
  and the menu bar header reads "Paused until 10:41" until you resume. A model finishing a download
  or a file finishing transcription while the window is in the background sends a notification
  (never for an error) that takes you straight to Models or the result when you click it. See
  [ADR-006](docs/adr/006-menu-bar-and-notifications.md).
- Dictionary page: add names, terms, products and places with an optional phonetic hint; recognised
  words feed the speech engine directly, and "Learn names from Contacts" imports names locally.
- Snippets page: define a trigger (e.g. `/sig`) and a body with `cursor`/`date`/`clipboard`/`app`
  placeholders; say or type the trigger in any app to expand it. `cursor` (also `{cursor}`) places
  the caret within the inserted text when the target supports Accessibility selection.
- Styles page: pick a rewrite tone (Formal, Casual, Very casual, Verbatim) and per-app overrides;
  rule-based styling (fillers removed, punctuation and capitalization added) runs on every
  dictation before it's inserted — see [ADR-005](docs/adr/005-rule-based-styling-pipeline.md).
- On-device style cleanup: an optional local LLM (Qwen2.5 3B Instruct via llama.cpp, Settings ›
  Models) rewrites the tone step for Formal/Casual/Very casual on top of the same rule pass, with
  automatic fallback to rule-based styling whenever the model is absent, still loading, too slow
  or produces a bad answer — dictation never waits on it and never loses a result. "Re-style ▾" on
  a History row rewrites a past dictation into another tone without re-recording and copies the
  result; Files' result view can "Apply {Style} cleanup" to instantly rewrite every segment of a
  finished transcript (rule-based only, no re-processing) — see
  [ADR-007](docs/adr/007-llm-styling-on-llama-cpp.md).

## Roadmap

| Version | Phase | Issue |
|---|---|---|
| 2.1 | Dictation: fn push-to-talk / hands-free, Flow Bar, insertion into any app, onboarding, History | [#110](https://github.com/artemsemdev/VoxFlow/issues/110) |
| 2.2 | Main window and Settings complete, menu bar, notifications, rule-based styles | [#111](https://github.com/artemsemdev/VoxFlow/issues/111) |
| 2.3 | Style cleanup with a local LLM (Qwen2.5 3B via llama.cpp) | [#112](https://github.com/artemsemdev/VoxFlow/issues/112) |
| 2.4 | MCP server on localhost | [#113](https://github.com/artemsemdev/VoxFlow/issues/113) |
| — | Signed and notarized releases | [#115](https://github.com/artemsemdev/VoxFlow/issues/115) |

Dictation (capture, Flow Bar state machine and HUD, the fn hotkey, windowed transcription,
Accessibility insertion, encrypted history), onboarding, the History page and Settings ›
Hotkeys/Audio/Privacy are wired end-to-end on `develop` (unreleased, phase 3c).

Tracking issue: [#105](https://github.com/artemsemdev/VoxFlow/issues/105). The product design is the
Claude Design canvas checked in at [design/](design/).

## Requirements

- macOS 15 or later on Apple Silicon (Intel Macs are not supported).
- To build: Xcode 26.x and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Models are downloaded on demand into `~/Library/Application Support/VoxFlow/Models`.

There are no signed binaries yet; build from source (see [SETUP.md](SETUP.md)).

## Build and test

```bash
xcodegen generate                       # creates VoxFlow.xcodeproj (gitignored)
xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow -destination 'platform=macOS,arch=arm64' build test
```

Package-only tests, no Xcode project needed:

```bash
cd VoxFlowKit && swift test
```

Open `VoxFlow.xcodeproj` in Xcode to run the app (scheme `VoxFlow`). `VoxFlow/Info.plist` is
generated by XcodeGen from `project.yml` (`info.properties`) and is not committed: add usage strings
such as `NSMicrophoneUsageDescription` to `project.yml`. Integration tests that need a Whisper model
look in `~/Library/Application Support/VoxFlow/Models` and skip with a reason when none is installed.

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen definition of the app target and the `VoxFlow` scheme |
| `VoxFlow/` | SwiftUI app shell: App, MainWindow, Files, Settings, Design (per-screen folders appear with their phase) |
| `VoxFlowTests/` | App-layer tests (view models, navigation) |
| `VoxFlowKit/` | SwiftPM package with all logic: Core, Audio, Speech, Models, Files, Dictation, Storage, Styling, MCP |
| `design/` | The Claude Design canvas that is the product spec |
| `docs/adr/` | Architecture decision records |
| `docs/formats.md` | Transcript output format specification |
| `docs/superpowers/` | Design specs and implementation plans (pre-2.0 documents refer to the old `v2/` prefix) |
| `scripts/` | CI helpers (`affected_tests.py`) |
| `spikes/` | Throwaway benchmarks (not built in CI) |

## CI

`.github/workflows/ci.yml` runs a ladder so a small change does not pay for a full macOS build:

| Changed files (PR) | What runs |
|---|---|
| only `docs/**`, `design/**`, `*.md` | nothing on macOS; `result` is green |
| `scripts/**` | Python unit tests for the CI scripts (Ubuntu) |
| `VoxFlowKit/**`, modules the app does not link | `swift test` for the changed modules and their dependents, derived from `swift package describe` by `scripts/affected_tests.py` |
| `VoxFlow/**`, `VoxFlowTests/**`, `project.yml`, `Package.swift`/`Package.resolved`, a module the app links (per `product:` in `project.yml`), any other path in the repository, the workflow itself, or PR label `ci:full` | full `VoxFlow` scheme: build + all tests |

Every pull request runs the classify job and `result` (seconds on Ubuntu) so the required check
always exists. Adding the `ci:full` label to an open PR starts a full run. Pushes to `develop`/`master`
and manual runs always run the full scheme. Branch protection needs only the `CI / result` check.
`codeql.yml` runs CodeQL for Swift on pushes to `develop`/`master`, weekly, and on demand.

## Branching

GitFlow: `master` holds released, tagged versions; `develop` is the integration branch;
`feature/<issue>-<slug>` branches open pull requests into `develop`; `release/x.y.z` branches merge
to `master` with a tag and back into `develop`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## VoxFlow 1.x

The previous implementation (.NET 9, Mac Catalyst, pyannote speaker labeling) is archived on the
[`v1`](https://github.com/artemsemdev/VoxFlow/tree/v1) branch and tag `v1.0.0-final`. It is not
maintained; speaker labeling, Intel Macs and Mac Catalyst are out of scope for 2.x.

## License

See [LICENSE](LICENSE).
