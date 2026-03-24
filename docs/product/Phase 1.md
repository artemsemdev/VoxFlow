# Phase 1: Shared Core, Desktop Minimum, Packaging, and First Run

Derived from [ROADMAP.md](./ROADMAP.md). This phase combines the old foundation and first-run work into one delivery phase.

## Goal

Keep every feature currently described in `PRD.md`, move that behavior into shared services, add a macOS desktop app, package it, and make first run predictable enough that a user can install and produce a transcript without reading source code.

MCP remains supported in Phase 1, but it is not part of the Phase 1 desktop UI scope.

## Desktop UI Stack

Phase 1 should use Blazor Hybrid for the desktop UI.

Practical decision:

- first supported desktop platform: macOS
- UI technology: Blazor components
- UI implementation: HTML, CSS, and C# components
- recommended desktop host for Phase 1: .NET MAUI Blazor Hybrid

Platform note:

- Linux desktop support is not Phase 1 scope
- if Linux support becomes necessary later, `Photino.Blazor` can be evaluated then

## Must Keep From the Current Product

- startup validation
- audio conversion with `ffmpeg`
- model reuse, download, and inspection
- configured languages and language selection
- anti-hallucination decoder settings
- transcript filtering
- progress reporting
- cancellation
- plain-text result writing
- batch processing
- MCP tools, prompts, and resource access

## What To Implement

### 1. Shared Application Layer

Move the current workflow behind shared services that can be used by desktop, CLI, and MCP.

Minimum service surface:

- `ValidateEnvironment`
- `TranscribeFile`
- `TranscribeBatch`
- `InspectModel`
- `ReadTranscript`
- `GetEffectiveConfig`

Also required:

- unified progress events
- unified warning and error payloads
- cancellation support
- typed request and response DTOs

### 2. Move Current PRD Logic Out of Host-Specific Code

Refactor the current implementation so the following are not tied to the CLI entry point:

- config loading and effective config resolution
- startup validation checks
- `ffmpeg` wrapper and WAV conversion
- model provisioning and inspection
- language selection
- decoder settings
- transcript filtering
- result writing
- batch discovery and summary generation

Rules:

- no business logic in desktop view models
- no business logic in Blazor components
- no second transcription pipeline for desktop
- no console-only progress as the source of truth
- no MAUI or Blazor dependency inside the shared core

### 3. Desktop App Minimum

Build only the minimum desktop surface that is useful:

- Blazor Hybrid shell running on macOS
- environment status
- config path or settings access
- input file picker
- drag-and-drop file input (macOS table stakes)
- single-file transcription
- progress and warnings
- transcript preview
- output path and "open folder" action
- model status

Recommended first screens:

- Home or Status
- Transcribe
- Result
- Settings

Desktop-specific integrations that belong in the shell layer:

- file picker
- drag-and-drop handler (NSView drop delegate or equivalent)
- open-folder action
- clipboard support if needed
- any macOS-specific shell behavior (e.g., dock icon, app menu)

Explicitly excluded from the Phase 1 desktop UI:

- batch UI
- MCP tool list
- MCP prompt list
- MCP server start or stop controls
- MCP configuration screens
- MCP diagnostics screens
- MCP quickstart or onboarding UI

### 4. CLI and MCP Migration

Rewire existing hosts to the shared core.

CLI:

- keep the current CLI behavior and output contract
- call shared services instead of host-specific workflow code

MCP:

- keep current tools, prompts, and resource behavior
- keep path policy in the MCP host
- call shared services for actual work

### 5. Packaging and Distribution

Produce versioned, signed release artifacts for macOS.

Required:

- packaged desktop build (.app bundle inside .dmg or .pkg)
- Apple Developer ID code signing
- notarization via `notarytool` (required for Gatekeeper to allow install)
- checksums (SHA-256)
- install docs shipped with the release (not deferred to Phase 3)
- uninstall or cleanup notes
- versioned release notes

Decisions that must be explicit:

- whether `ffmpeg` is bundled or externally installed
- model storage location (`~/Library/Application Support/VoxFlow/` recommended)
- temp/output defaults
- minimum macOS version target
- whether to use Hardened Runtime (required for notarization)

Code signing notes:

- Without notarization, macOS 10.15+ users see "app is damaged" or Gatekeeper blocks
- Apple Developer ID costs $99/year but is required for distribution outside the Mac App Store
- If cost is a blocker, document the `xattr -cr` workaround in install docs and plan notarization for Phase 4

### 6. First-Run Dependency Bootstrap

Handle first-run requirements inside the product, not only in docs.

Required:

- dependency readiness check
- model download or provisioning status
- failure states for missing `ffmpeg`, missing model, unwritable directories, and invalid config
- retry path for recoverable setup failures

### 7. First-Run UX

The desktop app should show a clear state machine:

- not ready
- ready
- running
- failed
- complete

Required UI:

- actionable validation results
- one obvious path to a first transcript
- success screen with transcript preview and output location

### 8. Minimum Ship Docs

Phase 1 must ship with at least these docs alongside the release:

- install instructions (download, verify checksum, install, Gatekeeper notes)
- first-run guide (launch, environment check, first transcription)
- config reference (appsettings.json fields, defaults, overrides)
- known limitations
- uninstall instructions

These are not marketing docs. They are the minimum a user needs to install and succeed without reading source code.

### 9. Trust Baseline

Add only the trust work that directly helps product use:

- small benchmark corpus
- known limitations doc
- run detail summary showing:
  - model
  - language
  - warnings
  - output path
  - config summary

Benchmark scope should stay small and practical:

- clean speech
- noisy speech
- difficult audio likely to trigger hallucinations

### 10. Tests and Regression Gates

Preserve or add tests for:

- config loading
- startup validation
- audio conversion wrapper
- language selection
- filtering
- result writing
- batch behavior
- MCP path policy and tool behavior
- shared-service integration
- desktop smoke path

Desktop-specific smoke coverage:

- the macOS desktop app starts
- the Blazor UI loads
- validation results render
- file selection reaches the transcription workflow
- progress updates render
- success state shows output path and transcript preview

## Out of Scope

- Full transcript workspace
- Full batch desktop UI
- MCP UI, MCP setup UI, and MCP diagnostics UI inside the desktop app
- New AI workflow features
- Linux desktop support
- Windows desktop support if it slows down macOS delivery
- Reusing the Blazor UI as a separate web application in Phase 1

## Implementation Order

1. Freeze shared DTOs and effective-config shape.
2. Extract config, validation, conversion, and model services.
3. Extract the single-file transcription workflow.
4. Extract batch, inspect-model, and read-transcript services.
5. Rewire CLI to the shared core.
6. Rewire MCP to the shared core.
7. Set up Apple Developer ID and signing pipeline early (do not defer).
8. Create the macOS desktop shell with .NET MAUI Blazor Hybrid.
9. Build the Blazor UI for the minimum desktop flow including drag-and-drop.
10. Add shell adapters for file picker, drag-and-drop, open-folder, and UI state mapping.
11. Build macOS packaging (.dmg or .pkg), signing, and notarization scripts.
12. Finalize `ffmpeg` and model bootstrap behavior.
13. Implement first-run state handling in the desktop app.
14. Write install, first-run, and config docs.
15. Add the run detail summary and known limitations doc.
16. Create the minimum benchmark corpus and release gate.
17. Run regression tests across desktop, CLI, and MCP.

## Practical Risks

- Blazor components can become a second business-logic layer if state and workflow calls are not kept in services.
- MAUI-specific code can leak into the shared core if boundaries are not kept strict.
- Packaging and notarization can become the schedule driver — set up signing early.
- Drag-and-drop may require native macOS interop if Blazor WebView does not support it natively.
- First-run UX can become vague if the app does not distinguish setup failure from transcription failure.
- Batch support will regress if only the single-file path is tested.
- MCP can silently break if DTOs change without tool-level tests.

## Done When

- all current `PRD.md` features work through the shared core
- a supported macOS user can install from a release
- a macOS Blazor Hybrid desktop app can validate the environment and transcribe a file
- dependency failures are actionable
- known limitations are documented
- install and first-run docs ship with the release
- a small benchmark baseline runs before release
- CLI still works
- MCP still works
- the desktop app does not try to surface MCP features in Phase 1
- no host has its own duplicate transcription logic
