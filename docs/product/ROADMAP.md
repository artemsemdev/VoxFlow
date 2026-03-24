# VoxFlow Roadmap

## Goal

Turn the current local transcription CLI and MCP server into a packaged macOS application that is easier to run, easier to trust, and stable enough for a 1.0 release.

## Current Baseline

- CLI transcription pipeline exists (migrated to `VoxFlow.Cli` using Core via DI).
- Batch mode exists.
- MCP server exists (migrated to `VoxFlow.McpServer` using Core interfaces directly).
- Shared core library (`VoxFlow.Core`) extracted with DI registration via `AddVoxFlowCore()`.
- Desktop app (`VoxFlow.Desktop`) in active development — macOS MAUI Blazor Hybrid.
- Phase 1 implementation is in progress.
- Core constraints are already clear:
  - local-only processing,
  - stable text output,
  - configuration-driven behavior,
  - no cloud fallback,
  - no meeting bot behavior,
  - no full editor.

### Phase 1 Technology Decisions

| Decision | Choice | ADR |
|----------|--------|-----|
| Shared library architecture | `VoxFlow.Core` with instance-based DI services | ADR-019 |
| Progress reporting | `IProgress<ProgressUpdate>` for host-agnostic callbacks | ADR-020 |
| Desktop UI framework | .NET MAUI Blazor Hybrid | ADR-021 |
| Desktop navigation | Contextual flow (screen IS the state) | ADR-022 |
| MCP integration | Direct Core interface injection (facades eliminated) | ADR-023 |

## Practical Rules

- Keep CLI and MCP working while adding desktop support.
- First supported desktop platform is macOS.
- Desktop UI should use Blazor Hybrid in a native desktop shell.
- MCP stays supported, but it is not part of the Phase 1 desktop UI.
- Do not add work that does not improve transcription, packaging, outputs, docs, or stability.
- Keep the output contract and local-first behavior intact.

## Non-Goals

- Cloud inference
- Meeting bot behavior
- Collaboration features
- Full transcript editor
- Speaker diarization
- Translation
- Enterprise admin
- Speculative marketing or ecosystem work

## Phase Summary

| Phase | Focus | Main Work | Done When |
|---|---|---|---|
| [Phase 1](./Phase%201.md) | Shared core, desktop minimum, packaging, first run | Move all current PRD features behind shared services, keep CLI and MCP working, add a macOS-first Blazor Hybrid desktop app with code signing, package it, ship install docs, and make first run and trust signals usable | A signed macOS user can install from a release, validate the environment, run single-file transcription, and review the result |
| [Phase 2](./Phase%202.md) | Repeat-use features | Presets, structured outputs, run metadata, bundle layout, batch desktop UI, auto-update, transcript workspace | Repeated runs need less manual setup and produce reusable artifacts |
| [Phase 3](./Phase%203.md) | Integration guides and external polish | MCP quickstarts for named clients, screenshots, API reference, release notes | A new user can integrate MCP and understand outputs by following the docs |
| [Phase 4](./Phase%204.md) | Stabilization and 1.0 | QA matrix, performance profiling, accessibility audit, bug fixing, supported-scope doc, release candidate | 1.0 can be released with an explicit supported scope and verified resource requirements |

## Why This Order

1. Phase 1 first because desktop, packaging, and first run depend on the same shared core.
2. Phase 2 second because repeat-use features matter only after install and first run work.
3. Phase 3 third because integration guides and external polish should describe a real product, not future ideas.
4. Phase 4 last because 1.0 should be based on QA and real behavior, not narrative.

## Versioning and Release Strategy

- Follow semantic versioning: 0.x during pre-1.0 phases, 1.0.0 at release.
- Each phase should produce at least one tagged pre-release (e.g., 0.1.0-alpha for Phase 1, 0.2.0-beta for Phase 2).
- Documentation updates ship with the code they describe, not in a later phase.

## Roadmap Exit Criteria

The roadmap is complete when:

- a packaged macOS desktop app exists,
- CLI and MCP still work,
- install from a release works without reading source code,
- outputs include the current text format plus only the additional formats that are actually needed,
- docs cover install, first run, outputs, batch behavior, and MCP,
- and the QA matrix passes for the declared 1.0 scope.
