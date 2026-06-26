# Runbook — Local Speaker Labeling

> ADR: [ADR-024 Local Speaker Labeling Pipeline](../adr/024-local-speaker-labeling-pipeline.md)
> Delivery plan: [docs/delivery/local-speaker-labeling/](../delivery/local-speaker-labeling/)
> Scope: operational guide for enabling, running, and troubleshooting the speaker-labeling enrichment on a developer machine.

This runbook is the landing page for anyone who wants to use or diagnose VoxFlow's optional speaker-labeling feature. It covers the first-run setup for each `IPythonRuntime` mode, how to turn the feature on from each host, what a successful run looks like, and how to recover from the four most common failure modes.

---

## 1. What speaker labeling does

Speaker labeling augments a VoxFlow transcript with `Speaker A` / `Speaker B` / ... prefixes per word or per turn. The enrichment runs a local [pyannote.audio](https://github.com/pyannote/pyannote-audio) diarization model in a Python child process and merges its speaker time segments with the word-level timestamps Whisper.net already produces. Everything happens on-device — no audio, no transcript, and no speaker data leaves the machine. See ADR-024 for the design rationale and the sidecar JSON contract.

The feature is **off by default**. Turning it on for a run writes two artifacts side by side: the existing `.txt` / `.md` / `.srt` / `.vtt` / `.json` transcript (unchanged shape) and a `.voxflow.json` companion that carries the structured speaker roster, per-word assignments, and derived turns.

---

## 2. Prerequisites

| Requirement | Why | Notes |
|---|---|---|
| Python 3.10+ | pyannote.audio 3.3.2 requires it. | 3.12 is the practical ceiling on Intel Mac (no torch wheels for 3.13 on x86_64). |
| ~1.5 GB free disk | pyannote models (~300 MB) + torch/torchaudio/numpy wheels in the managed venv. | Venv lives under `~/Library/Application Support/VoxFlow/python-runtime/` on macOS. |
| Hugging Face account + access token | pyannote pretrained pipelines are gated. You must accept the model license before the first download succeeds. | [Create a token](https://huggingface.co/settings/tokens) and accept the licenses for `pyannote/speaker-diarization-3.1` **and** `pyannote/segmentation-3.0` (the required dependency). Set `HUGGING_FACE_HUB_TOKEN=<token>` in the shell before enabling the feature. |
| pyannote model license accepted | Without license acceptance the HF API returns 403 on first download and the sidecar fails with a diagnostic pointing at the license page. | See the model card at <https://huggingface.co/pyannote/speaker-diarization-3.1>. |

**Licensing note.** pyannote pretrained models are distributed under CC BY-NC-SA 4.0, which permits non-commercial use. VoxFlow's Phase 1 delivery is non-commercial; if that changes a separate license agreement with pyannote/CNRS is required. ADR-024's "Trade-offs accepted" section records this explicitly.

---

## 3. First-run setup — `ManagedVenv` mode (default)

`ManagedVenv` is the default `pythonRuntimeMode` and what fresh users hit first. VoxFlow creates a venv under `~/Library/Application Support/VoxFlow/python-runtime/` and installs the pinned requirements from [src/VoxFlow.Core/Resources/python-requirements.txt](../../src/VoxFlow.Core/Resources/python-requirements.txt). The host needs `python3` on `PATH` only during the one-time bootstrap; after that the venv's interpreter is used exclusively.

### Steps

1. Install Python 3.10+ and confirm it resolves:
   ```bash
   python3 --version
   ```
   On Apple Silicon with Homebrew: `brew install python@3.12`. On Intel Mac pin to `python@3.12` — 3.13 has no torch wheels for x86_64.
2. Export the Hugging Face token in the shell that will launch VoxFlow (Desktop, CLI, or MCP server):
   ```bash
   export HUGGING_FACE_HUB_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxx
   ```
   Accept the licenses on the model cards for `pyannote/speaker-diarization-3.1` and `pyannote/segmentation-3.0` with the same HF account.
3. Enable the feature in config and start a transcription — the first run bootstraps the venv:
   - `transcription.speakerLabeling.enabled: true` in the host's `appsettings.json`, **or**
   - CLI `--speakers`, **or**
   - MCP `transcribe_file` call with `enableSpeakers: true`, **or**
   - Desktop Ready-screen toggle.

On Desktop the first run surfaces progress through the `VenvBootstrapStage` stages rendered in the Running view. On CLI the same stages are logged via the structured progress stream. Typical first-run cost: a few minutes of wheel downloads followed by a one-time pyannote model fetch.

### What the first run writes

| Path | Contents |
|---|---|
| `~/Library/Application Support/VoxFlow/python-runtime/` | The managed venv (created by `ManagedVenvRuntime.CreateVenvAsync`). |
| `~/.cache/huggingface/hub/` (or `$HF_HOME/hub/`) | pyannote model weights, ~300 MB, fetched once then cached. |
| `~/Documents/VoxFlow/output/<name>.voxflow.json` (Desktop) or the configured output path (CLI/MCP) | The speaker-aware structured artifact. |

Subsequent runs skip the venv bootstrap and the model download, so only inference time is paid.

---

## 4. First-run setup — `SystemPython` mode (escape hatch)

`SystemPython` is intended for CI and for developers who already manage a Python environment. It shells out to whatever `python3` resolves on `PATH` and does **not** create or manage a venv for you.

### Steps

1. Install Python 3.10+ (same floor as ManagedVenv).
2. Install the pinned requirements into the environment you want VoxFlow to use:
   ```bash
   pip install -r src/VoxFlow.Core/Resources/python-requirements.txt
   ```
   Prefer a dedicated venv you create and activate yourself — polluting the system site-packages is not supported.
3. Export `HUGGING_FACE_HUB_TOKEN` and accept the model licenses as in ManagedVenv step 2.
4. Set `transcription.speakerLabeling.pythonRuntimeMode: "SystemPython"` in the host's config alongside `enabled: true`.

### Why SystemPython is not the default

Packaging portability — ManagedVenv owns the full dependency closure and keeps runtime behavior reproducible across machines. SystemPython is the dev/CI escape hatch called out in ADR-024; prefer ManagedVenv for anything a user touches directly.

---

## 5. First-run setup — `Standalone` mode

`Standalone` is the `python-build-standalone`-based bundled runtime envisioned by ADR-024 and tracked in Phase 3 as **P3.5**. As of 2026-04-19 the spike has not concluded, so Standalone is **not yet shipped**. Setting `pythonRuntimeMode: "Standalone"` today resolves `PythonRuntimeMode.Standalone` at config-binding time but no runtime is wired to it — enrichment will fail preflight with a clear diagnostic.

When the spike concludes:

- **Go path** — P3.5 lands `StandaloneRuntime` plus a bundled interpreter tree. This section will be rewritten to describe where the bundle lives and how to configure `pythonRuntimeMode: "Standalone"` as the preferred user mode.
- **No-go path** — P3.5 lands a "close the loop" PR that removes `Standalone` from the accepted `PythonRuntimeMode` values and this section is replaced with a single sentence pointing at the ADR decision note.

Until then, use `ManagedVenv` (default) or `SystemPython` (escape hatch).

---

## 6. Enabling the feature from each host

"Host override wins over config default" is the consistent rule across all four surfaces. The per-request override does **not** mutate the loaded config.

### Desktop

Toggle **Enable speaker labeling** on the Ready screen before choosing a file. The toggle forwards through `TranscribeFileRequest.EnableSpeakers`; un-checking it for a single run does not disable the feature in `appsettings.json`.

### CLI

```bash
dotnet run --project src/VoxFlow.Cli -- --speakers                          # force on
dotnet run --project src/VoxFlow.Cli -- --speakers=false                    # force off
dotnet run --project src/VoxFlow.Cli -- --no-speakers                       # force off (alias)
dotnet run --project src/VoxFlow.Cli -- --help                              # show flag list
```

Conflicting flags resolve left-to-right (last writer wins). Unknown flags print a diagnostic naming the offending token and exit with code **2** (distinct from startup-validation failure = 1). If you prefer the config-level switch, set `transcription.speakerLabeling.enabled: true` in `appsettings.json`.

### MCP

The `transcribe_file` tool exposes an optional `enableSpeakers` boolean parameter:

```jsonc
{
  "name": "transcribe_file",
  "arguments": {
    "inputPath": "/abs/path/to/interview.m4a",
    "enableSpeakers": true
  }
}
```

`null` / omitted uses the server's configured default from `appsettings.json`. `true` / `false` override `transcription.speakerLabeling.enabled` for that single request. See [src/VoxFlow.McpServer/Tools/WhisperMcpTools.cs](../../src/VoxFlow.McpServer/Tools/WhisperMcpTools.cs) for the parameter's `[Description]` attribute.

### Server / host-wide default

All three hosts resolve the same `transcription.speakerLabeling` config block from the active `appsettings.json`:

```jsonc
"speakerLabeling": {
  "enabled": false,                        // host-wide default; per-request flags override
  "timeoutSeconds": 600,                   // sidecar process timeout; diarization of long audio can run for minutes
  "pythonRuntimeMode": "ManagedVenv",      // "ManagedVenv" | "SystemPython" | "Standalone" (see §5)
  "modelId": "pyannote/speaker-diarization-3.1"
}
```

`appsettings.example.json` ships this block with Phase-1 defaults. JSON has no comments — see `SpeakerLabelingOptions` in [src/VoxFlow.Core/Configuration/SpeakerLabelingOptions.cs](../../src/VoxFlow.Core/Configuration/SpeakerLabelingOptions.cs) for the validated field semantics.

---

## 7. What a successful run looks like

### Progress output (CLI, speaker-labeling enabled)

```
Transcription [████████████████████████████████] 100.0%  0:22  [English]  done
Diarization   [████████████████████████████████] 100.0%  4:20  done
Merge         [████████████████████████████████] 100.0%  4:45  Complete
```

The three phases are sequential by design: Whisper inference → pyannote diarization sidecar → in-process speaker merge. Diarization dominates the wall-clock budget — expect roughly 20–25% of audio duration per minute on Apple Silicon, more on Intel Mac. The 600 s default `timeoutSeconds` is sized for ~40-minute recordings; raise it for longer files.

### `.voxflow.json` excerpt (two-speaker interview)

```jsonc
{
  "version": 1,
  "speakers": [
    { "id": "A", "displayName": "Speaker A" },
    { "id": "B", "displayName": "Speaker B" }
  ],
  "words": [
    { "start": 1.20, "end": 1.50, "text": "Hello", "speakerId": "A" },
    { "start": 1.50, "end": 1.90, "text": "how",   "speakerId": "A" },
    { "start": 3.10, "end": 3.40, "text": "I'm",   "speakerId": "B" }
  ],
  "turns": [
    { "speakerId": "A", "startTime": 1.20, "endTime": 2.40, "words": [ /* ... */ ] },
    { "speakerId": "B", "startTime": 3.10, "endTime": 3.80, "words": [ /* ... */ ] }
  ]
}
```

The primary text output (`.txt` / `.srt` / `.vtt` / `.md` / `.json`) remains unchanged in shape. The `.voxflow.json` companion is what Desktop's review screen loads to populate the speaker roster rename UI.

### Single-speaker case

If pyannote detects only one speaker, the enrichment still succeeds and the result carries an informational note ("Only one speaker detected."). See ADR-024 "Automatic speaker count detection" for the full policy.

---

## 8. Troubleshooting — "Python runtime not found"

Symptom: `IValidationService` reports an enrichment-disabled warning at startup, or the first run bails with `PythonRuntimeStatus.NotReady`. See `SystemPythonRuntime.GetStatusAsync` / `ManagedVenvRuntime.GetStatusAsync` in [src/VoxFlow.Core/Services/Python/](../../src/VoxFlow.Core/Services/Python/) for the exact status text.

Checklist:

1. `python3 --version` from the same shell that launches VoxFlow — must print `3.10` or newer. If the binary is missing, install it (Homebrew `python@3.12`, or the official macOS installer from python.org).
2. If ManagedVenv mode reports `Managed venv not yet created`, that is expected before the first run and auto-bootstraps. If it recurs after a successful bootstrap, the venv was deleted or corrupted — `rm -rf ~/Library/Application Support/VoxFlow/python-runtime/` and let VoxFlow rebuild it.
3. If SystemPython mode reports the interpreter below 3.10, either upgrade the default `python3` or switch `pythonRuntimeMode` to `ManagedVenv`, which brings its own.
4. On Intel Mac, Python 3.13 has no torch wheels. Pin to 3.12 and retry.

---

## 9. Troubleshooting — "pyannote model download failed"

Symptom: the sidecar returns an error envelope whose `error` field contains `Diagnostic:` lines about the HF token or cache state. The diagnostic is produced by `_diagnose_none_pipeline` inside [src/VoxFlow.Core/Resources/voxflow_diarize.py](../../src/VoxFlow.Core/Resources/voxflow_diarize.py); it distinguishes four concrete failure modes.

| Diagnostic hint | Root cause | Fix |
|---|---|---|
| "HUGGING_FACE_HUB_TOKEN and HF_TOKEN are both unset" | Token isn't reaching the child process. | Export `HUGGING_FACE_HUB_TOKEN=<token>` in the shell that launches the host, then retry. |
| "HF token present (prefix=...)" but `model_info` probe fails with "401 Unauthorized" | Token is wrong or revoked. | Regenerate at <https://huggingface.co/settings/tokens>. |
| `model_info` probe fails with "403 Forbidden" on `pyannote/speaker-diarization-3.1` | Top-level model license not accepted. | Visit <https://huggingface.co/pyannote/speaker-diarization-3.1>, click **Agree and access repository** with the HF account that owns the token. |
| "Cached top-level model: True. Cached pyannote/segmentation-3.0: False" | Segmentation dependency license not accepted. | Visit <https://huggingface.co/pyannote/segmentation-3.0> and accept. The segmentation model is a silent dependency; without it the pipeline loads to `None`. |

Force a fresh download by deleting the relevant cache folder:

```bash
rm -rf ~/.cache/huggingface/hub/models--pyannote--speaker-diarization-3.1
rm -rf ~/.cache/huggingface/hub/models--pyannote--segmentation-3.0
```

`HF_HUB_CACHE` / `HF_HOME` take precedence over the default path if set — `CompositionSpeakerLabelingPreflight` checks both.

---

## 10. Troubleshooting — "Sidecar exited with code N"

Symptom: a `DiarizationSidecarException` is logged by `PyannoteSidecarClient`, or the transcript result carries an `EnrichmentWarnings` entry containing the stderr tail. Transcription still succeeds — the non-speaker `.txt` is produced with a warning instead of a hard failure (ADR-024, "Failure modes").

Reproduce manually to see the full stderr:

```bash
# Use whichever interpreter the failing runtime mode resolves. ManagedVenv:
~/Library/Application\ Support/VoxFlow/python-runtime/bin/python3 \
  src/VoxFlow.Core/Resources/voxflow_diarize.py <<'JSON'
{"version": 1, "wavPath": "/absolute/path/to/normalized.wav"}
JSON
```

Common causes:

- **`ModuleNotFoundError`** — the venv was built with a mismatched requirements file. Delete the venv and rebuild (`rm -rf ~/Library/Application Support/VoxFlow/python-runtime/` then re-enable the feature). The Phase 1 requirements pins torch to `>=2.2,<3`, numpy to `<2`, and `huggingface_hub<0.32` — out-of-tree substitutions break pipeline load.
- **Stdout corruption** — if the error complains that stdout was not parseable JSON, a library printed a banner on fd 1. The sidecar already stashes fd 1 before heavy imports (`os.dup2(2, 1)`); report this as a bug with the stderr tail attached.
- **Crash during inference** — typically out-of-memory on very long audio. Shorten the input, raise the system's available RAM, or switch runtime mode.

When the issue is reproducible, file a bug with: the sidecar stderr tail, the host's runtime mode, the Python version, the audio duration, and whether it is a fresh venv.

---

## 11. Troubleshooting — "Sidecar timed out"

Symptom: `DiarizationSidecarException` whose message mentions the timeout, and `EnrichmentWarnings` on the transcript result notes that speaker labeling was not applied.

`transcription.speakerLabeling.timeoutSeconds` governs this. The default is **600 seconds** (10 minutes), sized for ~40-minute recordings on Apple Silicon. Raise it for long files:

```jsonc
"speakerLabeling": {
  "enabled": true,
  "timeoutSeconds": 1800,
  "pythonRuntimeMode": "ManagedVenv",
  "modelId": "pyannote/speaker-diarization-3.1"
}
```

Rules of thumb:

- Apple Silicon: diarization runs at ~20–25% of real time after model load. A 40-minute file takes ~8–10 minutes.
- Intel Mac (x86_64): 1.5–2× slower; budget accordingly. Expect `pyannote.audio 3.3.2` to be the ceiling (torch dropped macOS x86_64 at 2.3).
- First run of a session is slower than subsequent runs because pyannote loads and warms the model.

If you hit the timeout consistently, raise `timeoutSeconds` rather than fighting it with retries — a timed-out enrichment is always skipped, not resumed.

---

## 12. Running the `RequiresPython` test suite locally

Phase 1 integration tests that drive a real Python sidecar are gated behind both an xUnit trait and an environment variable so they stay opt-in on machines without the full pyannote stack.

```bash
export VOXFLOW_RUN_REQUIRES_PYTHON_TESTS=1
export HUGGING_FACE_HUB_TOKEN=<token>
dotnet test VoxFlow.sln --filter "Category=RequiresPython"
```

Without `VOXFLOW_RUN_REQUIRES_PYTHON_TESTS=1` set, every `[Trait("Category", "RequiresPython")]` test calls `Skip.IfNot(...)` and the filter run reports them as skipped, not failed. See [tests/VoxFlow.Core.Tests/Services/Diarization/PyannoteSidecarClientIntegrationTests.cs](../../tests/VoxFlow.Core.Tests/Services/Diarization/PyannoteSidecarClientIntegrationTests.cs) and [tests/VoxFlow.Core.Tests/Services/Python/SidecarScriptContractTests.cs](../../tests/VoxFlow.Core.Tests/Services/Python/SidecarScriptContractTests.cs) for the exact gate.

Run this suite before merging any PR that touches sidecar code, diarization, or the Python runtime abstractions. Fixtures live under [tests/fixtures/sidecar/](../../tests/fixtures/sidecar/).

---

## 13. Known limitations and non-goals

The feature is intentionally narrow for Phase 1/2/3. See ADR-024 "Not in initial scope" and the delivery README's "Out of scope" list for the full picture, and [docs/delivery/local-speaker-labeling/README.md](../delivery/local-speaker-labeling/README.md) for where the boundary lives. Highlights:

- No arbitrary speaker identification by real name — the rename UI updates `displayName` only.
- No cross-session speaker recognition.
- No cloud diarization fallback — local-only is load-bearing on VoxFlow's privacy principle.
- No manual speaker count constraint (`maxSpeakers`). Detection is unconstrained.
- No word-level manual editing UI. Turn-level review only.
- No performance benchmarks asserted in CI; the numbers in §11 are guidance, not a contract.
- `Standalone` runtime mode is reserved but not yet shipped (§5).

---

## 14. Changelog

- **2026-04-19** — Runbook introduced as part of Phase 3 (P3.3). Covers ManagedVenv + SystemPython modes, the four HF failure diagnostics surfaced by `voxflow_diarize.py`, the `VOXFLOW_RUN_REQUIRES_PYTHON_TESTS` opt-in, and the CLI/MCP/Desktop enablement paths shipped in P3.1 / P3.2 / P2.2. `Standalone` mode is documented as deferred pending the `python-build-standalone` spike outcome.

---

## Appendix — speaker-labeling diagnostic codes

When speaker labeling cannot run, VoxFlow surfaces a **stable diagnostic code** instead of a raw Python/pyannote error. Codes appear in `EnrichmentWarnings` as `speaker-labeling: <code>: <summary> <next action>`; the raw technical detail goes to the logs. The codes are defined in [`SpeakerLabelingDiagnosticCode`](../../src/VoxFlow.Core/Models/SpeakerLabelingDiagnosticCode.cs) and produced by [`SpeakerLabelingDiagnostics`](../../src/VoxFlow.Core/Services/Diarization/SpeakerLabelingDiagnostics.cs).

| Code | Meaning | Typical next action |
|---|---|---|
| `python-not-found` | No supported Python runtime resolved | Install Python 3.10+, or use `ManagedVenv` mode |
| `python-version-unsupported` | Python is older than 3.10 | Install Python 3.10 or newer |
| `venv-missing` | Managed runtime not installed yet | Run the managed setup (§3) |
| `venv-bootstrap-failed` | Managed runtime install failed | Check disk/network, retry setup; see logs |
| `hf-token-missing` | Hugging Face token required and absent | Set `HUGGING_FACE_HUB_TOKEN` (§9) |
| `model-license-required` | Model license not accepted | Accept the license on Hugging Face (§9) |
| `model-not-cached` | Model not in local cache | Run setup with a valid token to download it |
| `runtime-not-ready` | Runtime not ready at diarization start (unclassified) | Set up the runtime, then retry |
| `process-crashed` | Sidecar stopped unexpectedly | Re-run; if it persists, see §10 |
| `timeout` | Diarization exceeded the timeout | Raise `timeoutSeconds` or use shorter audio (§11) |
| `malformed-json` | Sidecar emitted unreadable output | Reinstall the runtime; check for stdout corruption (§10) |
| `schema-violation` | Sidecar output failed schema validation | Match VoxFlow + runtime versions; report if it persists |
| `error-response-returned` | Sidecar returned an error envelope | See logs (often token/license — §9) |
| `unknown-speaker-labeling-failure` | Unrecognized failure | Check logs; report with technical detail |

The `torch-import-failed` / `pyannote-import-failed` codes are part of the contract and will be produced by the forthcoming `doctor speakers` health check. Plain transcription always continues regardless of which code is raised.
