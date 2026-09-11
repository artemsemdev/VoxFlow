# ADR-009: Bounded file windows and dictation priority

Status: Accepted · Date: 2026-09-11 · Issue: #145

## Context

Files and dictation share one loaded Whisper model. A whole-file `whisper_full` call monopolized
the native serial queue; a sentence dictated during a long file could reach the HUD's 20-second
processing timeout before inference even began.

The pinned [whisper.cpp v1.9.2 API](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/include/whisper.h)
does not promise concurrent use of the same context. Separate model contexts would duplicate
model memory. Neither is needed to give interactive work a turn.

## Decision

- Retain one `WhisperCppEngine`, model context and serial native queue. `fileEngine` is a lower
  priority view of that same engine. Dictation and model loading use the foreground view.
- The queue selects pending dictation before pending file work, FIFO within each role. It never
  interrupts or overlaps an active native call. Enqueueing and selecting the next operation share
  a mutex, so two callers cannot both start an idle worker.
- `FileTranscriber` caps transcription windows at ten seconds and prefers the last 200 ms quiet
  interval after the first three seconds. A final remainder shorter than 200 ms stays with the
  previous window (Whisper's mel-frame rounding skips some requests just above 100 ms), so the
  largest transcription request contains less than 10.2 seconds of audio. Emitted segments shift
  back to absolute file timestamps.
- Auto detection retains the first thirty seconds, matching Whisper's detection context rather
  than narrowing it to the first transcription window. The caller's options remain in effect;
  prior output is not replayed as a new prompt. Fixed cuts produced duplicated phrases in the
  repeated native fixture, and quiet boundaries removed that regression.
- File progress covers the original sample count, and every sample, including a short tail,
  remains in the transcription input. Cancellation is checked between windows.

## Consequences and validation

- Pending file work cannot run ahead of queued dictation. An active file operation finishes, and
  another can start between dictation's detection and inference requests. This bounds the audio
  processed per intervening file operation, not wall-clock inference time: model load,
  hardware contention or a sufficiently slow machine can still exceed the existing timeout.
- Frequent dictation can slow file completion. No new HUD gate or second copy of model weights is
  introduced. Each role supplies its own prompt; upstream defaults reset native prompt history.
- Window cuts may affect recognition at boundaries. The release checklist requires a real
  ten-minute file plus simultaneous TextEdit dictation, including a boundary-quality check.
- Cancelled queued operations skip native work when selected; an already executing native
  transcription still uses its existing abort callback.
- Deterministic tests cover priority/FIFO ordering, concurrent submission, preserved samples,
  absolute timing, progress and a ten-minute fake job whose dictation completes within the
  processing budget while the file remains running, with explicit and automatic language selection.
  A separately gated native test compares repeated-fixture word coverage against batch inference.
