# Architecture Decision Log

> ADR-style records for the most significant design decisions. Each record includes the decision, context, alternatives considered, and trade-offs accepted.

## Index

| ADR | Decision | Status |
|-----|----------|--------|
| [001](#adr-001) | Local-only console architecture | Superseded by ADR-019 |
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
| [016](#adr-016) | MCP server as separate host with InternalsVisibleTo | Superseded by ADR-023 |
| [017](#adr-017) | Stdio-only MCP transport | Accepted |
| [018](#adr-018) | Path policy for MCP tool arguments | Accepted |
| [019](#adr-019) | Extract shared VoxFlow.Core library with DI | Accepted |
| [020](#adr-020) | Use IProgress&lt;T&gt; for host-agnostic progress reporting | Accepted |
| [021](#adr-021) | Blazor Hybrid for macOS desktop UI | Accepted |
| [022](#adr-022) | ViewModel-driven desktop state flow | Accepted |
| [023](#adr-023) | Eliminate InternalsVisibleTo in favor of shared library | Accepted |

---

## ADR-001

### Use a local-only console architecture

**Status:** Superseded by [ADR-019](#adr-019)

**Context:** The product requirement is fully local, privacy-first audio transcription. No audio data should leave the machine.

**Decision:** Build a single-process .NET 9 console application. No web server, no API, no cloud integration, no IPC.

**Superseded:** The system is no longer console-only. ADR-019 introduces a shared `VoxFlow.Core` library with three host applications (CLI, MCP Server, Desktop). The local-only and privacy-first principles remain unchanged — the architecture evolved from a single console app to a multi-host architecture sharing a common core.

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

---

## ADR-016

### MCP server as a separate host with InternalsVisibleTo

**Status:** Superseded by [ADR-023](#adr-023)

**Context:** The [ROADMAP](../product/ROADMAP.md) calls for exposing VoxFlow transcription capabilities to AI clients (Claude, ChatGPT, GitHub Copilot, VS Code) via the Model Context Protocol. The MCP SDK (`ModelContextProtocol` NuGet v1.1.0) requires a DI-based composition root with constructor injection, while VoxFlow uses static services.

**Decision:** Create a separate .NET 9 console application (`WhisperNET.McpServer`) that references `VoxFlow.csproj` and accesses internal types via `InternalsVisibleTo`. Application facades bridge static services to DI-compatible interfaces. Host-agnostic DTOs decouple MCP tool schemas from internal service signatures.

**Superseded:** The introduction of `VoxFlow.Core` as a shared library (ADR-019) eliminated the need for `InternalsVisibleTo` and application facades. The MCP server now injects Core interfaces directly via DI, just like the CLI and Desktop hosts. See ADR-023 for details.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Full project restructuring (extract shared library) | High-risk refactoring for a first integration; the CLI host would need to change for no user-facing benefit |
| Public API surface on VoxFlow | Would expose internal types permanently; harder to evolve |
| Process-level IPC (pipe VoxFlow CLI output to MCP server) | Fragile string parsing; loses type safety; harder to test |
| Embed MCP host in the VoxFlow CLI | Would couple the CLI to MCP SDK dependencies; Console.SetOut redirect would break existing CLI output |

**Trade-offs accepted:**
- `InternalsVisibleTo` creates a compile-time coupling between VoxFlow and the MCP server. Internal API changes in VoxFlow can break the MCP server. This is acceptable because both projects are in the same repository and tested together.
- Application facades add a thin wrapper layer. This is minimal overhead and provides the boundary needed for future evolution toward a shared application core.

---

## ADR-017

### Stdio-only MCP transport

**Status:** Accepted

**Context:** The MCP specification supports both stdio and HTTP/SSE transports. VoxFlow is a local-only, privacy-first tool.

**Decision:** Support only stdio transport for the MCP server. The AI client launches the MCP server as a child process and communicates over stdin/stdout.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| HTTP/SSE transport | Introduces network surface area; conflicts with local-only design principle; requires port management and security headers |
| Both stdio and HTTP | Doubles the transport surface; no current requirement for remote access |

**Trade-offs accepted:**
- The MCP server can only be used by local AI clients that support stdio transport. Remote AI clients cannot connect. This is consistent with VoxFlow's local-only architecture.
- Console output from VoxFlow services must be redirected to stderr (`Console.SetOut(Console.Error)`) to protect the stdout MCP protocol stream.

---

## ADR-018

### Path policy for MCP tool arguments

**Status:** Accepted

**Context:** MCP tools accept file paths as arguments from AI clients. Unlike the CLI (where the operator provides paths directly), MCP tool arguments come from a semi-trusted source — an AI model that may hallucinate paths or be manipulated.

**Decision:** Implement `PathPolicy` to validate all file paths from MCP tool arguments against configurable allowed input/output root directories. Reject paths that use traversal patterns, are not absolute (when configured), or fall outside allowed roots.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| No path validation (trust AI client) | Security risk; AI clients may provide arbitrary paths |
| Sandbox via file system permissions | OS-level enforcement is coarser; does not provide application-level error messages |
| Allowlist of specific files | Too restrictive; users need directory-level access for batch workflows |

**Trade-offs accepted:**
- When allowed roots are empty (`[]`), any absolute path is accepted. This is the permissive default for local-only use. Operators can restrict roots in `appsettings.json` for tighter security.
- Path validation adds a small overhead to every tool invocation. This is negligible compared to the transcription pipeline.

---

## ADR-019

### Extract shared VoxFlow.Core library with DI

**Status:** Accepted

**Context:** With three host applications (CLI, MCP Server, Desktop), the previous approach of static services in a single project with `InternalsVisibleTo` for the MCP server was no longer sustainable. Each host needs the same transcription services, and duplicating or bridging them via facades creates maintenance burden and fragile coupling.

**Decision:** Extract all business logic into a shared `VoxFlow.Core` class library. Convert static services to instance-based services implementing interfaces. Register all services through a single `AddVoxFlowCore()` extension method. Each host project references `VoxFlow.Core` and calls `AddVoxFlowCore()` in its DI setup.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Keep static services, add more facades | Facades for three hosts would triple the wrapper layer; maintenance cost exceeds DI overhead |
| Shared project (linked files) | Does not provide a clean compilation boundary; harder to reason about dependencies |
| NuGet package for Core | Over-engineering for a single repository; adds packaging and versioning complexity |
| Keep InternalsVisibleTo for all hosts | Breaks encapsulation further; any internal change can break any host |

**Trade-offs accepted:**
- DI adds ceremony (interface definitions, registration code, constructor injection) compared to direct static method calls. This is now justified by three hosts sharing the same services.
- Existing static method call patterns in `Program.cs` were replaced with service interface calls. This changes the code style but improves testability via mocking.

**Supersedes:** [ADR-001](#adr-001) (no longer console-only architecture)

---

## ADR-020

### Use IProgress&lt;T&gt; for host-agnostic progress reporting

**Status:** Accepted

**Context:** The CLI renders progress as an ANSI progress bar in the console. The Desktop app renders progress as a Blazor UI update. The MCP server suppresses progress. Core services must report progress without knowing which host is consuming it.

**Decision:** Core services accept `IProgress<ProgressUpdate>` as a parameter. Each host provides its own implementation: `ConsoleProgressService` for CLI, a Blazor-bound handler for Desktop, and a no-op for MCP.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Events / delegates on service classes | Couples Core services to a specific eventing pattern; harder to compose |
| IObservable&lt;T&gt; / Rx | Adds Reactive Extensions dependency for a simple one-way notification pattern |
| Shared progress service interface in Core | Would require Core to define UI-aware abstractions; `IProgress<T>` is already in the BCL |
| No progress from Core (host polls) | Polling is wasteful and introduces latency in progress updates |

**Trade-offs accepted:**
- `IProgress<T>` is push-based, so Core services must call `Report()` at appropriate intervals. If a host does not care about progress, it still receives (and discards) the callbacks. The overhead is negligible.
- `ProgressUpdate` must be a Core-defined type that carries enough information for any host to render, without being tied to any host's rendering model.

---

## ADR-021

### Blazor Hybrid for macOS desktop UI

**Status:** Accepted

**Context:** The product needs a macOS desktop application for visual transcription workflow. The team has .NET expertise and the Core library is already .NET 9.

**Decision:** Use .NET MAUI Blazor Hybrid to build the desktop application. Blazor components run inside a native macOS WebView, providing web-standard UI with native shell integration.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Native SwiftUI / AppKit | Requires Swift/Obj-C expertise; cannot share .NET types with Core |
| Electron + TypeScript | Adds Node.js runtime; cannot share .NET types without IPC bridge |
| Avalonia UI | Mature cross-platform .NET UI, but less ecosystem support than MAUI; Blazor Hybrid allows web skill reuse |
| MAUI without Blazor (XAML) | XAML tooling for macOS is less mature; Blazor provides better component model for this workflow |
| Terminal UI (Spectre.Console) | Would not satisfy the "desktop app" requirement; limited interaction model |

**Trade-offs accepted:**
- Blazor Hybrid renders in a WebView, which has slightly higher resource usage than native UI. For a developer tool with simple screens, this is acceptable.
- MAUI macOS support is less mature than iOS/Android. Some platform-specific workarounds may be needed.
- Dark theme requires explicit CSS/styling rather than automatic OS theme inheritance. This is managed with a custom dark theme stylesheet.

---

## ADR-022

### ViewModel-driven desktop state flow

**Status:** Accepted

**Context:** The desktop app has a small single-window workflow: startup initialization, ready state, running state, failure recovery, and completion. The UI needs clear state transitions without overbuilding router/navigation infrastructure.

**Decision:** Use a lightweight ViewModel-driven state model. `Routes.razor` only handles startup initialization and retry on fatal initialization errors. After initialization, `MainLayout.razor` switches between `ReadyView`, `RunningView`, `FailedView`, and `CompleteView` based on `AppViewModel.CurrentState`.

**Alternatives considered:**

| Alternative | Why rejected |
|------------|-------------|
| Formal state machine (Stateless library) | Adds a dependency and abstraction layer for a small workflow with simple transitions |
| Router-based navigation (URL-driven) | URL-style routing adds indirection to a single-window desktop app that does not expose deep links |
| Tab-based layout | The workflow is sequential, not parallel; tabs suggest simultaneous access to all screens |
| Single-page with show/hide sections | Becomes harder to reason about as startup, running, failure, and completion states diverge |

**Trade-offs accepted:**
- The current state model works well for one primary flow but should be revisited if Desktop grows into multi-task workflows such as batch monitoring or concurrent jobs.
- `AppViewModel` owns more UI state than a pure routing model would, but the trade-off is acceptable at the current scope (`Ready`, `Running`, `Failed`, `Complete`, plus a startup-error surface).

---

## ADR-023

### Eliminate InternalsVisibleTo in favor of shared library

**Status:** Accepted

**Context:** The MCP server previously accessed VoxFlow internals via `InternalsVisibleTo` and bridged static services with application facades (ADR-016). With `VoxFlow.Core` extracted as a shared library (ADR-019), this indirection is no longer needed.

**Decision:** Remove `InternalsVisibleTo` from all projects. Remove application facades from the MCP server. The MCP server now injects `VoxFlow.Core` interfaces directly, exactly like the CLI and Desktop hosts. All types consumed by host projects are public in `VoxFlow.Core`.

**What was removed:**
- `InternalsVisibleTo` assembly attributes
- `IStartupValidationFacade`, `ITranscriptionFacade`, `IModelInspectionFacade`, `ILanguageInfoFacade`, `ITranscriptReaderFacade` facade interfaces and implementations
- Application contract DTOs that existed only to bridge facades to MCP tools

**What replaced them:**
- Core service interfaces (`ITranscriptionService`, `IValidationService`, etc.) consumed directly by MCP tools
- Core model types used directly in MCP tool responses

**Trade-offs accepted:**
- MCP tools now depend on Core interfaces rather than MCP-specific facade interfaces. If Core interfaces change, MCP tools must update. This is the same coupling that CLI and Desktop have, which is acceptable for a single-repository project.

**Supersedes:** [ADR-016](#adr-016) (InternalsVisibleTo + facades eliminated)
