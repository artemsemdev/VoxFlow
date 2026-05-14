# Error catalog

Canonical list of user-facing error messages VoxFlow can surface, plus root cause and remediation for each. The expectation is that when a user pastes an error string into an issue or asks "what does this mean?", we can point at one row in this table.

**Where each entry shows up:**
- **CLI** — written to stderr by `VoxFlow.Cli` or surfaced in `result.txt`.
- **Desktop** — shown in the failed-state view banner or in `desktop.log` under `~/Library/Application Support/VoxFlow/logs/`.
- **MCP** — returned in the JSON error envelope of a tool response.
- **All** — any host that uses `VoxFlow.Core` services.

**Reading the patterns:** the **Pattern** column is the regex / substring you can grep for in the captured output. The **Source** column points at the line that throws or constructs the message; if a message is reworded later, that's the place to update.

---

## Speaker labeling — `SidecarFailureReason` enum

Every value of [`SidecarFailureReason`](../../src/VoxFlow.Core/Models/SidecarFailureReason.cs) maps to one of the rows below. The user-visible string is built by `SpeakerEnrichmentService.FormatSidecarWarning`:
`"speaker-labeling: {kebab-reason}: {message}"`.

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `speaker-labeling: runtime-not-ready: …` | All | The configured Python runtime (system or managed venv) is missing or below the required version. | Install Python ≥ 3.10 on PATH OR let the managed venv bootstrap by running once with `transcription.speakerLabeling.pythonRuntimeMode=ManagedVenv`. See [speaker-labeling runbook](./speaker-labeling.md). | [`PyannoteSidecarClient.cs:82`](../../src/VoxFlow.Core/Services/Diarization/PyannoteSidecarClient.cs#L82) |
| `speaker-labeling: process-crashed: voxflow_diarize.py exited with code …` | All | The sidecar Python process crashed before writing a result envelope (segfault, OOM, missing dependency). | Re-run with `VOXFLOW_DEBUG_SIDECAR=1` to keep stderr in the log; inspect `desktop.log` for the exit code. Common cause: pyannote.audio not installed in the active environment. | [`PyannoteSidecarClient.cs:122`](../../src/VoxFlow.Core/Services/Diarization/PyannoteSidecarClient.cs#L122) |
| `speaker-labeling: timeout: voxflow_diarize.py did not return within …s` | All | The sidecar took longer than `transcription.speakerLabeling.timeoutSeconds` (default 600). Long audio + first-run model load is the usual culprit. | Increase `transcription.speakerLabeling.timeoutSeconds` in `appsettings.json` for longer recordings. Pre-warm the model cache by running a short job first. | [`PyannoteSidecarClient.cs:113`](../../src/VoxFlow.Core/Services/Diarization/PyannoteSidecarClient.cs#L113) |
| `speaker-labeling: malformed-json: voxflow_diarize.py wrote non-JSON to stdout: …` | All | The Python sidecar wrote text to stdout that wasn't JSON — almost always a stray `print()` in user-modified `voxflow_diarize.py` or a library writing to stdout instead of stderr. | Search the active `voxflow_diarize.py` for `print(...)`; library output must go to `sys.stderr`. If the file is the bundled one, file a bug with the stdout snippet attached. | [`PyannoteSidecarClient.cs:134`](../../src/VoxFlow.Core/Services/Diarization/PyannoteSidecarClient.cs#L134) |
| `speaker-labeling: schema-violation: voxflow_diarize.py response failed schema validation: …` | All | The sidecar produced JSON that doesn't match [`sidecar-diarization-v1.schema.json`](../contracts/sidecar-diarization-v1.schema.json). Indicates a contract drift between the .NET client and the Python script. | If you didn't modify `voxflow_diarize.py`, this is a bug — file an issue with the offending response attached. If you did, validate your modifications against the schema. | [`PyannoteSidecarClient.cs:162`](../../src/VoxFlow.Core/Services/Diarization/PyannoteSidecarClient.cs#L162) |
| `speaker-labeling: error-response-returned: voxflow_diarize.py returned error envelope: …` | All | The sidecar wrote a structured `{ "status": "error", "error": "..." }` response. The trailing text is the upstream error verbatim — typically a `Repository not found` from Hugging Face, a CUDA-OOM, or a pyannote auth failure. | If "Repository not found" or auth-related: set `HUGGING_FACE_HUB_TOKEN` and accept the gated licenses on both `pyannote/speaker-diarization-3.1` and `pyannote/segmentation-3.0`. See [speaker-labeling runbook §0](./speaker-labeling.md). | [`PyannoteSidecarClient.cs:152`](../../src/VoxFlow.Core/Services/Diarization/PyannoteSidecarClient.cs#L152) |

## Speaker labeling — additional warnings (non-enum)

These are surfaced by `SpeakerEnrichmentService` but bypass the `SidecarFailureReason` taxonomy because the failure happens outside the sidecar call.

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `speaker-labeling: timed out after …s` | All | Outer linked-CTS timeout fired before the sidecar returned. Same cause as `timeout:` above but reported by the enrichment orchestrator, not the sidecar client. | Same as the sidecar `timeout` row. | [`SpeakerEnrichmentService.cs:123`](../../src/VoxFlow.Core/Services/Diarization/SpeakerEnrichmentService.cs#L123) |
| `speaker-labeling: diarization returned zero speakers` | All | Sidecar succeeded but pyannote detected no speech — common with silent or too-short clips (< 1 s). | Sanity-check the audio file plays in a media player. For short clips, transcribe without speaker labeling: set `transcription.speakerLabeling.enabled=false`. | [`SpeakerEnrichmentService.cs:129`](../../src/VoxFlow.Core/Services/Diarization/SpeakerEnrichmentService.cs#L129) |
| `speaker-labeling: internal error: …` | All | An exception escaped enrichment that wasn't already mapped to a `SidecarFailureReason`. The trailing text is `ex.Message`. | Re-run with a smaller / known-good audio file to isolate. File an issue with `desktop.log` attached; the `ILogger<TranscriptionService>` line that paired this warning will have the full stack. | [`TranscriptionService.cs:144`](../../src/VoxFlow.Core/Services/TranscriptionService.cs#L144) |

## ffmpeg / audio conversion

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `Unsupported input format '…'. Supported formats: …` | All | The input file's extension is not in `SupportedInputFormats`. | Convert to one of the listed formats (M4A, WAV, MP3, AAC, FLAC, OGG, AIFF, MP4) or extend `SupportedInputFormats` if the codec is genuinely supported by ffmpeg. | [`AudioConversionService.cs:41`](../../src/VoxFlow.Core/Services/AudioConversionService.cs#L41) |
| `Failed to start ffmpeg for WAV conversion.` (`Win32Exception` inner) | All | `ffmpeg` binary not found at the configured path. macOS exit code 127 is the typical native sign. | Install ffmpeg (`brew install ffmpeg`) OR set `transcription.ffmpegExecutablePath` to an absolute path such as `/opt/homebrew/bin/ffmpeg`. | [`AudioConversionService.cs:72`](../../src/VoxFlow.Core/Services/AudioConversionService.cs#L72) |
| `ffmpeg conversion failed with exit code N: …` | All | ffmpeg ran but failed (codec issue, corrupt input, etc.). The trailing text is the captured stderr. | Inspect the stderr fragment in the message; common causes: missing codec, non-audio file with audio extension, locked input file. | [`AudioConversionService.cs:82`](../../src/VoxFlow.Core/Services/AudioConversionService.cs#L82) |
| `ffmpeg reported success, but the WAV file is missing or empty.` | All | ffmpeg returned 0 but the output file is absent or zero-bytes. Usually a path-permission issue (output directory not writable) or a race with another process. | Check the configured `wavFilePath` parent directory is writable and that no other VoxFlow process is mid-conversion. | [`AudioConversionService.cs:89`](../../src/VoxFlow.Core/Services/AudioConversionService.cs#L89) |

## Whisper model

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `Whisper model at … failed to load; marking for re-download.` (in `desktop.log` via `ILogger<ModelService>`) | All | Existing model file is corrupt, truncated, or built for an incompatible Whisper.net version. | Delete the configured `modelFilePath` and re-run — VoxFlow will redownload. If the redownload also fails, check disk space and `~/.cache/whisper-net/` permissions. | [`ModelService.cs:80`](../../src/VoxFlow.Core/Services/ModelService.cs#L80) |
| `Unsupported model type configured: …` | All | `transcription.modelType` does not match any `Whisper.net.Ggml.GgmlType`. | Use one of the valid values: `Tiny`, `Base`, `Small`, `Medium`, `LargeV1` … `LargeV3`. See `appsettings.example.json`. | [`ModelService.cs:152`](../../src/VoxFlow.Core/Services/ModelService.cs#L152) |
| `Model download completed but the model could not be loaded: …` | All | Download succeeded but the binary cannot be loaded. Usually a platform-compat issue (e.g., Intel Mac asking for an arm64-only build) — see `WhisperRuntimeFailureFormatter`. | If the inner message mentions runtime / platform, you're on an unsupported host (Intel Mac with arm64-only runtime, etc.). Otherwise re-download by deleting the file. | [`ModelService.cs:138`](../../src/VoxFlow.Core/Services/ModelService.cs#L138) |

## Startup validation

Validation surfaces an aggregate result rather than throwing; the message lives in each `ValidationCheck.Details`. These are the most common rows.

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `Input file … Not found: …` | All | `transcription.inputFilePath` does not exist. | Check the path; if relative, it resolves against the host's working directory (CLI = repo root; Desktop = `~/Documents/VoxFlow/`). | [`ValidationService.cs:113`](../../src/VoxFlow.Core/Services/ValidationService.cs#L113) |
| `Directory not found: …` (output / model / batch dirs) | All | A configured directory does not exist on disk. | Create it manually, or rely on the host to materialize it (Desktop auto-creates standard dirs on startup; CLI does not). | [`ValidationService.cs:364`](../../src/VoxFlow.Core/Services/ValidationService.cs#L364) |
| `Directory is not writable: … {ex.Message}` | All | A configured directory exists but the current user has no write permission. | Fix permissions or pick a writable path. On Mac, `~/Library/Application Support/VoxFlow/` is always writable for the current user. | [`ValidationService.cs:395`](../../src/VoxFlow.Core/Services/ValidationService.cs#L395) |
| `Speaker labeling runtime … Managed venv not yet created at '…'` | All (warning, not failure) | `pythonRuntimeMode=ManagedVenv` on a fresh machine; the venv is bootstrapped lazily on first enrichment. | No action needed — the next enabled run will bootstrap. To verify ahead of time, see [speaker-labeling runbook §4](./speaker-labeling.md). | `CompositionSpeakerLabelingPreflight` |
| `Speaker labeling model cache … is not cached and will be downloaded on first run.` | All (warning) | Pyannote weights not in `~/.cache/huggingface/hub`. | No action needed — the first enrichment downloads them (~1 GB). | `CompositionSpeakerLabelingPreflight` |

## Desktop CLI bridge (Intel Mac)

On Intel Mac, the Desktop host shells out to `VoxFlow.Cli`. Its stderr lines surface in the failed-state banner via `DesktopCliSupport.ExtractFailureMessage`.

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `Could not locate the VoxFlow CLI bridge. Rebuild the Desktop app …` | Desktop | The bundled CLI executable is missing from the Mac Catalyst `.app` bundle. Happens when `CopyBundledCliBridge` did not run (e.g., the CI gate baseline of 2 skipped `DesktopCliBundleTests` calls out exactly this). | Rebuild the Desktop project: `dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst`. The CLI bridge is copied as part of the build. | [`DesktopCliTranscriptionService.cs:181`](../../src/VoxFlow.Desktop/Services/DesktopCliTranscriptionService.cs#L181) |
| `VoxFlow could not handle the dropped file: …` (alert dialog) | Desktop | Drag-and-drop produced an unsupported file or the underlying transcription pipeline threw. The trailing text is `ex.Message`. | If "Unsupported input format", convert the file (see ffmpeg row above). For other messages, check `~/Library/Application Support/VoxFlow/logs/desktop.log` for the full stack. | [`MainPage.xaml.cs:175`](../../src/VoxFlow.Desktop/MainPage.xaml.cs#L175) |
| `Finder did not return within 10s and was terminated.` | Desktop | `/usr/bin/open` was launched to show the result folder but hung past the 10 s per-op timeout. Rare; usually a stuck Launch Services handoff. | Try opening the folder manually via Finder → Go → Go to Folder. File an issue if it reproduces consistently. | [`ResultActionService.cs:82`](../../src/VoxFlow.Desktop/Services/ResultActionService.cs#L82) |

## MCP server

| Pattern | Surface | Root cause | Remediation | Source |
|---|---|---|---|---|
| `[mcp] shutting down — waiting up to Ns for in-flight tool invocations to drain.` (stderr) | MCP | The MCP server received SIGINT / SIGTERM and is performing a graceful shutdown. Not an error — informational. | None. To customize the grace period, set `mcp.shutdownGracePeriodSeconds` in `appsettings.json`. | [`Program.cs:68`](../../src/VoxFlow.McpServer/Program.cs#L68) |
| MCP tool envelope `{ "isError": true, "content": [{"text": "…"}] }` with text containing `Path is not allowed:` | MCP | The requested input/output path is outside the allow-list configured by `mcp.allowedInputRoots` / `mcp.allowedOutputRoots`, or is relative when `mcp.requireAbsolutePaths=true`. | Add the path's parent directory to the allow-list, or pass an absolute path. See `docs/deployment/mcp-server-security.md` (#49). | [`PathPolicy.cs`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs) |

---

## Adding a new entry

When you add a new throw / structured error surface in `src/`:

1. Append a row to the appropriate table above. Use the same column order: **Pattern**, **Surface**, **Root cause**, **Remediation**, **Source**.
2. Source link format: `[file.cs:NN](../../src/path/to/file.cs#LNN)`. Relative paths from this file resolve into the repo.
3. If the error belongs to an enum (like `SidecarFailureReason`), make sure every enum value still has a row.
4. Cross-link from [troubleshooting.md](./troubleshooting.md) when the entry would also help someone scanning the troubleshooting page.

## Related

- [Troubleshooting](./troubleshooting.md) — common scenarios and resolutions.
- [Speaker labeling runbook](./speaker-labeling.md) — full setup walkthrough for the diarization pipeline.
- [Smoke tests](./smoke-tests.md) — what to run after a change to confirm nothing regressed.
