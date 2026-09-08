# Changelog

All notable changes to VoxFlow are recorded here. The format follows Conventional Commits and semantic
versioning.

## 2.0.0 — 2026-09-08

VoxFlow 2 is a from-scratch native macOS rewrite (Swift 6, SwiftUI, whisper.cpp on Metal). It replaces
the .NET 9 / Mac Catalyst implementation, which is archived on the `v1` branch and tag `v1.0.0-final`.

### Added
- File transcription: drop or open audio/video files (MP3, WAV, M4A/AAC, FLAC, AIFF, CAF, MP4, MOV),
  a queue with progress and ETA, stop and long-audio confirmations, per-file error rows.
- Output formats TXT, SRT, VTT, JSON and Markdown, saved to `~/Transcripts` and re-exportable
  without re-processing (`docs/formats.md`).
- Result view with segments, search, Copy, Save as… and Reveal in Finder.
- Settings › Models: download, pause/resume, checksum verification and removal of Whisper
  large-v3-turbo and Whisper small.
- On-device speech engine over the pinned whisper.cpp v1.9.2 XCFramework; language auto-detection;
  per-segment confidence.

### Changed
- Everything: new architecture (SwiftPM package `VoxFlowKit` + thin SwiftUI app), new CI ladder
  that runs only the tests a change can affect, GitFlow branching.

### Removed
- Speaker labeling / diarization, Intel Mac and Mac Catalyst support, the CLI and the MCP server
  (the MCP server returns in 2.4; the CLI is not planned).

### Not yet
- Dictation into other apps (2.1), main window pages beyond Files (2.2), style cleanup (2.3),
  MCP (2.4), signed and notarized builds (build from source for now).
