# VoxFlow v2 — design spec

Date: 2026-09-07 · Status: approved in conversation, pending written review · Tracking issue: #105

VoxFlow v2 is a from-scratch native macOS application. v1 (.NET 9 / MAUI) is archived on
branch `v1` and tag `v1.0.0-final`; it is **not** a reference for v2 behaviour, file formats
or code. The product specification is the Claude Design canvas checked in at
`v2/design/VoxFlow.dc.html` (three design turns, 60+ screens and states, inventory in
section 3b, transition timings in 3d, edge cases in 3e).

## 1. Product

**One sentence.** Speak into any text field on the Mac and get clean text, entirely
on-device; also transcribe audio/video files; expose both to local AI clients over MCP.

**In scope (from the design).**
- Dictation loop: Flow Bar HUD (FB-01…12), push-to-talk (hold fn ≥ 250 ms) and hands-free
  (double-tap fn ≤ 350 ms, stop after 3 s silence, 15 min cap), insertion via Accessibility
  with clipboard fallback, excluded apps / secure input, language chip + popover.
- Menu bar (MB-00…04) and completion-only notifications.
- Main window: Home, History, Dictionary, Snippets, Styles, Files, Settings (⌘1–7).
- Settings: General, Hotkeys, Models, Audio, Privacy, MCP Server.
- Onboarding ONB-01…05 with permission-denied branches and model download.
- Models catalog: Whisper large-v3-turbo (default, 1.6 GB), Whisper small (480 MB),
  Qwen2.5 3B Instruct Q4 (1.9 GB) for style cleanup.
- Files: drop/queue, TXT/SRT/VTT/JSON/MD, result view with instant re-export.
- MCP server on loopback with token, tools `transcribe_file`, `dictate`, `search_history`.
- Privacy promise as a system: green "on-device" status on every surface; the only network
  call is a model download the user starts.

**Out of scope in v2.** Speaker labeling / diarization; Intel Macs and Mac Catalyst; MAUI;
CLI (revisit after promotion); Parakeet TDT (not available in whisper.cpp); auto-updates.

## 2. Decisions (with reasons)

| Decision | Choice | Why |
|---|---|---|
| Language / UI | Swift 6 language mode, SwiftUI with AppKit bridges, macOS 15+ | Design assumes macOS 15 controls; strict concurrency removes the data-race class that dictation (audio thread + UI + engine) otherwise attracts |
| Speech engine | whisper.cpp via prebuilt XCFramework (`binaryTarget`, pinned release + checksum) | Owner's choice; ggml model files match the sizes in the design; Metal included; no C compilation in CI |
| Style LLM | llama.cpp via prebuilt XCFramework, GGUF | Same ggml family: one ModelStore, one download/verify path |
| Project definition | XcodeGen `project.yml`; `.xcodeproj` generated and gitignored | Readable YAML, no pbxproj merge conflicts, easy for agents to edit; CI runs `brew install xcodegen` |
| Logic vs app | All logic in SwiftPM package `VoxFlowKit`; app target is a thin shell | Logic tests run with `swift test`, no Xcode UI; MCP and app share code |
| Storage | SQLite via GRDB, file encrypted with a key held in the Secure Enclave / Keychain | SwiftData on macOS 15 fights strict concurrency and offers no at-rest encryption story |
| Audio decode | AVFoundation (`AVAudioFile` + `AVAudioConverter`) → 16 kHz mono Float32 | No ffmpeg binary; one conversion point; typed errors for unsupported/corrupt files |
| Branching | GitFlow: `develop` integration, `feature/*`, `release/*`, `hotfix/*` | Owner's requirement; `master` always releasable |
| Attribution | Commits and PRs authored solely by the repository owner | Owner's requirement; no AI trailers or footers |
| Delegation | Fable orchestrates; bounded work goes to Sonnet/Haiku agents | Owner's requirement; rational token use |

## 3. Repository layout

```
v2/
  .gitignore                  # detailed, grouped (Xcode, SPM, DerivedData, models, secrets)
  project.yml                 # XcodeGen → VoxFlow.xcodeproj (ignored); scheme "VoxFlow"
  VoxFlow/                    # app target: SwiftUI + AppKit bridges, assembles screens only
    App/                      # @main, MenuBarExtra, window scenes, AppDelegate (hotkeys, Dock drop)
    Onboarding/ FlowBar/ MenuBar/ MainWindow/ Settings/
    Design/                   # tokens: accent palette, HUD material, sizes and timings from 3d
  VoxFlowTests/               # app-layer tests (view models, navigation)
  VoxFlowKit/                 # SwiftPM package, all logic, no SwiftUI
    Package.swift
    Sources/
      VoxFlowCore/            # domain types, settings, errors, protocols; imports Foundation only
      VoxFlowAudio/           # file decode → 16 kHz mono; mic capture; RMS for the waveform
      VoxFlowSpeech/          # SpeechEngine protocol impl: WhisperCppEngine (actor)
      VoxFlowModels/          # ModelCatalog, ModelStore (download/resume/verify/free-space/remove)
      VoxFlowFiles/           # FileQueue, transcript writers, export
      VoxFlowDictation/       # FB state machine: hotkey timing, silence stop, insertion policy
      VoxFlowStorage/         # History/Dictionary/Snippets/Styles on GRDB, encryption
      VoxFlowStyling/         # TextStyler protocol; RuleStyler now, LlamaStyler in phase 5
      VoxFlowMCP/             # loopback HTTP MCP, token, client approval, path policy
    Tests/<Module>Tests/      # Swift Testing; fakes for every protocol
  design/                     # VoxFlow.dc.html + support.js (the spec)
  docs/adr/                   # v2 ADRs, own index starting at 001
  docs/superpowers/specs/     # this document and later specs
  README.md
```

**Boundary rules.** `VoxFlowCore` imports only Foundation. Modules talk through protocols
declared in Core (`SpeechEngine`, `AudioSource`, `AudioDecoding`, `ModelDownloading`,
`TextStyler`, `TextInserter`, `Clock`) so each test replaces its neighbours with fakes.
The app imports modules; modules never import the app. One module = one folder = one test
target. A file past ~300 lines is a signal to split.

## 4. Engine and models

**Audio.** Internal format is 16 kHz mono Float32. `AudioDecoder` reads any container
AVFoundation can open (MP3, WAV, M4A, AAC, FLAC, AIFF, MP4, MOV) and converts in one step;
unsupported type and decode failure are distinct errors (MW-06x). `MicrophoneSource`
wraps `AVAudioEngine` with an input tap, publishes sample chunks and RMS (14-bar waveform),
and reports device changes (ST-04n) and exclusive use by another app (FB-07 variant).

**Speech.** `SpeechEngine` (Core protocol): `load(model:)`, `detectLanguage(samples:) ->
(code, confidence)`, `transcribe(samples:, options:) -> AsyncThrowingStream<SegmentEvent, Error>`
where events are partial/final segments with start/end/text/confidence and progress.
`WhisperCppEngine` is an `actor` over the whisper.cpp XCFramework. Options exposed: language
or auto (confidence < 0.6 surfaces as low-confidence, chip "EN?"), thread count, initial
prompt built from Dictionary words, no-speech threshold. Dictation longer than 60 s is
processed in windows so text streams while speaking; whether that is viable at
large-v3-turbo speed is measured by the phase-1 spike; the fallback is batch processing
on release.

**Models.** `ModelCatalog` is code: id, display name, size, languages, source URL
(HuggingFace `ggerganov/whisper.cpp` and the Qwen GGUF repo), SHA-256, role (speech or
style), default flag. Files live in `~/Library/Application Support/VoxFlow/Models`.
`ModelStore` implements exactly the design's states: free-space check before start
(size + 500 MB, SYS-DISK), resumable download with pause/offline (ONB-04a, ST-03o, MB-02),
checksum verification before "Installed" (ST-03v), remove with default-switch rule and
"only installed model cannot be removed" (ST-03d), files deleted manually → "Not installed"
with no automatic re-download. No background update checks; network only on Download.

**Phase-1 spike (throwaway).** A 50-line executable loads large-v3-turbo, transcribes a
30 s WAV and prints load time, real-time factor and peak memory on the owner's Mac. Result
decides streaming-vs-batch dictation and whether small should be the default on 8 GB Macs.

## 5. Data and storage

- One GRDB database `~/Library/Application Support/VoxFlow/voxflow.sqlite`; tables
  `dictations` (text, raw transcript, app, style, language, duration, words, created_at),
  `dictionary`, `snippets`, `app_style_overrides`, `mcp_clients`. Audio is never stored.
- At-rest encryption: SQLCipher-style page encryption is not required by the design; the
  design says "Key stored in the Secure Enclave". Implementation: database file inside an
  encrypted container is overkill; instead each `dictations.text/raw` column is encrypted
  with AES-GCM using a key wrapped by a Secure Enclave key (CryptoKit). Toggle in Privacy.
- Retention: delete after 30 days (configurable) runs at launch and daily.
- Settings via `UserDefaults` behind a `Settings` type in Core with typed keys.
- Access token for MCP in the Keychain.

## 6. Phases, branches, promotion

GitFlow: `master` (released, tagged) · `develop` (integration) · `feature/<issue>-<slug>`
→ PR into `develop` · `release/x.y.z` → `master` + tag, merged back · `hotfix/*` from
`master`. Branch `v1` archives the .NET code.

| # | Phase | User-visible result | Issue |
|---|---|---|---|
| 0 | Scaffold, CI, .gitignore, ADR-001 | Empty window with sidebar, menu bar item, green CI | #107 |
| 1 | Engine: decode, whisper.cpp, ModelStore, spike | Nothing in UI; tests + performance numbers | #108 |
| 2 | Files: queue, writers, result view, Files page, Settings › Models | Drop a file → transcript. **Promotion gate** | #109 |
| 3 | Dictation: capture, fn hotkey, Flow Bar, insertion, onboarding, History storage | Core product scenario | #110 |
| 4 | Rest of main window and all Settings, menu bar, notifications, rule-based styles | Full design minus LLM and MCP | #111 |
| 5 | Style cleanup on llama.cpp (Qwen2.5 3B), Re-style | Formal / Casual / Very casual | #112 |
| 6 | MCP server | Claude Desktop / Cursor connect | #113 |
| 7 | Release: signing, notarization, .dmg, GitHub Release | Installable image | #115 |

**Promotion (after phase 2).** `release/2.0.0` from `develop`: move `v2/` to the repository
root, delete the .NET tree, rename `ci-v2.yml` → `ci.yml` and `codeql-v2.yml` →
`codeql.yml`, rewrite `README.md`, bump version; merge to `master`, tag `v2.0.0`, merge
back to `develop`. Phases 3–7 ship as v2.1, v2.2 … through `release/` branches.

## 7. Testing and CI

- **Unit (primary).** Swift Testing in `VoxFlowKit`; every module tested with fakes of its
  neighbours; TDD (failing test first). No model files, no network, no UI.
- **Integration.** Tests tagged `RequiresModel` run real whisper.cpp on a short fixture WAV;
  skipped with a printed reason when the model is absent (CI has none, the owner's Mac does).
- **UI.** Two happy paths only: drop file → transcript; hold fn → text inserted. Everything
  else in the UI is covered through view models in unit tests.
- **CI.** `ci-v2.yml` on `macos-15`: select Xcode 26.x, `brew install xcodegen`,
  `xcodegen generate`, `xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`,
  cache SPM + DerivedData, upload xcresult. `codeql-v2.yml`: same build under CodeQL Swift.
  Triggers: PRs into `develop`, pushes to `develop`/`master`, paths `v2/**`.
  The v1 workflows keep running for the .NET tree with `paths-ignore: v2/**` until promotion.

## 8. Process for one phase

1. Fable writes the phase brief in the issue: interfaces, tests, acceptance criteria.
2. `feature/<issue>-<slug>` from `develop`.
3. Work is delegated per module: Sonnet agents implement against the brief with TDD;
   Haiku agents do mechanical edits. Independent modules run in parallel.
4. Fable reviews, runs the full local suite, fixes.
5. PR into `develop` using the repository template; fine-grained Conventional Commits
   authored by the owner.
6. Owner reviews and merges; Fable closes the issue with ticked criteria and a summary.
7. Short "what we learned" note for the owner (teaching goal).

## 9. Risks

- whisper.cpp large-v3-turbo may be too slow for streaming dictation on some Macs → spike
  in phase 1; batch fallback; small model suggested on 8 GB Macs.
- Accessibility insertion is app-dependent (Electron apps, secure fields) → clipboard
  fallback is a first-class state (FB-04b), not an error.
- XCFramework releases move fast → versions pinned in `Package.swift`; updating is a
  deliberate `chore:` PR with the checksum.
- macOS 15 vs 26 SDK differences → CI pins Xcode 26.x to match the owner's machine;
  deployment target stays 15.0.
