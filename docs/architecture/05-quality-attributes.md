# Quality Attributes

> How the architecture satisfies its non-functional requirements, with specific scenarios and trade-offs.

## Attribute Summary

| Attribute | Priority | How the architecture addresses it |
|-----------|----------|----------------------------------|
| Privacy | Critical | No network calls during transcription; all data stays local |
| Reliability | High | Fail-fast validation; atomic model writes; error isolation in batch |
| Operability | High | Structured diagnostics; progress feedback; clear exit codes |
| Maintainability | High | Module-per-responsibility; immutable config; small dependency surface |
| Testability | High | Pure-function modules; generated fixtures; fake external dependencies |
| Performance | Medium | Sequential processing; single-model load; acceptable for local use |

## Privacy

**Scenario:** A user transcribes a confidential meeting recording.

**Response:** Audio data, intermediate WAV files, and transcript output never leave the local machine. The application makes no network calls during the transcription pipeline. The Whisper model runs locally via native bindings.

**How enforced:**
- No HTTP client usage in the transcription pipeline
- No telemetry, analytics, or crash reporting
- Model download is a one-time setup step, not part of the processing flow
- Intermediate WAV files are written to local temp and deleted after processing

**Trade-off accepted:** The user must install ffmpeg and download the Whisper model themselves (or let the app download it once). This is manual setup cost in exchange for a zero-network-dependency runtime.

## Reliability

**Scenario:** A user runs a batch of 50 files. File 12 has a corrupt header.

**Response:** Files 1–11 produce transcripts. File 12 is recorded as failed with the error message. Files 13–50 continue processing. The batch summary report shows exactly which files succeeded, failed, or were skipped.

**How enforced:**
- **Fail-fast validation:** StartupValidationService runs 15+ checks before any expensive work. Missing ffmpeg, invalid model type, non-writable directories — all caught before the first audio conversion.
- **Atomic model writes:** Model downloads go to a temp file first, then are moved atomically. A crash during download does not leave a corrupt model file.
- **Error isolation in batch:** Each file has independent error handling. Configurable via `stopOnFirstError`.
- **Cancellation propagation:** CancellationToken threads through all async operations. Ctrl+C kills ffmpeg child processes and stops inference promptly.

**Trade-off accepted:** Startup validation adds latency before processing begins (typically 1–3 seconds for all checks). This is acceptable because the checks prevent minutes of wasted compute on invalid configurations.

## Operability

**Scenario:** A user runs transcription and wants to understand what happened.

**Response:** The application provides structured feedback at every stage:

| Stage | Feedback |
|-------|----------|
| Startup validation | Color-coded pass/warn/fail/skip report with specific messages |
| Audio conversion | ffmpeg output captured and logged on failure |
| Model management | Status messages for reuse, download, or re-download |
| Transcription | ANSI progress bar with percentage, elapsed time, spinner |
| Language selection | Candidate scores logged; winner selection explained |
| Filtering | Skip reasons logged per rejected segment |
| Batch processing | `[File X/Y]` context in progress display; summary report at end |

**How enforced:**
- ConsoleProgressService detects interactive vs. redirected output (disables ANSI for pipes)
- StartupValidationConsoleReporter uses color-coded ANSI output
- Exit codes map to outcomes: 0 (success), 1 (failure), 130 (cancelled)

**Trade-off accepted:** Console output is verbose by design. This prioritizes diagnosability over quiet operation. A `--quiet` flag could be added but is not needed for the current use case.

## Maintainability

**Scenario:** A developer needs to add support for a new audio format (e.g., `.mp3` input).

**Response:** The change is localized:
1. Add the format to FileDiscoveryService's pattern matching
2. Ensure ffmpeg supports the format (it already does)
3. No changes needed to inference, filtering, or output — those stages work with WAV samples regardless of the original format

**Scenario:** A developer needs to add a fourth host (e.g., a web API).

**Response:** The change is straightforward:
1. Create a new host project that references `VoxFlow.Core`
2. Call `AddVoxFlowCore()` in the DI setup
3. Inject Core service interfaces and implement host-specific concerns (HTTP transport, auth, etc.)
4. No changes to Core or existing hosts required

**How enforced:**
- **Shared Core library:** All business logic lives in `VoxFlow.Core`. Host projects contain only host-specific concerns.
- **Interface-based DI:** Core services implement interfaces (`ITranscriptionService`, `IValidationService`, etc.), enabling loose coupling between hosts and business logic.
- **Single DI entry point:** `AddVoxFlowCore()` ensures consistent service registration across all hosts.
- **Module-per-responsibility:** Each module has a single clear purpose. AudioConversionService handles format conversion; WavAudioLoader handles WAV parsing; neither knows about the other's internals.
- **Immutable configuration:** TranscriptionOptions is sealed. No module can accidentally modify another module's behavior by mutating shared state.
- **Host-agnostic progress:** `IProgress<ProgressUpdate>` decouples Core from any specific output mechanism.

**Trade-off accepted:** DI and interfaces add some ceremony compared to the previous static service approach. This is now justified by three hosts sharing the same Core, and the overhead is minimal given the clear organizational benefits.

## Testability

**Scenario:** A developer needs to verify that the transcript filter correctly rejects hallucinated segments.

**Response:** TranscriptionFilter.FilterSegments is a pure function that takes raw segments and configuration, and returns accepted + skipped segments with reasons. It can be tested without any I/O, external processes, or Whisper runtime.

**Test coverage structure:**

| Test Category | What is tested | How external deps are handled |
|--------------|----------------|-------------------------------|
| Configuration validation | TranscriptionOptions.LoadFromPath | Generated temp settings files |
| Startup validation | StartupValidationService.ValidateAsync | File system probes with temp directories |
| WAV parsing | WavAudioLoader.LoadSamplesAsync | Generated WAV fixtures (TestWaveFileFactory) |
| Transcript filtering | TranscriptionFilter.FilterSegments | Pure function — no deps |
| Language selection logic | DecideWinningCandidate | Pure function — no deps |
| Output formatting | OutputWriter.BuildOutputText | Pure function — no deps |
| File discovery | FileDiscoveryService.DiscoverInputFiles | Temp directories with test files |
| Batch summary | BatchSummaryWriter.BuildSummaryText | Pure function — no deps |
| End-to-end startup | Application launch + validation | Fake ffmpeg (FakeFfmpegFactory) |
| End-to-end batch | Full batch pipeline | Fake ffmpeg + temp directories |

**How enforced:**
- Core service interfaces enable mock-friendly unit testing — any host interaction with Core can be tested by mocking the interface
- Test support utilities in `tests/TestSupport/` provide deterministic fixtures
- FakeFfmpegFactory creates a mock ffmpeg that produces valid WAV output without real audio processing
- TemporaryDirectory (IDisposable) ensures clean test isolation
- DI registration can be verified by calling `AddVoxFlowCore()` and resolving interfaces

**Trade-off accepted:** Some modules (AudioConversionService, ModelService) are harder to unit test in isolation because they interact with external processes or native libraries. These are covered by end-to-end tests instead. This is a reasonable trade-off for a codebase of this size — test coverage does not require 100% unit test isolation.

## Performance and Stability

**Scenario:** A user transcribes a 60-minute recording.

**Response:** Processing time is dominated by Whisper inference, which is CPU-bound and inherently sequential for a single file. The application does not add meaningful overhead beyond inference.

**Design choices for stability:**
- **Sequential batch processing:** No parallel inference. Memory usage is predictable and bounded.
- **Single model load:** WhisperFactory is created once and reused. Avoids repeated native library initialization/teardown.
- **Temp file cleanup:** Intermediate WAV files are deleted after processing, preventing disk accumulation in long batch runs.
- **16kHz mono WAV:** ffmpeg converts to the exact format Whisper expects. No runtime resampling needed.

**Trade-off accepted:** Sequential batch processing means total time scales linearly with file count. Parallel processing could reduce wall-clock time on multi-core machines, but would require careful native runtime management and memory budgeting that is not justified for a local tool. If throughput becomes important, this would be the first design constraint to revisit (see ADR-011).

## MCP Server Security

**Scenario:** An AI client invokes `transcribe_file` with a path like `../../etc/passwd`.

**Response:** `PathPolicy.ValidateInputPath()` rejects the path before any file system access occurs. The tool returns a JSON error: `"Input path validation failed: Path traversal is not allowed."` No file is read.

**How enforced:**
- `PathPolicy` normalizes paths and checks against configurable allowed input/output root directories
- Absolute paths are required by default (`requireAbsolutePaths` option)
- Path traversal patterns (`../`, `..\\`) are rejected
- `SanitizePath()` strips sensitive path components from error messages
- Batch mode can be disabled entirely via `allowBatch` configuration
- Maximum batch file count is capped via `maxBatchFiles`

**Scenario:** An MCP tool writes diagnostic output to stdout, corrupting the MCP protocol stream.

**Response:** `Console.SetOut(Console.Error)` at MCP server startup redirects all `Console.WriteLine` calls to stderr. The stdout channel is reserved exclusively for MCP JSON-RPC frames.

**Trade-off accepted:** Diagnostic output from VoxFlow services is redirected to stderr, which may not be visible to all MCP clients. This is acceptable because protocol integrity is more important than diagnostic visibility — clients can access diagnostics through the `validate_environment` tool instead.

## Quality Attribute Trade-off Matrix

| Decision | Attribute Gained | Attribute Traded | Why acceptable |
|----------|-----------------|------------------|----------------|
| Local-only processing | Privacy | Convenience (manual setup) | Core requirement; setup is one-time |
| Fail-fast validation | Reliability | Startup latency (~1-3s) | Prevents minutes of wasted compute |
| Shared Core with DI | Maintainability, testability | Simplicity of static calls | Three hosts justify the DI overhead; interfaces enable mocking |
| Sequential batch | Stability, predictability | Throughput | Local tool; wall-clock time acceptable |
| ffmpeg as external process | Maintainability | Deployment dependency | ffmpeg is ubiquitous; validated at startup |
| Continue-on-error batch | Reliability (partial results) | Fail-fast purity | One bad file should not discard good work |
| Console output verbosity | Operability | Quiet operation | Diagnosability is more important for this use case |
| MCP stdio-only transport | Privacy, simplicity | Remote access | Local-first security; no network surface area |
| IProgress&lt;T&gt; for progress | Host-agnostic Core | Slight indirection | Each host renders progress differently; Core must not know how |
| Path policy enforcement | Security | Convenience (any path) | Prevents directory traversal from AI client tool arguments |
| Console.SetOut redirect | Protocol integrity | Diagnostic visibility | MCP protocol requires clean stdout; diagnostics via tools instead |
| Blazor Hybrid for Desktop | Cross-platform UI potential, web skills reuse | Native UI fidelity | Acceptable for a developer tool; dark theme provides good macOS integration |
