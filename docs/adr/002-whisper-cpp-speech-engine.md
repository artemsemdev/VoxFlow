# ADR-002: whisper.cpp via XCFramework as the speech engine; streaming dictation is viable

Status: Accepted · Date: 2026-09-08

## Context
The design promises Whisper large-v3-turbo / small on Apple Silicon, text that appears while
speaking, and no network use except model downloads. Candidates: whisper.cpp, WhisperKit
(CoreML), Apple SpeechAnalyzer (macOS 26 only).

## Decision
- whisper.cpp, consumed as the prebuilt XCFramework from the upstream release (`binaryTarget`,
  version and checksum pinned in `Package.swift`; updates are deliberate `chore:` PRs).
- `WhisperCppEngine` is an actor that runs the C API on a private serial queue and streams
  final segments via `new_segment_callback`; cancellation goes through `abort_callback`.
- Models are ggml files downloaded on user action only, checksum-verified, stored in
  `~/Library/Application Support/VoxFlow/Models`.
- Dictation (phase 3) streams: turbo transcribes 16× faster than real time on an M1 Max, so a
  3 s window costs ~0.2 s. Batch is the fallback on slower Macs; small is the 8 GB option.

## Measurements
See `v2/spikes/whisper-perf/README.md`. Turbo: load 0.72 s, RTF 0.063, 1.8 GB RSS; small: 0.20 s,
0.024, 716 MB. First run compiles Metal shaders (~12 s once).

## Alternatives considered
- WhisperKit: faster on ANE for some models, but a second model ecosystem (CoreML bundles) and
  the owner chose ggml for both speech and the style LLM.
- Apple SpeechAnalyzer: no model choice, macOS 26 only; the Models screen would be meaningless.

## Consequences
- The XCFramework ships `parakeet.h`; Parakeet may be reachable later without a new engine.
- Language detection costs ~0.75 s with turbo; the UI must not call it per keystroke.
- The engine holds ~1.8 GB while loaded; unloading on memory pressure is a phase-3 concern.
- Segment confidence is the mean token probability; the language detected by `whisper_full` itself is not surfaced yet (phase 2 decides).
