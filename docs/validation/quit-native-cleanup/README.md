# Quit with a resident style model

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
