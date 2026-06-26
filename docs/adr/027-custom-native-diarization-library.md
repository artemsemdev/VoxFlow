# ADR-027: Do Not Build a Custom Native Diarization Library Yet

**Status:** Accepted

**Date:** 2026-06-26

**Related ADRs:** ADR-004, ADR-006, ADR-019, ADR-024

---

## Context

ADR-024 added local speaker labeling through a Python sidecar that runs
`pyannote/speaker-diarization-3.1`, then merges speaker time segments with
Whisper word timestamps in .NET. The architecture keeps transcription local and
isolates the Python runtime from the main VoxFlow process, but it is still a
complex feature:

- It depends on Python, PyTorch, pyannote, model cache setup, and Hugging Face
  access requirements.
- It introduces a second runtime next to .NET and the existing native
  Whisper.net stack.
- It requires careful JSON contract handling, stdout/stderr isolation, timeout
  behavior, and sidecar diagnostics.
- Packaging remains harder than the rest of the app, especially across Apple
  Silicon, Intel macOS, and Linux development environments.

This raises a reasonable question: should VoxFlow write its own diarization
library in the fastest practical programming language and remove the Python
sidecar?

The important distinction is that diarization is not mostly a language-speed
problem. A useful diarization engine includes voice activity detection, speaker
embedding extraction, clustering, overlap handling, speaker count estimation,
and quality evaluation across noisy real-world audio. Most of the runtime cost
is model inference and tensor operations, not the orchestration language. A
custom implementation in Rust, C++, Zig, or C would still need a proven model,
optimized kernels, platform-specific acceleration, and a validation corpus.

Writing the entire ML stack from scratch would reduce one type of complexity
(Python packaging) by adding larger and riskier complexity: model selection,
model conversion or training, numerical correctness, hardware acceleration,
benchmarking, and long-term maintenance.

## Decision

Do **not** replace the ADR-024 speaker-labeling sidecar with a custom native
diarization library in the near term.

Keep the current architecture as the default implementation: pyannote performs
diarization in an isolated local sidecar, and VoxFlow keeps orchestration,
speaker assignment, transcript modeling, and host integration in .NET.

Pursue simplification in two focused tracks instead:

1. **Short-term simplification:** reduce the operational pain of the current
   sidecar by improving setup, preflight diagnostics, model-cache checks,
   timeout messages, and packaging. This keeps the proven diarization model
   while making the user and maintainer experience less fragile.
2. **Native-runtime spike:** evaluate a native diarization engine only as a
   bounded research spike. The spike may use a native host language, but it must
   rely on proven model/runtime components rather than a from-scratch
   diarization algorithm.

If a native path becomes viable, prefer this shape:

- Use **Rust** for VoxFlow-owned native orchestration if VoxFlow needs a new
  maintained native boundary. Rust gives predictable packaging, memory safety,
  good C ABI interoperability, and a lower long-term defect risk than a fully
  hand-written C++ application layer.
- Use existing high-performance inference components for the hot path, such as
  a C/C++ runtime, ONNX Runtime, Core ML, Metal, Accelerate, or another proven
  model execution backend. The numeric kernels should not be invented inside
  VoxFlow.
- Keep the public contract compatible with the current
  `sidecar-diarization-v1` shape or introduce a clearly versioned successor.
  Hosts should continue to depend on speaker segments, not on implementation
  details of the engine.

This means "native" is a packaging and runtime-isolation improvement, not a
license to rebuild the diarization research stack.

## Native-runtime acceptance criteria

A future native engine can replace the Python sidecar only if it satisfies all
of these criteria:

- **Local-only operation:** no cloud inference and no transcript or audio upload.
- **Quality:** diarization quality is measured on representative meeting,
  interview, and call audio and is comparable to or better than the current
  pyannote path.
- **Performance:** end-to-end diarization latency and peak memory are
  materially better than the current sidecar on supported hardware, not just
  faster in microbenchmarks.
- **Packaging:** the runtime can be shipped and updated on supported VoxFlow
  platforms without asking users to manage Python, PyTorch, or model licenses
  manually.
- **Licensing:** the model and runtime licenses are compatible with VoxFlow's
  current and likely future distribution model.
- **Failure isolation:** failures remain enrichment warnings, not transcription
  failures. The plain transcript must still be produced.
- **Testability:** the engine has contract fixtures, deterministic regression
  tests, and benchmark fixtures that can run in CI or in an explicitly gated
  local validation lane.
- **Maintainability:** the implementation is small enough for this project to
  own. If the native code becomes a second ML framework, the spike fails.

## Alternatives considered

| Alternative | Decision | Rationale |
|---|---|---|
| Build a diarization library from scratch in Rust | Rejected | Rust would improve memory safety and packaging, but it does not remove the need for a trained diarization model, optimized inference kernels, clustering quality, and benchmark data. |
| Build a diarization library from scratch in C++ | Rejected | C++ can be fast and close to platform APIs, but it increases memory-safety and maintenance risk. It is only justified for narrowly scoped kernel/runtime integration, not for a whole VoxFlow-owned ML stack. |
| Build a diarization library from scratch in Zig or C | Rejected | These may produce small native binaries, but the ecosystem for ML inference, model conversion, and maintainable application-level integration is weaker for this project than Rust plus proven C/C++ backends. |
| Port pyannote directly to native code | Rejected for now | A direct port would be a large ML engineering project with high correctness risk. Model conversion may be worth spiking, but a manual reimplementation is not. |
| Use a native wrapper around a proven diarization model/runtime | Candidate for future spike | This is the only native direction that could reduce packaging complexity without taking ownership of the whole diarization algorithm. It must meet the acceptance criteria above. |
| Keep the Python sidecar and simplify operations | Accepted | This preserves known diarization quality and the existing ADR-024 boundaries while targeting the part of the implementation that currently hurts most: setup, packaging, and diagnostics. |
| Use cloud diarization | Rejected | It conflicts with VoxFlow's local-first and privacy-first principles. |

## Trade-offs accepted

- VoxFlow keeps Python-sidecar complexity for now instead of replacing it with
  an unproven native engine.
- The project accepts that "fastest language" is not the right primary decision
  metric for diarization. End-to-end quality, packaging, memory use, and
  maintainability matter more.
- A native spike may still happen, but it must be measured against the current
  implementation and must preserve the speaker-labeling contract.
- The current pyannote path remains subject to model licensing and package
  compatibility constraints. If VoxFlow's distribution model changes, this ADR
  should be revisited with licensing as a first-class driver.

## Consequences

- ADR-024 remains the active speaker-labeling architecture.
- Work to reduce diarization complexity should focus first on the existing
  runtime boundary, setup flow, diagnostics, and packaging.
- Any proposal to introduce Rust, C++, Zig, or C for diarization must be framed
  as a measured native-runtime spike with explicit acceptance criteria, not as a
  rewrite based on language performance alone.
- The .NET merge layer, transcript schema, host override pattern, and enrichment
  failure behavior remain stable even if the diarization engine changes later.

## Revisit triggers

Reconsider this decision if one of these becomes true:

- The Python/pyannote path cannot be packaged reliably for supported platforms.
- pyannote licensing blocks the intended VoxFlow distribution model.
- A proven local diarization model becomes available with a supported native
  runtime and compatible license.
- Benchmarks show that a native implementation can materially improve latency
  or memory while matching diarization quality.
- The team has enough ML/runtime ownership capacity to maintain the native
  stack without slowing core VoxFlow product work.
