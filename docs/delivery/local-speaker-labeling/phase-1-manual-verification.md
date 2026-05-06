# Phase 1 — Manual Verification Guide

**Parent:** [Local Speaker Labeling — Delivery Plan](README.md)
**Scope:** Verify the Phase 1 enrichment pipeline end-to-end from the CLI before approving Phase 2 / Phase 3.

This guide is written so that you can run everything yourself, on your own machine, without touching code. It covers the disabled-path regression guard (no change when the flag is off), the enabled path (venv bootstrap + real diarization), and every output the pipeline now produces.

## 0. Prerequisites

1. **Python 3.10 or newer on PATH.** The managed venv is created by shelling out to `python3 -m venv`, so `python3 --version` must succeed and report ≥ 3.10.
   ```bash
   python3 --version
   ```
2. **ffmpeg** on PATH (same as before).
3. **Hugging Face account + accepted pyannote licenses.** pyannote's pipeline is gated, and so is each of its transitive component models. You must accept **both** licenses — `Pipeline.from_pretrained` silently returns `None` if either is missing, and the sidecar will refuse to run with an actionable error. You must:
   - Create an account at https://huggingface.co/
   - Visit https://huggingface.co/pyannote/speaker-diarization-3.1 and click **Agree and access repository**
   - Visit https://huggingface.co/pyannote/segmentation-3.0 and click **Agree and access repository** (required — this is a dependency of the 3.1 pipeline and is gated separately)
   - Create a read token at https://huggingface.co/settings/tokens
   - Export it in the shell you'll run the CLI from, **before** launching:
     ```bash
     export HUGGING_FACE_HUB_TOKEN=hf_xxx_your_read_token
     ```
4. **A short test audio file** with at least two speakers (30–120 seconds is enough). A two-person voice memo works.
5. **Free disk space.** First bootstrap downloads torch + pyannote.audio and is ~2–3 GB. Budget 4 GB.

## 1. Run the full test suite first

From the repo root:

```bash
dotnet test VoxFlow.sln
```

Expected: **all tests pass.** You should see roughly:

- `VoxFlow.Core.Tests`: ≈340 passed, **7 skipped** (the skipped tests are `Category=RequiresPython` / real-sidecar integration tests that need pyannote preinstalled — they stay skipped in a clean environment)
- `VoxFlow.McpServer.Tests`: 39 passed
- `VoxFlow.Cli.Tests`: 29 passed
- `VoxFlow.Desktop.Tests`: ≈145 passed, **2 skipped** (the two `DesktopCliBundleTests` skip until the Mac Catalyst `.app` bundle is built locally — they pass once the bundle has been produced via Visual Studio for Mac or `dotnet build … -t:Run` from `src/VoxFlow.Desktop/`)

If any test **fails**, stop here and report the failure.

### 1a. Skip-count baselines and the CI gate

Tests under `[SkippableFact]` write their skip reason to the xUnit test-output sink via `LoudSkip.IfNot` / `LoudSkip.If` (see `tests/TestSupport/LoudSkip.cs`). The reason is visible regardless of `--verbosity` — look for lines like `[SKIP] python3 not available on PATH`. The CI workflow (`.github/workflows/ci.yml`) hard-fails the job if a project's `Skipped: N` summary drifts from the documented baseline:

| Job leg | Project | Expected Skipped |
|---|---|---|
| Linux `core-hosts` | `VoxFlow.Core.Tests` (with `--filter Category!=RequiresPython`) | **0** — every `[SkippableFact]` is filtered out, no remaining `[Fact(Skip=…)]` |
| Linux `core-hosts` | `VoxFlow.Cli.Tests` | **0** — no `[SkippableFact]` callsites |
| Linux `core-hosts` | `VoxFlow.McpServer.Tests` | **0** — no `[SkippableFact]` callsites |
| macOS `desktop` | `VoxFlow.Desktop.Tests` | **2** — runner Xcode forces `MtouchLink=SdkOnly`, which produces a Mac Catalyst bundle without the CLI bridge, so both `DesktopCliBundleTests` skip |
| Local full solution (`dotnet test VoxFlow.sln`, no filter) | All projects | **7 + 2 = 9** — the 7 Core `RequiresPython` tests + the 2 Desktop bundle tests |

Drift = regression. If a count changes, the LoudSkip output names exactly which guard fired; update both this baseline table and the gate in `.github/workflows/ci.yml` only when the change is intentional.

## 2. Disabled-path regression guard

The first invariant of Phase 1 is: **with `speakerLabeling.enabled=false`, nothing about the pipeline changes.**

1. Copy the CLI example settings into a working file you will edit:
   ```bash
   cp appsettings.example.json /tmp/voxflow-phase1-disabled.json
   ```
2. Edit `/tmp/voxflow-phase1-disabled.json`:
   - `transcription.inputFilePath` → your short test audio
   - `transcription.wavFilePath` → `/tmp/voxflow-phase1/disabled.wav`
   - `transcription.resultFilePath` → `/tmp/voxflow-phase1/disabled.txt`
   - Leave `speakerLabeling.enabled` at `false`
   ```bash
   mkdir -p /tmp/voxflow-phase1
   ```
3. Run the CLI pointing at this settings file:
   ```bash
   dotnet run --project src/VoxFlow.Cli -- --settings /tmp/voxflow-phase1-disabled.json
   ```
4. **Expected:**
   - Validation report **does not** contain any `Speaker labeling runtime` or `Speaker labeling model cache` check.
   - Transcription runs to completion as before.
   - `/tmp/voxflow-phase1/disabled.txt` contains the plain transcription — **no** `Speaker A:` prefixes anywhere.
   - **No** `/tmp/voxflow-phase1/disabled.txt.voxflow.json` file was written.

If you see any of: speaker prefixes in the output, a `.voxflow.json` sidecar, or validation emitting "Speaker labeling …" checks, that's a regression — stop and report it.

## 3. Enable speaker labeling

1. Duplicate the disabled settings into a new enabled settings file:
   ```bash
   cp /tmp/voxflow-phase1-disabled.json /tmp/voxflow-phase1-enabled.json
   ```
2. Edit `/tmp/voxflow-phase1-enabled.json`:
   - `transcription.resultFilePath` → `/tmp/voxflow-phase1/enabled.txt` (so you don't overwrite the disabled-path artifact)
   - `transcription.wavFilePath` → `/tmp/voxflow-phase1/enabled.wav`
   - `transcription.speakerLabeling.enabled` → `true`
   - Leave `pythonRuntimeMode` at `"ManagedVenv"` and `modelId` at `"pyannote/speaker-diarization-3.1"`.
   - Leave `timeoutSeconds` at `600`.

## 4. First run — expect venv bootstrap

On the **first** run with the flag enabled, `ManagedVenvBootstrapper` creates the managed venv and installs pyannote. This takes several minutes and several GB of download.

```bash
export HUGGING_FACE_HUB_TOKEN=hf_xxx_your_read_token
dotnet run --project src/VoxFlow.Cli -- --settings /tmp/voxflow-phase1-enabled.json
```

### 4a. Startup validation report

Before transcription starts, the validation report now includes two new checks:

- **`Speaker labeling runtime`** — on a fresh machine this will be `Warning` with a message like `Managed venv not yet created at '…/VoxFlow/python-runtime'`. That is fine — it's informational, `CanStart` stays `true`, and bootstrap runs lazily during enrichment.
- **`Speaker labeling model cache`** — on a fresh machine this will be `Warning` with `Model pyannote/speaker-diarization-3.1 is not cached and will be downloaded on first run.`

Both are warnings, not failures. Validation should still report `PASSED WITH WARNINGS`.

### 4b. Where files go

- Managed venv: `~/Library/Application Support/VoxFlow/python-runtime/` (macOS) or `%AppData%\VoxFlow\python-runtime\` (Windows). You should see a `bin/python3` or `Scripts\python.exe` after bootstrap.
- Pyannote model cache: `~/.cache/huggingface/hub/models--pyannote--speaker-diarization-3.1/` (or under `$HF_HOME/hub` / `$HF_HUB_CACHE` if you've overridden them).

### 4c. Progress reporting during enrichment

While diarization runs, the CLI progress bar should switch to a `Diarizing` stage between roughly 85% and 95%, with short stage messages coming from the sidecar (`loading model`, `running pipeline`, etc.). You'll notice the process is CPU/GPU-bound during this period.

### 4d. Timeouts and failure modes

- If your audio is long and diarization exceeds `timeoutSeconds`, the enrichment returns a warning `speaker-labeling: timed out after 600s` and the final transcript falls back to the legacy (no-speakers) output. Increase `timeoutSeconds` and retry.
- If `HUGGING_FACE_HUB_TOKEN` is missing or invalid, the sidecar fails with an auth error surfaced as an `error-response-returned` warning. The transcript still completes without speakers. Fix the token and retry.
- If bootstrap itself fails (bad pip install, out of disk), the bootstrap exception propagates; you'll see the error and nothing is written. Fix the environment and retry.

## 5. Verify the outputs

After a successful enabled run:

```bash
ls -la /tmp/voxflow-phase1/
```

You should see both `enabled.txt` **and** `enabled.txt.voxflow.json`.

### 5a. Primary output (`.txt`)

```bash
cat /tmp/voxflow-phase1/enabled.txt
```

Expected shape:

```
Speaker A: <first speaker's sentence>
Speaker B: <second speaker's sentence>
Speaker A: <…>
```

Every line is prefixed with `Speaker <Id>: ` — never a line without a speaker.

### 5b. `.voxflow.json` sidecar

```bash
cat /tmp/voxflow-phase1/enabled.txt.voxflow.json | python3 -m json.tool | head -40
```

Expected: an object with `metadata` (schema version, diarization model id, sidecar version), a `speakers` array, and a `turns` array. Each turn has `speakerId`, `startTime`, `endTime`, and a `words` array. The file round-trips against [`docs/contracts/voxflow-transcript-v1.schema.json`](../../contracts/voxflow-transcript-v1.schema.json) — the unit tests cover this automatically, so you don't need to revalidate manually, but you're welcome to:

```bash
# Optional — any CLI JSON-schema validator works
```

### 5c. Other formats

Try the other formats by changing `transcription.resultFormat` in the settings file and re-running. Expected rendering:

| Format | What to look for |
|--------|------------------|
| `txt` | `Speaker A: …` prefix on each turn line |
| `md` | `**Speaker A:** …` bolded prefix per turn |
| `json` | Top-level `speakerTranscript` field present; legacy fields unchanged |
| `srt` | Each cue's text prefixed with `Speaker A: `; timestamps unchanged from the no-speakers path |
| `vtt` | Each cue's text wrapped with `<v Speaker A>…` WebVTT voice tag |

For each format, re-run the same pipeline with `speakerLabeling.enabled=false` as a control and diff the two — everything non-speaker should be byte-identical.

## 6. Second run — expect fast path

Run the same enabled command again:

```bash
dotnet run --project src/VoxFlow.Cli -- --settings /tmp/voxflow-phase1-enabled.json
```

Expected differences from the first run:

- Validation report now shows **`Speaker labeling runtime` = Passed** with `Python <version> at …/VoxFlow/python-runtime/bin/python3`.
- **`Speaker labeling model cache` = Passed** because pyannote is in `~/.cache/huggingface/hub/`.
- No bootstrap phase — enrichment starts immediately.
- Total wall time drops to roughly `whisper runtime + pyannote inference` with no downloads.

## 7. Switch to SystemPython (optional)

If you want to confirm the `SystemPython` mode also works (assuming your system `python3` already has pyannote installed):

1. In your enabled settings file, change `speakerLabeling.pythonRuntimeMode` to `"SystemPython"`.
2. Re-run the CLI.

Expected: validation's `Speaker labeling runtime` check reports the system interpreter path, and enrichment runs through `SystemPythonRuntime` instead of the managed venv. If system `python3` lacks pyannote, you'll get a sidecar `schema-violation` or `error-response-returned` warning — fall back to `ManagedVenv`.

The `Standalone` mode is deliberately not supported in Phase 1 and surfaces a warning: `runtime mode Standalone is not yet supported in Phase 1`.

## 8. What Phase 1 does **not** do

Before you test Phase 2 / 3, know these are deliberately deferred:

- **Desktop UI** — Ready-screen toggle, colored speaker rendering on the completion screen. None of that is wired yet; Phase 2 adds it.
- **CLI `--speakers` arg and MCP `enableSpeakers` tool parameter** — Phase 3. Today the only way to flip the flag is in `appsettings.json`.
- **Standalone runtime (python-build-standalone bundle)** — Phase 3, conditional on the ADR-024 spike.
- **Speaker renaming / colored palettes / Okabe-Ito** — display-only, Phase 2.

## 9. Report back

When you finish verification, report:

- Which steps passed / which surfaced unexpected behavior.
- The exact output you saw for each format in step 5.
- Whether first-run bootstrap completed and how long it took (rough wall time is enough).
- Whether second-run fast path behaved as described in step 6.

If everything in sections 1–6 matches this document, Phase 1 is verified and we can move into Phase 2.
