# Quit with resident speech and style models

The initial style-only fix was incomplete: it passed launch/quit checks before Whisper had
loaded. A subsequent report from that exact build crashed in the copy of GGML statically linked
with Whisper into VoxFlow, after speech recognition had been used. Both engine owners must be
drained before AppKit exits; testing only the prewarmed style model cannot establish that.

## Combined engine regression

`tools/NativeShutdownProbe` is a standalone validation package, not part of the shipped app.
It retains both actual engine owners for the process lifetime, loads the installed models,
detects language, transcribes the neutral repository fixture through dictation (with VAD) and
file paths, generates a short style reply, and then performs shutdown before normal process exit.

```sh
swift run --package-path tools/NativeShutdownProbe \
  --scratch-path /tmp/voxflow-native-shutdown-build NativeShutdownProbe \
  "$HOME/Library/Application Support/VoxFlow/Models/ggml-large-v3-turbo.bin" \
  "$HOME/Library/Application Support/VoxFlow/Models/qwen2.5-3b-instruct-q4_k_m.gguf" \
  VoxFlowKit/Tests/VoxFlowSpeechTests/Fixtures/attention-10s.wav
```

Before implementing Whisper shutdown, this probe aborted with `SIGABRT` (shell status 134)
in `ggml_metal_rsets_free` despite style cleanup completing. With both engines released, it
exits with status 0. A new deterministic test initially recorded three failures for retained
speech resources and accepted reloads. Further tests cover late load completion, queued
work from both priorities, and an already-detached context whose native free is still running.

## Original style-model report

The reported crash reaches `QuitCoordinator.request()` → AppKit termination → C++ process
destructors → `ggml_metal_rsets_free`, where llama.cpp b10881 asserts that no Metal residency
sets remain. `AppServices` retains the warmed-up style model for the application lifetime;
ordinary process exit does not run an awaited Swift unload.

## Native reproduction

A separate command-line probe links the same installed `llama.framework`, loads the installed
Qwen2.5 3B model with production context parameters (2048 context, 512 batch, 99 GPU layers),
and returns from `main`. It does not access recordings, history or other personal data.

- Retain the context/model through exit: `SIGABRT` (subprocess return code −6), at the exact
  reported assertion, `GGML_ASSERT([rsets->data count] == 0)`.
- Call `llama_free(context)` then `llama_model_free(model)` before exit: return code 0.

The pinned [upstream implementation](https://github.com/ggml-org/llama.cpp/blob/b10881/ggml/src/ggml-metal/ggml-metal-device.m#L1015)
requires resources to be deallocated before this destructor. No native dependency bump or
assertion suppression is needed.

## Regression coverage

- Tests first: the new idle-quit and loaded-model shutdown checks recorded five failures with
  no-op cleanup; both pass with the terminal cleanup barrier.
- Quit choices preserve save/cancel semantics, await cleanup before termination, and coalesce
  repeated requests while cleanup is suspended.
- Loader tests cover a resident model, a late warm-up result, held native unload, active
  generation cancellation, caller cancellation propagation, idempotence and blocked reloads.
- Existing native model generation/release checks still pass. On local Xcode 27, the unchanged
  llama.cpp Metal compiler emits unused-symbol warnings during real-model integration tests;
  keep these visible and separate from the app-only regression/build warning checks.
