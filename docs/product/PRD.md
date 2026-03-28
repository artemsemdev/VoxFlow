# VoxFlow Product Requirements Document

| Field | Value |
|---|---|
| Product | VoxFlow |
| Repository | `artemsemdev/VoxFlow` |
| Status | Active |
| Version | 1.0 |
| Last updated | March 28, 2026 |

---

## 1. Executive Summary

VoxFlow is a privacy-first, fully local audio transcription product built on .NET 9. It converts recorded audio files into clean, timestamped text transcripts entirely on-device, with no cloud dependencies and no data leaving the user's machine.

VoxFlow ships as three product surfaces built on a single shared core:

- **CLI** for developers, power users, and automated workflows
- **macOS Desktop** for users who prefer a visual single-file transcription experience
- **MCP Server** for AI clients that need programmatic access to transcription capabilities

All three surfaces share configuration, validation, preprocessing, inference, filtering, and output logic through a common core library, ensuring consistent behavior regardless of how the user interacts with the product.

---

## 2. Product Vision and Problem Statement

### Problem

Audio transcription is a common productivity need across professionals, researchers, developers, and content creators. Existing solutions fall into two categories:

1. **Cloud transcription services** that require uploading audio to third-party servers, creating privacy, compliance, and data-sovereignty risks for sensitive recordings such as legal proceedings, medical consultations, internal meetings, and confidential interviews.
2. **Manual transcription** that is time-consuming, error-prone, and impractical for regular use.

Users who handle sensitive audio need a transcription tool that works entirely on their own hardware, produces reliable output, and fits into both manual and automated workflows without compromising on privacy.

### Vision

VoxFlow provides a local-first transcription pipeline that is accurate, transparent, and automation-friendly. It gives users full control over their audio data while producing clean, deterministic output suitable for review, archival, or downstream processing. It is designed to serve both direct human users and AI-powered tool chains equally well.

---

## 3. Target Users and Primary Use Cases

### Target Users

| Persona | Description | Primary surface |
|---|---|---|
| **Privacy-conscious professional** | Transcribes meetings, interviews, calls, or legal recordings that must not leave the local machine. Comfortable with a desktop app but not necessarily with the command line. | Desktop |
| **Developer or power user** | Wants scriptable, configuration-driven transcription integrated into local workflows, build pipelines, or personal tooling. Comfortable with CLI and configuration files. | CLI |
| **AI workflow user** | Uses AI assistants (Claude, ChatGPT, GitHub Copilot, VS Code) and wants to invoke transcription as a tool within an AI-driven workflow without leaving the assistant context. | MCP Server |
| **Researcher or analyst** | Needs batch transcription of multiple recordings with per-file results and a summary report. Values deterministic, repeatable output. | CLI (batch mode) |

### Primary Use Cases

1. **Single-file local transcription.** A user selects one audio file and receives a timestamped transcript written to a local text file. The user can review, copy, and locate the output.
2. **Batch transcription.** A user points the tool at a directory of audio files and receives one transcript per input file, plus a human-readable summary report.
3. **Preflight environment check.** Before committing to a long-running transcription, the user receives a clear report of whether all prerequisites (ffmpeg, model, paths, configuration) are satisfied.
4. **AI-assisted transcription.** An AI client discovers and invokes VoxFlow's transcription pipeline through MCP, enabling the user to transcribe files from within an AI assistant conversation.
5. **Repeated single-file workflow.** A Desktop user transcribes one file, reviews the result, then transcribes another file in the same session without relaunching the app.

---

## 4. Jobs to Be Done

| Job | Outcome |
|---|---|
| Convert a recorded audio file into a readable transcript | A timestamped text file on disk, produced entirely on-device |
| Verify my environment before starting a long transcription | A clear pass/warn/fail report before any processing begins |
| Transcribe a batch of recordings in one operation | One result file per input, plus a summary with per-file status |
| Integrate transcription into an AI-assisted workflow | AI clients can discover and invoke transcription tools via MCP |
| Keep sensitive audio private during transcription | No audio data leaves the local machine at any point |
| Review and use the transcript immediately | The output is human-readable, easy to copy, and written to a known location |

---

## 5. Product Principles

| Principle | Meaning |
|---|---|
| **Local-first** | All processing happens on the user's machine. No network calls during transcription. No cloud fallback. |
| **Privacy-first** | Audio data never leaves the device. The product must not imply cloud upload, remote processing, or external data sharing. |
| **Truthful system status** | The product must clearly communicate whether it is ready, blocked, running, failed, or complete. No ambiguous or frozen states. |
| **Deterministic output** | Given the same input and configuration, the product should produce consistent, predictable results. |
| **Scriptable and automation-friendly** | Every capability available through the Desktop or CLI is also reachable through configuration and the MCP interface. |
| **Failure-transparent** | When something goes wrong, the product must explain what failed and what the user can do about it. Silent failures and corrupted output are unacceptable. |
| **Configuration-driven** | All runtime behavior is controlled by configuration. No magic values are hard-coded in the pipeline. |

---

## 6. Goals

- Provide reliable, local-only audio transcription across CLI, Desktop, and MCP surfaces
- Validate all prerequisites before starting expensive transcription work
- Show truthful, real-time progress during long-running operations
- Support graceful cancellation without corrupting output
- Reduce hallucinated transcript output caused by silence, noise, and low-information audio
- Produce clean, timestamped transcripts in a stable output format
- Expose the full transcription pipeline to AI clients through MCP
- Provide a macOS Desktop app for visual single-file transcription
- Support batch processing of multiple files in a single CLI run
- Keep the external input/output contract stable across releases

## 7. Non-Goals

The following are explicitly out of scope:

- Real-time or streaming transcription
- Speaker diarization (identifying who said what)
- Translation between languages
- Cloud-hosted inference or any remote processing
- Windows or Linux desktop support in the current phase
- Parallel or concurrent batch file processing
- Recursive subdirectory scanning in batch mode
- Watch mode or file-system monitoring
- Merging batch results into a single combined output file
- HTTP or SSE MCP transport (stdio only, for local-first security)
- MCP server as a long-lived daemon (it runs only when launched by an MCP client)
- Batch-processing UI in the Desktop app (batch processing exists in the pipeline but Desktop is a single-file workflow)
- Desktop settings editor UI (configuration overrides remain file-based)

---

## 8. In-Scope Surfaces and Phased Scope

### Product Surfaces

| Surface | Platform | Scope |
|---|---|---|
| **VoxFlow.Core** | .NET 9 (cross-platform library) | Shared pipeline: configuration, validation, preprocessing, inference, filtering, batch orchestration, output |
| **VoxFlow.Cli** | .NET 9 console application | Single-file and batch transcription via command line |
| **VoxFlow.Desktop** | .NET 9 MAUI Blazor Hybrid (macOS only) | Visual single-file transcription workflow |
| **VoxFlow.McpServer** | .NET 9 console application (stdio) | MCP tool/prompt/resource exposure for AI clients |

### Phase 1 Scope (Current)

- Stable single-file transcription across all three surfaces
- Batch transcription via CLI
- macOS Desktop for single-file workflow only
- MCP Server with full tool, prompt, and resource support
- Startup validation, progress reporting, cancellation, and error recovery on all surfaces

### Deferred to Future Phases

- Desktop batch-processing UI
- Desktop settings editor
- Multi-file Desktop workflow
- Windows and Linux desktop
- Additional MCP transports

---

## 9. Core User Journeys

### 9.1 CLI Single-File Transcription

1. The user configures `appsettings.json` with input file path, output path, model path, and desired settings.
2. The user runs the CLI application.
3. Startup validation runs and reports pass, pass with warnings, or fail.
4. If validation passes, the pipeline converts the audio to WAV, loads the model, runs inference, filters the output, and writes the transcript.
5. The user sees real-time progress with percentage, elapsed time, and current stage.
6. The transcript is written to the configured result file path.

### 9.2 CLI Batch Transcription

1. The user sets `processingMode` to `"batch"` and configures the batch input directory, output directory, and file pattern.
2. The CLI discovers matching files, sorts them deterministically, and processes each sequentially.
3. File-level progress (`[File X/Y]`) is displayed alongside per-file transcription progress.
4. Each input file produces an independent result file. Failed files are recorded and processing continues.
5. A human-readable summary report is written with per-file status, detected language, and timing.

### 9.3 Desktop Single-File Transcription

1. The user launches the Desktop app on macOS.
2. Startup validation runs automatically. If blocked, the app shows a warning banner and disables file selection.
3. When ready, the user selects a local audio file through the system file picker or drag-and-drop.
4. The Running screen shows a progress bar, percentage, elapsed time, and current stage.
5. On completion, the user can review a transcript preview, copy the transcript, or open the output folder.
6. On failure, the user can retry with the same file or choose a different file.
7. The user can start another transcription without relaunching the app.

For exhaustive screen-level detail, state transitions, and automation identifiers, see [DESKTOP_UI_SPEC.md](DESKTOP_UI_SPEC.md).

### 9.4 MCP-Assisted Transcription

1. An AI client (Claude, ChatGPT, GitHub Copilot, VS Code) launches VoxFlow's MCP server.
2. The client discovers available tools: environment validation, single-file transcription, batch transcription, language inspection, model inspection, and transcript reading.
3. The client validates the environment, then invokes transcription on a user-specified file.
4. The MCP server enforces path safety, runs the pipeline, and returns structured results.
5. The client can read the transcript and present it to the user within the assistant conversation.

---

## 10. Functional Requirements

### FR-01: Startup Validation

The application must run a configurable preflight validation stage before transcription begins.

**Requirements:**

- The validation stage must report one of three outcomes: `PASSED`, `PASSED WITH WARNINGS`, or `FAILED`.
- Validation checks must include: input file presence, output directory existence and writability, ffmpeg availability and version, model type validity, model directory existence and writability, model reuse or download readiness, Whisper runtime loadability, and configured language-code support.
- Individual checks must be independently configurable (enable/disable per check).
- If validation fails, transcription must not start.
- The validation report must provide actionable diagnostics for each check that does not pass.

**Surface-specific behavior:**

- CLI: Validation report is printed to the console before pipeline execution.
- Desktop: Validation runs during app initialization. Blocking failures show a warning banner and disable file selection. Fatal initialization errors surface through a startup-error screen with retry.
- MCP: The `validate_environment` tool returns structured validation results to the AI client.

**Acceptance criteria:**

- A missing ffmpeg produces a clear, actionable failure message and prevents transcription from starting.
- A missing model triggers download readiness reporting, not a silent failure.
- Desktop stays on the ready screen with file selection disabled when validation fails.

---

### FR-02: Audio Preprocessing

The application must convert input audio files to WAV format before transcription.

**Requirements:**

- Output WAV must be mono, 16000 Hz, WAV container.
- Conversion must use a configurable ffmpeg audio-filter chain for noise reduction and silence removal.
- The default filter chain applies noise filtering (`afftdn=nf=-25`) and silence removal (`silenceremove=stop_periods=-1:stop_threshold=-50dB:stop_duration=1`).
- Conversion errors must produce clear, actionable diagnostics.

**Acceptance criteria:**

- The pipeline does not proceed to inference if audio conversion fails.
- Applied audio filters are logged for diagnostic visibility.
- The filter chain can be customized entirely through configuration without code changes.

---

### FR-03: Model Management

The application must use a local Whisper model file for inference.

**Requirements:**

- Reuse the configured model when it already exists locally and loads correctly.
- Download the configured model automatically if it is missing or if the existing file is empty or unloadable.
- The model type and model file path must be configurable.
- Model download is the only network operation in the product. Once the model is present locally, all subsequent operations are fully offline.

**Acceptance criteria:**

- Model reuse vs. model download is logged so the user understands what happened.
- A corrupt or empty model file triggers re-download, not a crash.
- After the model is downloaded once, the product operates entirely without network access.

---

### FR-04: Language Handling

The application must transcribe only configured supported languages.

**Requirements:**

- When exactly one language is configured, the application must use that language directly without candidate comparison.
- When multiple languages are configured, the application must run one candidate pass per language, filter and score each candidate, and select the best match using duration-weighted segment probability.
- Ambiguity handling must be configurable: reject ambiguous candidates, or continue with the best candidate and log a warning.
- The default checked-in configuration supports English. Additional languages (Russian, German, Ukrainian) are supported by the pipeline and can be enabled through configuration.

**Acceptance criteria:**

- Single-language configuration does not trigger unnecessary multi-language comparison logic.
- Candidate scores are logged when multi-language mode is active.
- Unsupported or ambiguous language results do not produce misleading transcript output.

---

### FR-05: Transcript Filtering and Anti-Hallucination Controls

The application must filter out unusable transcript segments and reduce hallucinated output.

**Requirements:**

Filtering must skip segments that are:

- Empty text
- Configured non-speech markers (e.g., "music", "silence", "noise" in supported languages)
- Below the minimum segment probability threshold
- Low-information long segments (long duration, very short text)
- Bracketed non-speech stage directions (e.g., `[door opening]`)
- Repeated short duplicate loops typical of silence hallucinations

Anti-hallucination decoder settings must be configurable, including: `useNoContext`, `noSpeechThreshold`, `logProbThreshold`, and `entropyThreshold`.

**Acceptance criteria:**

- Obvious silence hallucinations and non-speech markers do not appear in final output.
- Skipped-segment reasons are logged for diagnostic visibility.
- All filtering thresholds and markers are configurable without code changes.

---

### FR-06: Progress Reporting

The application must show clear, real-time progress during transcription.

**Requirements:**

- Progress must include: overall percentage, current stage or activity, and elapsed time.
- Current language must be displayed when available during inference.
- Progress must update at a configurable refresh interval.

**Surface-specific behavior:**

- CLI: Colored ANSI output in interactive terminals, readable fallback when stdout is redirected.
- Desktop: Visual progress bar with numeric percentage and human-readable stage labels. The UI must show a truthful "starting" state before the first progress event arrives.
- MCP: Progress data is available through the tool response lifecycle.
- Batch mode: File-level progress (`[File X/Y]`) alongside per-file transcription progress.

**Acceptance criteria:**

- The user sees active, updating progress within 2 seconds of pipeline start.
- Long-running transcriptions never show a frozen or ambiguous UI state.
- Batch mode clearly indicates which file is being processed and overall batch progress.

---

### FR-07: Cancellation

The application must support graceful cancellation of long-running work.

**Requirements:**

- User interruption (Ctrl+C in CLI, cancel action in Desktop) must stop the current run without corrupting output state.
- Cancellation must propagate through all async operations: download, conversion, inference, and output writing.
- In-progress external processes (ffmpeg) should be stopped when cancellation is requested.
- Canceled runs must exit clearly instead of hanging.
- In batch mode, cancellation stops the entire batch immediately. Completed result files remain intact.

**Acceptance criteria:**

- Cancellation during any pipeline stage produces a clean exit within a reasonable time.
- No partial or corrupt output files are left after cancellation.
- Desktop treats cancellation as a recoverable action, not a failure.

---

### FR-08: Result Output

The application must write accepted transcript segments to the configured result file.

**Requirements:**

- Output encoding must be UTF-8.
- Each transcript line must use the following timestamped format:

```text
{start}->{end}: {text}
```

Example:

```text
00:00:01.2000000->00:00:03.8000000: Hello, this is a test.
```

- If the run is rejected due to unsupported or ambiguous language, the application must not produce misleading transcript output.
- This output format is a stable external contract and must not change without a versioned migration.

**Acceptance criteria:**

- Output files are valid UTF-8 with consistent timestamp formatting.
- Rejected runs produce no output file rather than an empty or misleading one.

---

### FR-09: Batch Processing

The application must support processing multiple audio files from a configured input directory in a single run.

**Requirements:**

- Batch mode is activated by setting `processingMode` to `"batch"` in configuration.
- File discovery scans the configured input directory for files matching a configurable pattern (default: `*.m4a`), sorted alphabetically for deterministic ordering.
- Empty or unreadable files are skipped. An empty match set is a failure.
- Each file follows the full pipeline: convert, load WAV, transcribe, filter, write output.
- Each input file produces its own result `.txt` file in the configured output directory.
- Intermediate WAV files are generated in a configurable temp directory and cleaned up after each file unless explicitly retained.
- The Whisper model is loaded once and reused across all files in the batch.

**Error handling:**

- By default, a failed file is recorded and processing continues with remaining files.
- When `stopOnFirstError` is enabled, the batch stops on the first file failure.
- Completed result files remain intact after cancellation or failure.

**Batch summary:**

- A human-readable summary report is written after the batch completes.
- The summary includes: total file count, succeeded count, failed count, skipped count, and total duration.
- Each file entry includes status, output file name, detected language, and processing duration.

**Acceptance criteria:**

- All matching files are processed in deterministic alphabetical order.
- Each file produces an independent result regardless of other files' success or failure.
- The summary report accurately reflects the outcome of every file in the batch.

---

### FR-10: MCP Server

The product must expose the transcription pipeline to AI clients through a Model Context Protocol server.

**Requirements:**

The MCP server runs as a separate .NET 9 console application using stdio transport (stdin/stdout for protocol frames, stderr for diagnostics). It consumes the shared core library through dependency injection.

**Tools (6):**

| Tool | Purpose |
|---|---|
| `validate_environment` | Run startup validation and return structured results |
| `transcribe_file` | Transcribe a single local audio file through the full pipeline |
| `transcribe_batch` | Batch transcribe a directory of audio files |
| `get_supported_languages` | Return configured supported languages |
| `inspect_model` | Return Whisper model status, path, loadability, and download state |
| `read_transcript` | Read a previously produced transcript file |

**Prompts (4):**

| Prompt | Purpose |
|---|---|
| `transcribe-local-audio` | Guide through transcribing a single local audio file |
| `batch-transcribe-folder` | Guide through batch transcribing all audio files in a folder |
| `diagnose-transcription-setup` | Diagnose the environment and suggest fixes |
| `inspect-last-transcript` | Review a generated transcript file |

**Resources:**

| Resource tool | Purpose |
|---|---|
| `get_effective_config` | Return the resolved effective configuration snapshot |

**Security:**

- All file paths from MCP tool arguments must be validated against configurable allowed input/output root directories.
- Absolute paths are required by default.
- Path traversal patterns (e.g., `../`) must be rejected.
- Batch mode and maximum batch file count are configurable limits.

**Acceptance criteria:**

- AI clients can discover and invoke all registered tools, prompts, and resource tools via stdio MCP.
- Path safety enforcement rejects every path outside configured allowed roots.
- The MCP server does not expose any network surface beyond local stdio.

---

### FR-11: Desktop Application

The product must provide a macOS desktop application for visual single-file transcription.

**Requirements:**

The Desktop app is a .NET 9 MAUI Blazor Hybrid application targeting macOS (Mac Catalyst). It presents a state-driven workflow with five screens:

| Screen | Purpose |
|---|---|
| **Startup Error** | Retry app initialization if configuration loading fails |
| **Ready** | Show validation status, display file-entry actions (Browse Files, drag-and-drop) |
| **Running** | Show real-time progress bar, percentage, elapsed time, stage label |
| **Failed** | Show the error with retry and choose-different-file actions |
| **Complete** | Show transcript preview with copy and open-folder actions |

**Key Desktop behaviors:**

- Startup validation runs automatically on app initialization.
- Blocking validation failures disable file selection and display a warning banner.
- File intake must be gated on the Ready state. No file-entry path may bypass blocked validation or a non-ready state.
- The UI must use local-first language (no "upload" terminology).
- On Apple Silicon, the Desktop app uses the shared core transcription pipeline directly.
- On Intel Mac Catalyst, the Desktop app routes transcription through a local CLI bridge to maintain the same working pipeline behavior.
- Dark theme consistent with macOS design conventions.
- No settings editor UI is required in the current phase. Persistent configuration overrides remain file-based.

**Acceptance criteria:**

- The app launches, validates the environment, and reaches the Ready screen.
- A user can select a file, observe real-time progress, and review the completed transcript.
- Failure states provide clear recovery actions.
- The UI behaves consistently on both Apple Silicon and Intel Mac Catalyst execution paths.

For exhaustive screen-level specifications, state transitions, accessibility requirements, and automation selector contracts, see [DESKTOP_UI_SPEC.md](DESKTOP_UI_SPEC.md).

---

### FR-12: Desktop Platform Compatibility

The Desktop app must initialize reliably on both Apple Silicon and Intel Mac Catalyst.

**Requirements:**

- Startup checks must verify ffmpeg availability, model presence and readiness, and output directory writability.
- On Apple Silicon, the app may use the shared core transcription pipeline directly (in-process Whisper inference).
- On Intel Mac Catalyst, the app must route transcription through a local CLI bridge, reusing the same working CLI pipeline while keeping all processing on-device.
- The Desktop build must ensure the CLI host is built and available for the Intel bridge path.

**Acceptance criteria:**

- The app does not crash or hang on either architecture.
- Transcription completes successfully on both Apple Silicon and Intel Mac Catalyst.
- The user experience is consistent across both execution paths.

---

## 11. Non-Functional Requirements

### NFR-01: Privacy

- Audio data must never leave the user's machine during transcription.
- The product must not make network calls during transcription pipeline execution.
- The only permitted network operation is first-time model download. After the model is present locally, all operations are fully offline.
- The product must not transmit telemetry, analytics, or usage data to external services.

### NFR-02: Security

- MCP file-path arguments must be validated against configurable allowed roots before any file-system operation.
- Path traversal patterns must be rejected.
- MCP uses stdio-only transport with no network surface area.
- Configuration files should not contain secrets. Sensitive paths are local filesystem references, not credentials.

### NFR-03: Reliability

- The product must fail early on invalid configuration, missing dependencies, or unavailable tooling.
- Conversion, model loading, inference, and output writing failures must produce clear, actionable diagnostics.
- Cancellation must never leave the system in a corrupt or hung state.
- Completed result files must survive subsequent failures or cancellation in batch mode.
- The Desktop app must avoid unsafe native teardown paths that can trigger macOS runtime instability.

### NFR-04: Performance

- The Whisper model must be loaded once and reused across all files in a batch run.
- Intermediate WAV files must be cleaned up after each file in batch mode (unless retention is configured) to manage disk usage.
- Progress updates must reach the user interface within the configured refresh interval.
- The pipeline should add minimal overhead beyond the inherent cost of ffmpeg conversion and Whisper inference.

### NFR-05: Accessibility

- Desktop progress indicators must include accessible `progressbar` semantics.
- Desktop screen states must be distinguishable by assistive technology.
- CLI output must remain readable when stdout is redirected (non-ANSI fallback).

### NFR-06: Observability and Diagnostics

- Startup validation must produce a detailed report with per-check pass/warn/fail status.
- Model reuse vs. download must be logged.
- Applied audio filters must be logged during WAV conversion.
- Candidate scores must be logged when multi-language mode is active.
- Skipped-segment reasons must be logged for transcript filtering diagnostics.
- Each major pipeline stage must log entry, completion, and failure with actionable context.

### NFR-07: Maintainability

- All transcription logic must live in the shared core library, consumed by all hosts via dependency injection.
- Host projects (CLI, MCP, Desktop) must contain only host-specific concerns.
- Core services must be registered through a single shared extension method.
- Progress reporting must use a host-agnostic interface to avoid coupling core logic to any specific UI.
- All business rules must be driven by configuration, not inline constants.
- The external I/O contract (input format, output format) must remain backward-compatible.

---

## 12. Runtime Configuration

All hosts load runtime settings from `appsettings.json` or a path provided through the `TRANSCRIPTION_SETTINGS_PATH` environment variable.

The Desktop host merges bundled defaults with a user-local override file at `~/Library/Application Support/VoxFlow/appsettings.json`.

The following settings must be configurable:

| Category | Configurable settings |
|---|---|
| **Paths** | Input file, WAV output, result file, model file, ffmpeg executable |
| **Model** | Model type (e.g., Base, Small, Medium) |
| **Audio** | Output sample rate, channel count, container format, ffmpeg audio-filter chain |
| **Language** | Supported language list (code + display name), ambiguity handling |
| **Filtering** | Non-speech markers, segment probability thresholds, long-segment thresholds, duplicate detection limits |
| **Anti-hallucination** | `useNoContext`, `noSpeechThreshold`, `logProbThreshold`, `entropyThreshold`, bracketed non-speech suppression |
| **Validation** | Enable/disable per individual startup check |
| **Progress** | Enable/disable, color support, bar width, refresh interval |
| **Processing mode** | Single-file or batch |
| **Batch** | Input directory, output directory, temp directory, file pattern, stop-on-first-error, intermediate file retention, summary file path |
| **MCP** | Server identity, path policy (allowed roots, absolute path requirement), batch limits, resource/prompt toggles, logging |

---

## 13. Dependencies and Assumptions

### Runtime Dependencies

| Dependency | Role | Acquisition |
|---|---|---|
| **.NET 9 runtime** | Application host | Pre-installed or bundled |
| **ffmpeg** | Audio preprocessing (format conversion, noise filtering, silence removal) | Must be available on PATH or at the configured path. Not bundled. |
| **Whisper model file** | Local speech-to-text inference | Downloaded automatically on first use if not already present. This is the only network operation. |
| **Whisper.net** | .NET binding for Whisper inference | NuGet dependency, bundled at build time |

### Assumptions

- The user's machine has sufficient disk space for the Whisper model file (varies by model size; Base ~150 MB).
- The user's machine can run .NET 9 applications.
- For Desktop: the user is running macOS 15.0 (Mac Catalyst) or later.
- For Desktop on Intel Macs: the CLI host binary is available locally for the CLI bridge path.
- Local file-system access is available for input reading, output writing, model storage, and configuration loading.
- First-time model download requires a one-time internet connection. After that, all operations are fully offline.

---

## 14. Success Metrics and Release Criteria

### Completion Rate

- Single-file transcription completes successfully when given a valid audio file and a properly configured environment.
- Batch transcription processes all matching files and produces independent result files, with failures isolated per file.

### Preflight Visibility

- Every startup validation failure produces a clear, actionable diagnostic message visible to the user before processing starts.
- Desktop disables file selection and shows a warning when validation fails.

### Cancellation Responsiveness

- Cancellation during any pipeline stage results in a clean exit with no corrupt or partial output files.
- Desktop treats cancellation as a recoverable user action with clear next steps.

### Output Correctness

- Transcript output uses the stable timestamped line format consistently across all surfaces.
- Rejected or failed runs produce no output rather than misleading content.
- Filtering removes obvious silence hallucinations, non-speech markers, and duplicate loops.

### Progress Visibility

- Users see active, updating progress throughout long-running transcription work.
- Batch mode shows both file-level and per-file progress simultaneously.

### Privacy Compliance

- No audio data or transcript content is transmitted over the network during transcription.
- No telemetry or analytics data is collected or sent.
- The only network operation is optional first-time model download.

### Desktop Stability

- The Desktop app launches, validates, and reaches the Ready screen on both Apple Silicon and Intel Mac Catalyst.
- Single-file transcription completes end-to-end through the Desktop UI.
- Recovery flows (retry, choose different file) work from both Failed and Complete states.

### MCP Safety

- Path safety enforcement rejects all file paths outside configured allowed roots.
- The MCP server exposes no network surface beyond local stdio.
- AI clients can discover and invoke all registered tools via MCP.

### Cross-Surface Consistency

- All three hosts (CLI, MCP, Desktop) produce identical transcript output for the same input and configuration, because they share the same core pipeline.

---

## 15. References

| Document | Purpose |
|---|---|
| [DESKTOP_UI_SPEC.md](DESKTOP_UI_SPEC.md) | Exhaustive Desktop screen specifications, state transitions, accessibility, and automation contracts |
| [ROADMAP.md](ROADMAP.md) | Delivery plan, priorities, and phased execution sequence |
| [ARCHITECTURE.md](../../ARCHITECTURE.md) | System architecture, design principles, boundary map, and ADR index |
| [docs/architecture/](../architecture/) | Detailed architecture views: system context, container, component, runtime sequences, quality attributes, decision log |
| [SETUP.md](../../SETUP.md) | Environment setup, local development, build, and test instructions |
