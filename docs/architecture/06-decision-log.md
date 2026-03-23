# Architecture Decision Log

> ADR-style records for the most significant design decisions. Each record includes the decision, context, alternatives considered, and trade-offs accepted.

## Index

| ADR | Decision | Status |
|-----|----------|--------|
| [001](#adr-001) | Local-only console architecture | Accepted |
| [002](#adr-002) | File-based stable contract | Accepted |
| [003](#adr-003) | Configuration-driven behavior | Accepted |
| [004](#adr-004) | ffmpeg as external audio preprocessing | Accepted |
| [005](#adr-005) | Local model management with reuse-first | Accepted |
| [006](#adr-006) | Staged inference with explicit post-processing | Accepted |
| [007](#adr-007) | Language selection with duration-weighted scoring | Accepted |
| [008](#adr-008) | Fail fast before expensive work | Accepted |
| [009](#adr-009) | Cancellation propagation through full pipeline | Accepted |
| [010](#adr-010) | Reuse Whisper runtime within a run | Accepted |
| [011](#adr-011) | Sequential batch processing | Accepted |
| [012](#adr-012) | Configuration-driven batch mode | Accepted |
| [013](#adr-013) | One result file per input file | Accepted |
| [014](#adr-014) | Continue-on-error with batch summary | Accepted |
| [015](#adr-015) | Temp directory for intermediate WAVs | Accepted |

---

## ADR-001

### Use a local-only console architecture

**Status:** Accepted

**Context:** The product requirement is fully local, privacy-first audio transcription. No audio data should leave the machine.

**Decision:** Build a single-process .NET 9 console application. No web server, no API, no cloud integration, no IPC.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Web API + frontend | Adds HTTP surface area, CORS, auth, deployment complexity — none of which serves the privacy goal |
| Desktop GUI (WPF/MAUI) | Adds platform-specific UI framework dependency for a workflow that is better served by CLI + config file |
| Worker service / background daemon | Adds process lifecycle management complexity for a tool that runs on demand |
| Python script with whisper.cpp | Would work, but .NET provides stronger type safety, test framework maturity, and cross-platform consistency |

**Trade-offs accepted:**
- No GUI — the operator interacts via config file and terminal output. This is appropriate for a developer tool.
- No HTTP API — if external systems need to invoke transcription, the ROADMAP describes an MCP server as a separate process.

---

## ADR-002

### Keep the external contract file-based and backward-compatible

**Status:** Accepted

**Context:** The pipeline has three artifact stages: input (`.m4a`), intermediate (`.wav`), output (`.txt`). Stability of these artifacts allows automation and debugging.

**Decision:** Maintain the file contract. Output format is `{start:TimeSpan}->{end:TimeSpan}: {text}` per line, UTF-8 without BOM.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| JSON output format | More structured, but the primary consumer is a human reading a transcript — plain text is more ergonomic |
| Binary/protobuf output | Over-engineering for a local tool; adds serialization dependency |
| Stdout-only output | Loses the file artifact; makes automation and batch processing harder |
| Configurable output format | Premature flexibility; one format is sufficient until a concrete need arises |

**Trade-offs accepted:**
- The plain text format carries less metadata than JSON (no per-segment probability, no language tag). If downstream tools need richer output, a structured format can be added as an additional output mode without breaking the existing contract.

---

## ADR-003

### Make runtime behavior configuration-driven

**Status:** Accepted

**Context:** Paths, model settings, language behavior, filtering thresholds, validation toggles, and progress settings must be adjustable without code changes.

**Decision:** Load all runtime behavior from `appsettings.json` (or path from `TRANSCRIPTION_SETTINGS_PATH`), then normalize into a sealed immutable `TranscriptionOptions` object.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| CLI arguments | Would require argument parsing library and make complex configurations unwieldy |
| Environment variables only | Too flat for nested configuration (languages, batch settings, filter thresholds) |
| YAML configuration | Adds a parsing dependency; JSON is natively supported in .NET |
| Mixed CLI + config file | Increases the surface area for configuration conflicts and debugging |

**Trade-offs accepted:**
- No CLI arguments means the user must edit a file to change behavior. This is acceptable because the configuration has 45+ settings — CLI arguments would be impractical at this scale.
- Environment variable override is limited to the config file path, not individual settings. This keeps the override surface small and predictable.

---

## ADR-004

### Use ffmpeg as an external audio preprocessing stage

**Status:** Accepted

**Context:** The pipeline requires `.m4a` → `.wav` conversion with specific parameters (16kHz, mono, configurable audio filters).

**Decision:** Delegate audio conversion to ffmpeg as a child process rather than embedding codec logic in the application.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| NAudio / managed codec library | Limited format support; platform-specific issues; adds large dependency |
| FFMpegCore / managed ffmpeg wrapper | Adds a dependency layer over a process call that is already simple |
| LibAV bindings | Complex native interop for a straightforward conversion task |
| Skip conversion (require WAV input) | Shifts burden to user; .m4a is the common recording format |

**Trade-offs accepted:**
- **Runtime dependency on ffmpeg.** The application cannot convert audio without ffmpeg installed. This is mitigated by startup validation (ADR-008) that checks ffmpeg availability before processing begins.
- **Process spawning overhead.** Spawning a child process is slower than in-process conversion, but audio conversion is not the bottleneck — Whisper inference is. The overhead is negligible in practice.
- **Less control over conversion internals.** The application controls ffmpeg via command-line arguments, not programmatic API. This is acceptable because ffmpeg's CLI is stable and well-documented.

**Why this is the right trade-off:** ffmpeg handles hundreds of audio formats with battle-tested codec implementations. Embedding this capability would mean maintaining audio processing code that adds no value to the core transcription mission.

---

## ADR-005

### Manage Whisper models locally with reuse-first behavior

**Status:** Accepted

**Context:** Whisper GGML models are large files (75MB–3GB). Download should be avoided when possible.

**Decision:** Attempt to load the existing model file first. Download only when the file is missing, empty, or fails to load. Use atomic file operations for downloads.

**Why atomic writes:** A download interrupted by Ctrl+C or network failure must not leave a corrupt model file that the next run would attempt to use. Writing to a temp file and then renaming ensures the model file is either complete or absent.

**Trade-offs accepted:**
- The application downloads from the internet during model acquisition. This is the only network-touching operation and happens only once (or when the model is changed). It does not violate the local-only processing principle because it is a setup step, not a processing step.

---

## ADR-006

### Use staged inference with explicit post-processing filters

**Status:** Accepted

**Context:** Whisper produces raw segments that include hallucinations, noise markers, silence placeholders, and repetitive loops. The PRD requires reducing these.

**Decision:** Separate inference from transcript acceptance. Raw Whisper segments are produced first, then filtered through deterministic post-processing rules in TranscriptionFilter.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Rely solely on Whisper decoder settings (temperature, no_speech_threshold) | Decoder settings reduce but do not eliminate hallucinations; post-processing is needed for edge cases |
| Filter during inference (streaming filter) | Couples filtering to the inference lifecycle; prevents logging full candidate results before filtering |
| ML-based hallucination detection | Over-engineering for this use case; deterministic rules are explainable and configurable |

**Trade-offs accepted:**
- Two-pass architecture (infer, then filter) means the full set of raw segments is held in memory before filtering. For typical audio files, this is a negligible memory cost compared to the Whisper model itself.
- Deterministic filters may miss novel hallucination patterns that ML-based detection could catch. The configurable threshold and marker list allows manual tuning when new patterns are observed.

---

## ADR-007

### Optimize language handling for the configured language set

**Status:** Accepted

**Context:** Single-language transcription should be fast. Multi-language transcription must select the best candidate with auditable scoring.

**Decision:**
- Single language: force directly, no comparison pass
- Multiple languages: one inference pass per language, score using duration-weighted segment probability, select winner with configurable ambiguity handling

**Scoring rationale:** Simple average probability is biased by segment count. A long audio file with many short segments would weight each equally regardless of duration. Duration-weighted scoring ensures that a 30-second high-confidence segment counts more than a 0.5-second high-confidence segment.

**Trade-offs accepted:**
- Multi-language mode runs N inference passes (one per language). For 3 languages on a 60-minute file, this means 3x inference time. This is acceptable because: (a) most users configure 1–2 languages, (b) language selection is a correctness concern worth the compute cost, and (c) there is no reliable way to detect language without running inference.

---

## ADR-008

### Fail fast before expensive work starts

**Status:** Accepted

**Context:** Audio conversion, model download, and transcription are long-running operations. Users should not wait minutes only to discover that ffmpeg is missing or the output directory is not writable.

**Decision:** Run a configurable startup validation stage that checks all prerequisites before beginning expensive processing.

**Scope of checks:** 15+ checks covering settings file, input file, output paths, ffmpeg availability, model type validity, model file loadability, Whisper runtime loadability, language support, and batch-specific paths.

**Trade-offs accepted:**
- Startup validation adds 1–3 seconds before processing begins. Some checks (model loadability, Whisper runtime) require loading native libraries, which has a cost.
- Validation is not exhaustive — it checks preconditions, not runtime invariants. A file could become unreadable between validation and processing. The validation reduces but does not eliminate failure during processing.

---

## ADR-009

### Propagate cancellation through the full pipeline

**Status:** Accepted

**Context:** The user must be able to cancel at any point with Ctrl+C, and the application should stop promptly without leaving orphan processes.

**Decision:** Use a single run-scoped CancellationToken, wire it through all async operations, and kill child ffmpeg processes on cancellation.

**Trade-offs accepted:**
- Cancellation is cooperative, not preemptive. Whisper inference checks the token between segments but cannot interrupt mid-segment processing. Cancellation latency depends on segment duration.
- ffmpeg child process is killed explicitly. This means the application must manage process lifecycle, but the alternative (letting ffmpeg run to completion after cancellation) would waste resources and leave the user waiting.

---

## ADR-010

### Reuse the Whisper processing runtime within a run

**Status:** Accepted

**Context:** Native Whisper runtime teardown on macOS has shown instability after multi-language passes. Creating and disposing WhisperFactory per language pass risks native memory issues.

**Decision:** Keep the WhisperFactory alive for the process lifetime. Reuse a single processor across candidate passes within one run. In batch mode, share the factory across files.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Dispose and recreate factory per language pass | Observed native teardown instability on macOS |
| Dispose and recreate factory per file in batch | Same stability concern; also wastes model loading time |
| Use finalizer-based cleanup | Unreliable timing; native resources need deterministic lifecycle |

**Trade-offs accepted:**
- The Whisper factory holds native memory for the entire process lifetime. For a console app that runs, processes, and exits, this is acceptable — the OS reclaims all resources on process exit.
- If the application were long-lived (e.g., a service), this decision would need revisiting.

---

## ADR-011

### Sequential batch file processing

**Status:** Accepted

**Context:** Whisper inference is CPU/GPU-intensive. Parallel processing would require careful memory management, native runtime thread safety analysis, and concurrency control.

**Decision:** Process files sequentially in a single thread. Share the Whisper factory and model across files.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Parallel processing with thread pool | Whisper.net native runtime thread safety is not guaranteed; memory usage would multiply |
| Producer-consumer pipeline (convert while transcribing) | ffmpeg conversion is fast relative to inference; overlapping adds complexity for minimal throughput gain |
| Process-level parallelism (spawn N app instances) | Requires external orchestration; memory usage would be N × model size |

**Trade-offs accepted:**
- Total processing time scales linearly with file count. A 50-file batch takes 50x single-file time.
- This is acceptable for a local tool. If throughput becomes critical, the first step would be producer-consumer pipeline (overlap conversion with inference), not full parallelism.

---

## ADR-012

### Configuration-driven batch mode

**Status:** Accepted

**Context:** The application is fully configuration-driven (ADR-003). Batch mode should follow the same pattern.

**Decision:** Add `processingMode` field and `batch` section in configuration. No CLI argument changes.

**Trade-offs accepted:**
- Switching between single-file and batch mode requires editing the config file. For a tool that processes audio files in defined workflows, this is acceptable — the user is already editing config for paths and settings.

---

## ADR-013

### One result file per input file in batch mode

**Status:** Accepted

**Context:** The single-file output contract is one `.txt` file per run. For batch mode, combining all results would lose file boundaries and make partial results harder to use.

**Decision:** Each input file produces `{name}.txt` in the batch output directory.

**Trade-offs accepted:**
- Many output files in the output directory. For a 100-file batch, this means 100 output files plus a summary. This is the expected and useful behavior for batch processing.

---

## ADR-014

### Continue-on-error with batch summary

**Status:** Accepted

**Context:** A batch of many files should not abort entirely because one file has a corrupt header or unsupported format.

**Decision:** Record the error and continue to the next file. The summary report shows which files succeeded, failed, or were skipped. Configurable via `stopOnFirstError`.

**Trade-offs accepted:**
- The user may not notice a failure until reading the summary. The summary report and exit code (non-zero if any file failed) make this visible, but it requires the user to check.

---

## ADR-015

### Intermediate WAV files use a temp directory in batch mode

**Status:** Accepted

**Context:** In single-file mode, the WAV path is fixed. In batch mode, each file needs its own WAV, and disk usage must stay bounded.

**Decision:** Generate intermediate WAVs in `batch.tempDirectory` (defaults to system temp). Clean up after each file. `keepIntermediateFiles` flag for debugging.

**Trade-offs accepted:**
- Temporary files are deleted immediately after processing. If the user needs to inspect the WAV for debugging, they must enable `keepIntermediateFiles` before the run — they cannot recover WAVs after the fact.
