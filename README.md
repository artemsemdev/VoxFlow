# VoxFlow

## Executive Summary

VoxFlow is a fully local, privacy-first audio transcription system that converts speech recordings into timestamped text transcripts without sending data to any external service. It ships as a shared .NET 9 transcription core with three hosts: CLI, macOS Desktop, and MCP. Transcription runs entirely on-device via Whisper.net, and the Desktop app can fall back to the same local CLI pipeline on Intel Mac Catalyst when the in-process Whisper runtime is not viable.

## The Problem & The Solution

**Problem:** Transcribing audio recordings manually is time-consuming and error-prone. Cloud-based transcription services raise privacy and compliance concerns, especially for sensitive recordings such as interviews, meetings, or legal proceedings.

**Solution:** This utility runs the entire transcription pipeline locally on the user's machine. Audio files are preprocessed, noise-filtered, and transcribed using a local Whisper model. The result is a clean, timestamped transcript file ready for review or downstream processing.

## Target Audience

- Professionals who need transcripts of meetings, interviews, or recorded calls
- Teams operating under data-privacy or compliance constraints that prohibit cloud transcription
- Developers and researchers who want a scriptable, configuration-driven transcription tool

## Key Business Capabilities

- **Single-file transcription** -- point the tool at one audio file and get a timestamped transcript
- **Batch processing** -- point the tool at a directory and transcribe all matching files in one run, with a completion summary report
- **Multi-language support** -- configure one or more candidate languages; the tool auto-selects the best match when multiple are provided
- **Audio preprocessing** -- built-in noise reduction and silence removal improve transcript quality before the model runs
- **Configurable quality controls** -- fine-tune segment filtering, hallucination suppression, and confidence thresholds to match your audio characteristics
- **Startup validation** -- a preflight check verifies all paths, dependencies, and model availability before processing begins
- **MCP server integration** -- expose transcription capabilities to AI clients (Claude, ChatGPT, GitHub Copilot, VS Code) via the Model Context Protocol
- **Fully offline** -- no network calls, no API keys, no data leaves the machine

## High-Level Architecture

VoxFlow is a .NET 9 solution with one shared processing library and three hosts:

- `VoxFlow.Core` -- shared configuration, validation, transcription, batch processing, and output pipeline
- `VoxFlow.Cli` -- thin command-line host over `VoxFlow.Core`
- `VoxFlow.Desktop` -- macOS MAUI Blazor Hybrid desktop host for single-file transcription workflow; on Intel Mac Catalyst it delegates transcription to a local CLI bridge
- `VoxFlow.McpServer` -- stdio MCP host exposing transcription tools to AI clients

The shared pipeline remains configuration loading, startup validation, ffmpeg-based audio conversion, local Whisper inference via Whisper.net 1.9.0, post-processing filters, and file output.

## Current Repository Status

- CLI, Core, and MCP all run against the shared `VoxFlow.Core` pipeline and are covered by dedicated test projects.
- Desktop is a macOS MAUI Blazor Hybrid single-file transcription app with four runtime states: `Ready`, `Running`, `Failed`, and `Complete`.
- Desktop has both headless component tests in `tests/VoxFlow.Desktop.Tests` and real macOS UI automation in `tests/VoxFlow.Desktop.UiTests`.
- The real Desktop happy path is green end-to-end: app launch, `Browse Files`, running state, transcript completion, and result actions are exercised against the actual `.app`.
- On Intel Mac Catalyst, Desktop routes transcription through the local `VoxFlow.Cli` host so the UI uses the same working transcription pipeline as CLI while keeping all processing on-device.
- Desktop Phase 1 stabilization is complete: Ready-screen copy is accurate (multi-format, local-only, single-file), file intake is guarded by validation state, drag-and-drop works through the visible drop zone, dropped files are staged locally without exposing internal temp names in the UI, transient state is cleared on new runs and cancellation, progress shows numeric percent with human-readable stage labels and progressbar accessibility, transcript copy sends the full file (not preview), action errors are surfaced non-fatally, and non-blocking startup warnings are visible.

## Project Documentation

| Document | Purpose |
|---|---|
| [SETUP.md](SETUP.md) | Technical setup, local development, and operations |
| [docs/architecture/](docs/architecture/) | Detailed architecture views and ADRs |
| [PRD.md](docs/product/PRD.md) | Product requirements document |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Architecture decisions and system design |
| [ROADMAP.md](docs/product/ROADMAP.md) | Feature implementation roadmap |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution workflow, quality bar, and review expectations |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Community behavior expectations and enforcement model |
| [SECURITY.md](SECURITY.md) | Vulnerability reporting and supported-version policy |
| [LICENSE](LICENSE) | MIT license for source and documentation |

For technical setup, local development, and operations, please see [SETUP.md](SETUP.md).
