# VoxFlow

## Executive Summary

VoxFlow is a fully local, privacy-first audio transcription system that converts speech recordings into timestamped text transcripts without sending data to any external service. It ships as a shared .NET 9 transcription core with three hosts: CLI, macOS Desktop, and MCP. Transcription runs entirely on-device via Whisper.net.

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
- `VoxFlow.Desktop` -- macOS MAUI Blazor Hybrid desktop host for single-file transcription workflow
- `VoxFlow.McpServer` -- stdio MCP host exposing transcription tools to AI clients

The shared pipeline remains configuration loading, startup validation, ffmpeg-based audio conversion, local Whisper inference via Whisper.net 1.9.0, post-processing filters, and file output.

## Current Repository Status

- CLI and Core processing are verified locally, including real sample inputs in `artifacts/Input/Test 1.m4a` and `artifacts/Input/Test 2.m4a`.
- Desktop now has headless Razor UI/component tests covering startup, validation, progress, settings, copy-to-clipboard, `DropZone`, and real-audio browse flow at the `ReadyView` level.
- Desktop is still under stabilization. The integrated `Routes`-based root shell currently has open UI integration failures around the full `Browse Files` flow, even though the direct `ReadyView -> DropZone -> AppViewModel -> VoxFlow.Core` path is passing.

## Project Documentation

| Document | Purpose |
|---|---|
| [SETUP.md](SETUP.md) | Technical setup, local development, and operations |
| [docs/architecture/](docs/architecture/) | Detailed architecture views and ADRs |
| [PRD.md](docs/product/PRD.md) | Product requirements document |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Architecture decisions and system design |
| [ROADMAP.md](docs/product/ROADMAP.md) | Feature implementation roadmap |

For technical setup, local development, and operations, please see [SETUP.md](SETUP.md).
