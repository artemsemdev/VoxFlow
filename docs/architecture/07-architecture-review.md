# Architecture Review Summary

> An honest assessment of the current design — what works well, what was deliberately kept simple, and where the architecture would evolve under different requirements.

## Executive Summary

VoxFlow is a multi-host .NET 9 system for fully local audio transcription. The architecture consists of a shared core library (`VoxFlow.Core`) consumed by three host applications: a CLI for command-line workflows, an MCP server for AI client integration, and a macOS Blazor Hybrid desktop app for visual transcription workflows. All hosts share the same core pipeline and service contracts via dependency injection, while the Desktop host can swap in a local CLI bridge on Intel Mac Catalyst without forking the transcription logic.

The design demonstrates intentional architectural evolution. What started as a single console application grew to accommodate MCP integration (via facades and InternalsVisibleTo) and then evolved to a proper shared library when a third host (Desktop) justified the restructuring. Boundaries are drawn at meaningful points, trade-offs are explicit, and the codebase is testable through interface-based DI.

## What the Architecture Gets Right

### 1. Boundaries are at the right level of granularity

The module structure follows natural domain boundaries:

- **Audio preprocessing** (ffmpeg) is isolated from **inference** (Whisper.net), which is isolated from **post-processing** (filtering). Each can change independently.
- **Configuration** is loaded once and frozen. No module can accidentally change another module's behavior.
- **Orchestration** lives in one place (`Program.cs`). Business logic does not leak into the entry point, and modules do not orchestrate themselves.

This is a better design than either monolithic (everything in `Program.cs`) or over-decomposed (interfaces and DI for a tool with one execution path).

### 2. Fail-fast validation is a first-class architectural concern

Startup validation is not a utility function — it is a dedicated service with its own report type, check statuses, and console presentation. This signals that the designer treats operational reliability as an architectural concern, not an afterthought.

The 15+ preflight checks cover the full dependency chain: config, file system, ffmpeg, model, Whisper runtime, and language support. Each check has a specific status (Passed, Warning, Failed, Skipped) and a human-readable message.

### 3. The filtering pipeline is explainable

TranscriptionFilter does not just accept or reject segments. It returns a `CandidateFilteringResult` with typed skip reasons (`SegmentSkipReason` enum) for every rejected segment. This makes the filter's behavior auditable and debuggable — a user can see exactly why a segment was dropped.

The seven filtering stages (empty text, noise markers, bracketed placeholders, low probability, low-information long segments, suspicious non-speech, repetitive loops) represent a careful study of Whisper's actual failure modes, not generic text filtering.

### 4. Batch mode reuses the pipeline without duplicating it

Batch processing shares the same per-file pipeline as single-file mode. The batch loop adds:
- File discovery and path mapping
- Error isolation per file
- Summary reporting
- Temp file lifecycle management

This is the correct abstraction level — batch mode is a loop around the existing pipeline, not a separate pipeline.

### 5. The test strategy matches the architecture

Each architectural boundary has corresponding test coverage:
- Pure functions (filtering, scoring, output formatting) are unit tested directly
- I/O-dependent modules (startup validation, file discovery) use temp directories
- External dependencies (ffmpeg) are replaced with fakes that produce valid output
- Full application behavior is covered by end-to-end tests

The test support utilities (`FakeFfmpegFactory`, `TestWaveFileFactory`, `TemporaryDirectory`, `TestSettingsFileFactory`) are thoughtful — they provide deterministic test infrastructure without requiring mocking frameworks.

### 6. Multi-host architecture shares Core without duplication

All three hosts (CLI, MCP Server, Desktop) use `VoxFlow.Core` via a single `AddVoxFlowCore()` DI registration. Each host contains only its specific concerns:

- **CLI:** Console progress rendering, exit code mapping
- **MCP Server:** Stdio transport, path policy enforcement, MCP tool/prompt definitions
- **Desktop:** Blazor UI, AppViewModel, Desktop config merge, macOS native shell, Intel CLI bridge

This validates the architecture's extensibility: three hosts share the same pipeline without any business logic duplication, facade layers, or `InternalsVisibleTo` hacks.

## Deliberate Simplicity

These are areas where the design intentionally avoids added complexity:

### DI is lightweight and justified

The system now uses dependency injection with `Microsoft.Extensions.DependencyInjection`, but keeps the DI usage simple:
- One registration entry point (`AddVoxFlowCore()`) — no complex module systems or auto-registration
- Constructor injection only — no service locator, no property injection, no factory patterns
- Simple lifetimes — services are singletons or transient; no scoped lifetimes needed
- The DI container is justified by three hosts sharing the same services. This is the "third host" trigger identified in the previous architecture review.

**What changed:** The previous architecture used static services and no DI container. With the addition of the Desktop host (the third host), the evolution from static to DI-based services was triggered — exactly as predicted in the architecture review's evolution table.

### No logging framework

The application writes directly to `Console.Error` and `Console.Out`. There is no ILogger, no structured logging, no log levels. This works because:
- The application runs interactively in a terminal — console output is the primary feedback channel
- There is no need for log aggregation, alerting, or machine-parseable log output
- The startup validation report and batch summary already provide structured diagnostic output

### No async pipeline / middleware pattern

The processing stages are called sequentially in `Program.cs`, not composed as a middleware pipeline. This works because:
- The stage ordering is fixed and unlikely to change
- There are no cross-cutting concerns (auth, retry, circuit breaker) that middleware patterns address
- The sequential call chain in Program.cs is readable and debuggable

## Where the Architecture Would Evolve

These are not weaknesses — they are design boundaries that would shift under different requirements.

| Trigger | Current State | Evolution |
|---------|--------------|-----------|
| ~~MCP server integration~~ | ~~Static services, no DI~~ | **Done** — MCP server added as separate host (ADR-016), later evolved to shared Core (ADR-019) |
| ~~Third host or shared library~~ | ~~InternalsVisibleTo + facades~~ | **Done** — `VoxFlow.Core` extracted with DI interfaces (ADR-019); facades and InternalsVisibleTo eliminated (ADR-023) |
| ~~Desktop application~~ | ~~No GUI~~ | **Done** — macOS Blazor Hybrid desktop app added (ADR-021) with contextual flow navigation (ADR-022) |
| HTTP/SSE MCP transport | Stdio-only | Add HTTP transport option; requires auth, CORS, port management |
| Parallel batch processing | Sequential loop | Producer-consumer pipeline; ffmpeg conversion overlapped with inference |
| Multiple transcription backends | Whisper.net hardcoded | Backend interface; factory-based selection |
| Structured output formats | Plain text only | Output format strategy; JSON/CSV writers alongside plain text |
| Watch mode / continuous processing | Run-once exit | File system watcher; process lifecycle management |
| Plugin system for filters | Hardcoded filter stages | Filter chain with configurable stage ordering |
| Linux/Windows desktop support | macOS only | Platform-specific MAUI targets; may require UI adjustments |

Each of these would be driven by a concrete requirement, not added speculatively. The current architecture does not prevent any of them.

## Architectural Fitness Indicators

How to know the architecture is working:

| Indicator | What to watch | Current status |
|-----------|---------------|----------------|
| **Change locality** | A new feature touches ≤ 2 modules | Desktop added as new host project — Core unchanged; MCP migration to shared Core touched only host-level code |
| **Host independence** | Adding a new host requires only host-specific code | Three hosts (CLI, MCP, Desktop) share Core via `AddVoxFlowCore()`; Desktop-specific Intel compatibility lives in the Desktop host rather than Core |
| **Test independence** | Unit tests run without external dependencies | All unit tests use generated fixtures, fake externals, and interface mocks |
| **Startup time** | Validation completes in < 5 seconds | 15+ checks complete in 1–3 seconds |
| **Failure clarity** | Every failure produces an actionable message | Startup validation, filter skip reasons, batch summary, Desktop warning banners, failure screens, and CLI-bridge error parsing all provide specific messages |
| **Dependency count** | External dependencies stay minimal | Core: 2 runtime deps (ffmpeg, Whisper.net); hosts add their specific deps (MCP SDK, MAUI, etc.) |

## Conclusion

This architecture has evolved appropriately as the product grew from a single CLI to a multi-host system. It prioritizes privacy, reliability, and operational clarity while now supporting three distinct host applications through a shared core library.

The strongest signal of architectural maturity is that the evolution followed the predicted path: the architecture review identified "third host" as the trigger for extracting a shared Core library, and that is exactly what happened when the Desktop app was added. The DI overhead is now justified by three hosts, interfaces enable testing, and `IProgress<ProgressUpdate>` cleanly decouples Core from host-specific rendering. Structure was added when it earned its cost — not before.
