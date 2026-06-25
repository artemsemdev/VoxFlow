# Local Speaker Labeling — Delivery Plan

Delivery plan for [ADR-024: Adopt a Local Speaker Labeling Pipeline](../../adr/024-local-speaker-labeling-pipeline.md).

This document is the **scope contract** for the feature. It follows the [Adding New Scope of Work](../adding-scope.md) template and is intended to be agreed once at the beginning and rarely changed. Per-phase executable plans live next to this file in `phase-N-*.md`.

---

## Problem Statement

VoxFlow produces filtered transcripts from local audio via Whisper.net but does not identify who spoke each segment. For interview, meeting, and call-review workflows this limits the usefulness of the transcript, because a reader cannot follow turn-taking without manually labeling speakers. The product direction is local-first and privacy-first, so cloud diarization is not acceptable as the default path. This delivery introduces a local post-ASR speaker-labeling pipeline that works for every language the existing transcription pipeline supports, without sending any audio or transcript data off the user's machine.

---

## Principle Alignment Check

| Principle | Evaluation |
|---|---|
| **Local-first** | ✅ All processing runs on the user's machine. Python sidecar runs locally, models cached locally. No cloud calls after initial model download. |
| **Privacy-first** | ✅ No audio or transcript data leaves the machine. Sidecar contract passes only a WAV path across the process boundary — no text. |
| **Configuration-driven** | ✅ Feature is opt-in via `speakerLabeling.enabled` in `appsettings.json`. Existing users are not affected unless they turn it on. |
| **Failure-transparent** | ✅ Sidecar failures are treated as recoverable enrichment failures. The transcription-only pipeline still produces output with a warning attached. Preflight validation surfaces clear diagnostics for missing runtime/models. |
| **Scriptable** | ✅ Feature is reachable from CLI (`--speakers`), Desktop (Ready-screen toggle), and MCP (`enableSpeakers` parameter). Structured `.voxflow.json` artifact is consumable by automation. |

No principle is violated. No trade-off requires maintainer approval.

---

## Proposed Solution

A four-stage enrichment layered on top of the existing transcription pipeline:

1. Whisper.net remains the source of transcription and **word-level timestamps** (`WhisperToken[]`). These tokens are currently discarded by `TranscriptionFilter` — this delivery preserves them through filtering.
2. A local Python sidecar (`voxflow_diarize.py`) performs pyannote speaker diarization and returns speaker time segments via a versioned JSON contract. The sidecar is purely acoustic — no text or language processing.
3. A .NET merge service (`SpeakerMergeService`) combines Whisper word timings with diarization speaker segments, assigns a speaker to each word by time overlap, and groups words into speaker turns inside a `TranscriptDocument` model.
4. The Desktop Ready screen exposes a toggle for the feature; the completion screen renders turns with colored speaker labels (Okabe-Ito colorblind-safe palette). CLI and MCP gain access to the structured artifact and new output formatting.

The Python runtime is decoupled from the sidecar contract via an `IPythonRuntime` abstraction with three implementations, so the packaging strategy is a **deferred decision**, not a prerequisite. See _Delivery Sequence_ below.

---

## In Scope

- Preserving `WhisperToken[]` through `TranscriptionFilter` (prerequisite for everything else).
- `TranscriptDocument` model with `SpeakerInfo` roster, `TranscriptWord` with speaker references, and derived `SpeakerTurn` groups.
- Versioned sidecar JSON contract (`docs/contracts/sidecar-diarization-v1.schema.json`).
- `voxflow_diarize.py` sidecar script using pyannote.
- `IPythonRuntime` abstraction with `SystemPythonRuntime` and `ManagedVenvRuntime` implementations.
- `IDiarizationSidecar` / `PyannoteSidecarClient` process launcher.
- `SpeakerMergeService` — pure-logic merge of Whisper words and diarization segments.
- `ISpeakerEnrichmentService` orchestrator wired into the main transcription pipeline behind a config flag.
- `SpeakerLabelingOptions` configuration section.
- First-run setup flow (venv bootstrap + pyannote model download), explicit and cancellable.
- `IValidationService` preflight check for speaker labeling prerequisites.
- Updates to existing output writers (`.txt`, `.srt`, `.vtt`, `.json`, `.md`) to render `Speaker X:` prefixes when `TranscriptDocument` is present.
- New `.voxflow.json` output artifact carrying the full `TranscriptDocument`.
- Desktop Ready-screen toggle for the feature.
- Desktop completion-screen colored speaker rendering (Okabe-Ito palette).
- CLI `--speakers` flag.
- MCP `enableSpeakers` tool parameter.
- Documentation: updated `ARCHITECTURE.md`, new `docs/runbooks/speaker-labeling.md`, updated `docs/developer/setup.md`, README snippet.
- Integration test fixtures: 1-speaker (Obama, trimmed), 2-speaker (LibriCSS), 3+ speaker (LibriCSS).
- Spike: `python-build-standalone` packaging validation (parallel to Phase 0, independent outcome).

---

## Out of Scope

Explicitly excluded from this delivery to prevent scope creep. Each item is either a future enhancement or a non-goal:

- Speaker renaming / display names / review editor (Desktop is display-only for this delivery).
- Word-level manual editing UI.
- Cross-session speaker recognition.
- Cloud diarization fallback.
- Daemon-mode sidecar (per-request spawn is the v1 pattern, matching ADR-004 ffmpeg precedent).
- Manual speaker count override / `maxSpeakers` configuration.
- Benchmarks of per-language diarization quality.
- Windows and Linux Desktop packaging (scope is limited to macOS for v1; CLI remains cross-platform because it uses `ManagedVenvRuntime` or system Python).
- Arbitrary speaker identification by real names (biometric identification is a non-goal).
- Promotion of `Local-Speaker-Labeling` branch into `master` — this is a separate decision made by the user after all phases are complete.

---

## Affected Surfaces

- [x] `src/VoxFlow.Core` — new services, new models, new configuration section under `transcription`, updated `TranscriptionFilter`, updated `TranscribeFileResult`, updated output writers, new embedded `voxflow_diarize.py` resource + requirements file.
- [x] `src/VoxFlow.Cli` — new `--speakers` flag, updated help text.
- [x] `src/VoxFlow.Desktop` — new Ready-screen toggle, new completion-screen colored speaker renderer, new progress stage wiring.
- [x] `src/VoxFlow.McpServer` — new `enableSpeakers` tool parameter, updated JSON schema of the `transcribe_file` tool.
- [x] `tests/VoxFlow.Core.Tests` — new unit tests (merge, runtime, sidecar client, enrichment, validation, output writers, transcript model) **plus** the Python-gated integration tests. Integration tests live in the same project tagged `[Trait("Category", "RequiresPython")]` and are filtered on the command line; a separate `VoxFlow.EndToEndTests` project is **not** created (there is no such project in the repo today — the folder exists only as orphaned build output and is deliberately not revived).
- [x] `tests/VoxFlow.Cli.Tests` — updated argument-parsing tests for `--speakers`.
- [x] `tests/VoxFlow.McpServer.Tests` — updated tool-schema tests for `enableSpeakers`.
- [x] `tests/VoxFlow.Desktop.Tests` — new Razor component tests for the speaker renderer and the Ready-screen toggle.
- [x] `tests/TestSupport` — shared helpers (`TestSettingsFileFactory` and co.) extended if new config shapes need test-side fixtures.
- [x] `appsettings.json` and `appsettings.example.json` — new nested `transcription.speakerLabeling` section (example file must mirror the loader-compatible shape).
- [x] `docs/contracts/` — new schema files for the sidecar contract and the `.voxflow.json` artifact.
- [x] `docs/runbooks/` — new runbook for troubleshooting speaker labeling (first-run setup, model download failures, sidecar diagnostics).
- [x] `docs/adr/024-local-speaker-labeling-pipeline.md` — amendment replacing PyInstaller with python-build-standalone as the preferred packaging tool.

---

## Configuration Changes

New nested section **inside** the existing `transcription` root of `appsettings.json`. The `transcription` root is mandatory because `TranscriptionOptions.LoadFromPath` deserializes into `TranscriptionSettingsRoot { Transcription: ... }` — a `speakerLabeling` key at the top level would be silently ignored. The `transcription.speakerLabeling` path is the only supported binding location.

```json
{
  "transcription": {
    "processingMode": "batch",
    "...": "... existing settings unchanged ...",
    "speakerLabeling": {
      "enabled": false,
      "timeoutSeconds": 600,
      "pythonRuntimeMode": "ManagedVenv",
      "modelId": "pyannote/speaker-diarization-3.1"
    }
  }
}
```

- `enabled` — default `false`. When `false`, zero runtime cost; pipeline behaves identically to current.
- `timeoutSeconds` — hard timeout for sidecar process, default 600 (10 min). Applies per file.
- `pythonRuntimeMode` — one of `SystemPython` (dev/CI escape hatch), `ManagedVenv` (default for users), `Standalone` (future, from python-build-standalone spike).
- `modelId` — pyannote model identifier. Pinned so upgrades are explicit.

The same nested structure must land in `appsettings.example.json` in the same PR that introduces it, so documented examples match the loader.

CLI override: `--speakers` flag on `transcribe` / `batch` commands. Overrides `enabled` for that invocation.

MCP override: `enableSpeakers` (bool) parameter on `transcribe_file` tool. Overrides `enabled` per request.

Desktop override: Ready-screen toggle. Persists back to `appsettings.json` on change.

---

## Dependencies

**Runtime (added on first enable):**

- Python 3.10+ interpreter. User-provided in `SystemPython` mode, managed by VoxFlow in `ManagedVenv` mode (requires Python 3.10+ installed on the host to create the venv), bundled in `Standalone` mode (future).
- `pyannote.audio` ~3.x (CC BY-NC-SA 4.0 — acceptable for VoxFlow's current non-commercial scope, documented explicitly in ADR-024 and runbook).
- `torch`, `torchaudio` (transitive via pyannote).
- pyannote pretrained model weights (~300 MB), downloaded on first run to `~/Library/Caches/VoxFlow/models/` (macOS).

**Development (local developer runs, not CI):**

- Python 3.10+ available locally for the `Category=RequiresPython` trait-filtered integration tests. Default CI excludes this integration suite; run it on a developer machine before relevant PRs.
- `Xunit.SkippableFact` NuGet package (added to `VoxFlow.Core.Tests` in P0.5) — enables dynamic skip for tests that depend on sidecar availability. Without this package, xUnit has no idiomatic runtime skip mechanism.

**Nothing is added to Core nuget dependencies** — the Python side is invoked as a child process via `System.Diagnostics.Process`. No new managed dependencies enter VoxFlow.Core.

---

## Acceptance Criteria

Observable, testable outcomes that define "done" for this delivery:

1. **Zero regression for existing users.** With `speakerLabeling.enabled=false` (the default), `dotnet test` produces the same results as before this delivery, and the user-visible transcription pipeline produces byte-identical output for the same input.
2. **Enrichment produces a `TranscriptDocument`.** On each of the three integration fixtures (`obama-speech-1spk-10s.wav`, `libricss-2spk-10s.wav`, `libricss-3spk-10s.wav`), enabling the feature produces a `TranscriptDocument` with detected speaker count 1, 2, and 3 respectively (within pyannote's clustering tolerance — tests assert `>=` not `==` for multi-speaker cases to account for clustering variance).
3. **`Speaker A` / `Speaker B` ordinal labels.** First speaker to appear in the audio is labeled `A`, second `B`, etc. Order is deterministic and verified by unit tests on JSON fixtures.
4. **Merge correctness.** Unit tests on `SpeakerMergeService` cover: empty input, single-speaker, two-speaker turn boundaries, multi-speaker, overlap edge cases (word fully inside one speaker, word straddling two speakers, word not covered by any speaker — assigned to nearest).
5. **Output writers render speaker labels.** For every format (`.txt`, `.srt`, `.vtt`, `.json`, `.md`), unit tests verify that a `TranscriptDocument` with 2 speakers produces output containing `Speaker A:` and `Speaker B:` in the expected positions. Existing tests for the `null` case still pass unchanged.
6. **`.voxflow.json` roundtrip.** Writing a `TranscriptDocument` to `.voxflow.json` and reading it back produces an equal object. Schema is validated against `docs/contracts/voxflow-transcript-v1.schema.json`.
7. **Failure is non-fatal.** When the sidecar is missing, crashes, times out, or returns malformed JSON, the pipeline still produces the transcription-only output with a non-empty `EnrichmentWarnings` list and `SpeakerTranscript = null`. Unit-tested by mocking sidecar failures.
8. **Preflight validation.** `IValidationService` returns a clear diagnostic when `enabled=true` but the Python runtime is not available or the pyannote model is not cached. Unit-tested for both branches.
9. **First-run setup is explicit and cancellable.** When the user enables the feature for the first time without a prepared venv/model cache, they see an explicit prompt/progress and can cancel. Tested end-to-end on a clean machine (manual smoke check before Phase 3 completion).
10. **Desktop displays colored speaker turns.** With the feature enabled, the completion screen shows transcript turns with each speaker in a distinct color from the Okabe-Ito palette. Cycles if >8 speakers. Razor component-tested.
11. **CLI, Desktop, MCP are consistent.** The same audio file produces the same structured result across all three hosts.
12. **Integration tests pass on a machine with Python installed.** `dotnet test --filter "Category=RequiresPython"` runs the full sidecar path against real fixtures and passes. Tests are tagged with `[Trait("Category", "RequiresPython")]` on the test class (xUnit 2.9 syntax — `[Category(...)]` is MSTest and does not work in this project).
13. **ADR-024 reflects the current design.** The PyInstaller reference is replaced with python-build-standalone (this is the only ADR amendment).

### Acceptance Criteria — Evidence Audit (P3.6)

Every criterion above is linked to one concrete test, walkthrough, or artifact. Integration evidence rows require a live Python 3.10+ runtime with `pyannote.audio` and are exercised by `dotnet test --filter "Category=RequiresPython"`.

| # | Criterion | Evidence |
|---|---|---|
| 1 | Zero regression when disabled (default) | [SpeakerLabelingOptionsTests.cs](../../../tests/VoxFlow.Core.Tests/Configuration/SpeakerLabelingOptionsTests.cs) (default `Enabled=false`) + [SpeakerEnrichmentServiceTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Diarization/SpeakerEnrichmentServiceTests.cs) (`EnrichAsync_Disabled_*` short-circuits without touching runtime) |
| 2 | `TranscriptDocument` on 1/2/3-speaker fixtures | [PyannoteSidecarClientIntegrationTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Diarization/PyannoteSidecarClientIntegrationTests.cs) + [SidecarScriptContractTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Python/SidecarScriptContractTests.cs), both `[Trait("Category", "RequiresPython")]` |
| 3 | Deterministic `Speaker A` / `Speaker B` ordinals | [SpeakerMergeServiceTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Diarization/SpeakerMergeServiceTests.cs) (`Merge_SingleSpeaker_AllWordsAssignedToA`, `Merge_TwoSpeakers_AssignsByMaxTimeOverlap`) |
| 4 | Merge edge cases (empty / single / boundary / straddle / uncovered) | [SpeakerMergeServiceTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Diarization/SpeakerMergeServiceTests.cs) |
| 5 | Output writers render speaker labels (`.txt` / `.srt` / `.vtt` / `.json` / `.md`) | [OutputWriterFormatTests.cs](../../../tests/VoxFlow.Core.Tests/OutputWriterFormatTests.cs) |
| 6 | `.voxflow.json` roundtrip + schema | [VoxflowTranscriptArtifactWriterTests.cs](../../../tests/VoxFlow.Core.Tests/Services/VoxflowTranscriptArtifactWriterTests.cs); schema: [voxflow-transcript-v1.schema.json](../../contracts/voxflow-transcript-v1.schema.json) |
| 7 | Failure is non-fatal (crash / timeout / malformed JSON) | [SpeakerEnrichmentServiceTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Diarization/SpeakerEnrichmentServiceTests.cs) (sidecar-error paths → non-empty `Warnings`, `Document = null`) |
| 8 | Preflight validation | [ValidationServiceSpeakerLabelingTests.cs](../../../tests/VoxFlow.Core.Tests/ValidationServiceSpeakerLabelingTests.cs) |
| 9 | First-run setup is explicit and cancellable | [ManagedVenvBootstrapperTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Python/ManagedVenvBootstrapperTests.cs) (venv creation + pip install progress stages) + runbook walkthrough: [speaker-labeling.md](../../runbooks/speaker-labeling.md) |
| 10 | Desktop colored speaker turns (Okabe-Ito palette) | [SpeakerTranscriptViewTests.cs](../../../tests/VoxFlow.Desktop.Tests/Components/SpeakerTranscriptViewTests.cs) |
| 11 | CLI / Desktop / MCP consistent (same `ISpeakerEnrichmentService`) | DI registration: [DependencyInjectionTests.cs](../../../tests/VoxFlow.Core.Tests/DependencyInjectionTests.cs); CLI flag: [CliArgumentsTests.cs](../../../tests/VoxFlow.Cli.Tests/CliArgumentsTests.cs); MCP parameter: [TranscribeFileToolSchemaTests.cs](../../../tests/VoxFlow.McpServer.Tests/TranscribeFileToolSchemaTests.cs) |
| 12 | `Category=RequiresPython` integration suite | Two tagged classes: [PyannoteSidecarClientIntegrationTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Diarization/PyannoteSidecarClientIntegrationTests.cs), [SidecarScriptContractTests.cs](../../../tests/VoxFlow.Core.Tests/Services/Python/SidecarScriptContractTests.cs) |
| 13 | ADR-024 PyInstaller → python-build-standalone amendment landed | [024-local-speaker-labeling-pipeline.md](../../adr/024-local-speaker-labeling-pipeline.md) |

---

## Delivery Sequence

Work is split into four sequential phases. Each phase finishes with the integration branch in a working state. Detailed TDD plans live in the per-phase documents — each is written just before the phase starts, except Phase 0 which is detailed in full now.

| Phase | Document | What it delivers | State after |
|---|---|---|---|
| **Phase 0** | [phase-0-foundation.md](phase-0-foundation.md) | Contract + abstractions + merge logic + fixtures. No end-to-end wiring. | Feature code exists, is fully unit-tested, but not called from the pipeline. |
| **Phase 1** | phase-1-enrichment.md _(written before Phase 1 starts)_ | Config + orchestrator + first-run flow + output writers + `.voxflow.json`. Wire into pipeline behind flag. | CLI and MCP produce speaker-labeled output when flag is on. Desktop still shows plain transcript. |
| **Phase 2** | phase-2-desktop-ui.md _(written before Phase 2 starts)_ | Ready-screen toggle + completion-screen colored renderer + progress stage UI. | Desktop users can enable the feature and see colored speaker turns. |
| **Phase 3** | phase-3-cli-mcp-polish.md _(written before Phase 3 starts)_ | CLI flag + MCP parameter + documentation + runbook + (conditional) Standalone runtime + release prep. | Feature is documented and production-ready on the integration branch, awaiting user promotion to `master`. |

**Parallel to Phase 0:** a standalone spike validates `python-build-standalone` packaging for pyannote + PyTorch. The spike has its own issue/branch and is **not a blocker** for any phase. Its outcome feeds into Phase 3 (go/no-go for `StandaloneRuntime`).

---

## Branching Strategy

```
master
  └── Local-Speaker-Labeling        ← integration branch for this delivery
        ├── speaker-labeling/p0.1-preserve-tokens
        ├── speaker-labeling/p0.2-transcript-doc
        ├── speaker-labeling/p0.3-python-runtime
        ├── ...
        └── speaker-labeling/p3.5-release-prep
```

- **Every sub-PR targets `Local-Speaker-Labeling`, never `master`.**
- Sub-branches follow the `speaker-labeling/pN.M-short-slug` naming convention.
- The promotion of `Local-Speaker-Labeling` → `master` happens **only** when all phases are complete and the user explicitly says so. It is not part of this plan.
- CI is **not** required to run on sub-PRs. Regression is caught by mandatory local `dotnet test` runs before each `gh pr create`.
- Each sub-PR is small, focused, and reviewable in one sitting.

---

## TDD & Testing Discipline

This delivery uses test-driven development strictly:

1. **Red before green.** Every new class or method gets a failing test before any implementation code is written. No "I'll write the test after."
2. **Bottom-up.** Pure-logic classes are tested and implemented first (`SpeakerMergeService`), then their consumers. Process boundaries come last.
3. **Fixture-based unit tests.** Merge logic is exercised with pre-recorded JSON fixtures of `WhisperToken[]` and sidecar responses — **not** by running Python. This keeps 90% of tests fast, deterministic, and environment-independent.
4. **Integration tests are gated via xUnit trait.** Tests that require a real Python runtime carry `[Trait("Category", "RequiresPython")]` (xUnit 2.9 syntax; the `VoxFlow.Core.Tests` project uses xUnit 2.9.2). The standard `dotnet test` run filters them out via `--filter "Category!=RequiresPython"`; the developer runs them explicitly via `dotnet test --filter "Category=RequiresPython"`. There is no MSTest-style `[Category]` attribute or `Assert.Inconclusive` — neither exists in xUnit. For tests that need to conditionally skip based on runtime state (e.g., "sidecar binary missing on this machine"), add the `Xunit.SkippableFact` NuGet package and use `Skip.If(...)` — this is introduced as part of the first PR that needs it (P0.5).
5. **Local test runs are mandatory before PRs.** Before `gh pr create`, run `dotnet test` (and, if the PR touches integration code, `dotnet test --filter "Category=RequiresPython"`) and confirm no previously-green test has turned red. Report results in the PR body.
6. **One PR = one completed TDD cycle.** A PR that leaves code half-implemented or tests red is not merged.

See the per-phase documents for the concrete TDD sequence of each PR.

---

## Acceptance Check Before Promotion

Before the user promotes `Local-Speaker-Labeling` to `master` (outside the scope of this delivery), the following must be true:

- [x] All acceptance criteria above are satisfied and verified. Evidence table: [Acceptance Criteria — Evidence Audit (P3.6)](#acceptance-criteria--evidence-audit-p36).
- [x] `dotnet test` is fully green locally (both the default run and `dotnet test --filter "Category=RequiresPython"`, on a machine that has Python 3.10+ installed for the filtered run). P3.6 local run summary is recorded in [CHANGELOG-phase3.md](CHANGELOG-phase3.md).
- [x] All four phase documents exist and are up to date (including post-execution outcomes): [phase-0-foundation.md](phase-0-foundation.md), [phase-1-enrichment.md](phase-1-enrichment.md), [phase-2-desktop-ui.md](phase-2-desktop-ui.md), [phase-3-cli-mcp-polish.md](phase-3-cli-mcp-polish.md).
- [x] ADR-024 amendment is merged into `Local-Speaker-Labeling`: [024-local-speaker-labeling-pipeline.md](../../adr/024-local-speaker-labeling-pipeline.md) (PyInstaller → python-build-standalone).
- [x] Runbook [speaker-labeling.md](../../runbooks/speaker-labeling.md) exists and has been manually walked through at least once (landed in P3.3).
- [x] Manual smoke test has been performed on at least one real-world recording: `artifacts/input/President Obama Speech.m4a` — user-confirmed during Phase 2 desktop rollout and re-verified in P3.6.
- [ ] User has personally reviewed the full `Local-Speaker-Labeling` diff. _(Left unticked intentionally — only the user can check this box as part of the promotion decision.)_

---

## Ready for user promotion review — 2026-04-19

All four phases of ADR-024 have landed on `Local-Speaker-Labeling`. Phase 3 closes with the release-prep pass in this commit (P3.6). The branch is ready for the user to review the full diff and decide whether to promote to `master`.

**Landed sub-PRs:**

- **Phase 0 — foundation:** #13 (preserve tokens), #14 (TranscriptDocument), #15 (`IPythonRuntime` + `SystemPythonRuntime`), #16 (`ManagedVenvRuntime`), #17 (`voxflow_diarize.py` sidecar), #18 (`PyannoteSidecarClient`), #19 (`SpeakerMergeService`), #20 (audio fixtures), #21 (docs phase plans).
- **Phase 1 — enrichment:** #22 (`SpeakerLabelingOptions`), #23 (request-level override), #25 (enrichment orchestrator, output writers, `.voxflow.json`).
- **Phase 2 — desktop UI:** #24 (Ready-screen toggle + colored renderer), #26 (hotfix: CLI bridge for `EnableSpeakers` on Intel Mac), #27 (desktop redesign: three-phase rings + shared TopBar + bundled sidecar).
- **Phase 3 — CLI / MCP / docs / Standalone / release:** sub-PRs on `speaker-labeling/phase-3-cli-mcp-polish` — P3.1 CLI flags, P3.2 MCP parameter, P3.3 runbook, P3.4 architecture/setup/README, P3.5 `StandaloneRuntime`, P3.6 (this) release prep. Phase-3 PR open against `Local-Speaker-Labeling`.

**What still requires the user:**

- Open / review / merge the Phase-3 PR into `Local-Speaker-Labeling`.
- Tick the final box in [Acceptance Check Before Promotion](#acceptance-check-before-promotion) after reviewing the full `master..Local-Speaker-Labeling` diff.
- Make the `Local-Speaker-Labeling` → `master` promotion decision (intentionally out of scope for this delivery).
