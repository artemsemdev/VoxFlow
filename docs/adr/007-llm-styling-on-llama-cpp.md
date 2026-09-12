# ADR-007: LLM styling on llama.cpp (Qwen2.5 3B)

Status: Accepted · Date: 2026-09-09

## Context

ADR-005 built the `TextStyler` seam specifically so that phase 4a's deterministic
`RuleStyler` could later be joined by an LLM-backed styler without touching storage,
`StyledTranscriber` or History — "phase 5 adds an LLM-backed styler behind the same
protocol; no other layer needs to change." Phase 5 (#112) is that swap: Formal, Casual
and Very casual are rewritten by an on-device LLM (Qwen2.5 3B Instruct, 4-bit GGUF)
through llama.cpp, while Verbatim and the rule pre-pass (fillers, auto-punctuation) stay
exactly as ADR-005 left them. Three surfaces exercise the result: the live dictation path
(canvas MW-05 Styles page, styled in real time as text is inserted), "Re-style ▾" on
History rows (canvas MW-02s — rewrite a stored dictation into another tone without
re-recording), and "Apply {Style} cleanup" on the Files result (canvas 2f — a checkbox
that rewrites every segment of a finished file transcript).

## Decision

- **Seam change (ruling 1).** `TextStyler.style(_:options:)` becomes `async throws` so
  the LLM path can await generation without blocking. `RuleStyler` keeps a synchronous
  body (`styleSync`) behind the now-`async` signature — it is still the only implementation
  Files uses, and the fallback every other caller falls back to. `StyledTranscriber` awaits
  the call; no other layer in the ADR-005 pipeline (storage, History, `SnippetExpander`,
  `StyleResolver`) changes shape.
- **Rule pre-pass, then LLM tone rewrite (ruling 2).** The LLM never sees raw dictation.
  `RuleStyler` runs first with `style: .casual`, honouring the global `removeFillers` /
  `autoPunctuate` toggles, and supplies `fillersRemoved`; the LLM receives that pre-passed
  text and rewrites only the tone. Verbatim never reaches the LLM at all — it is the
  rule pipeline's early-return case, unchanged since ADR-005.
- **Fallback matrix.** Every one of the following returns the rule-based result for the
  requested tone instead of the LLM's: the backend isn't ready (model absent or still
  loading), the pre-passed text exceeds 150 words, generation throws, generation exceeds
  the remaining processing budget (at most 8 s), or the output fails validation (empty; under 30% or over 300% of the input's word
  count; identical to the prompt; contains `<|im_`). A dictation — or a Re-style, or a
  Files cleanup — is never lost to a model problem; it degrades to the same deterministic
  output ADR-005 already shipped.
- **Determinism.** Greedy sampling (`llama_sampler_init_greedy`, no temperature), `n_ctx
  2048`, `n_batch 512`, `threads = min(8, activeProcessorCount)`, all layers on Metal
  (`n_gpu_layers = 99`), `maxNewTokens = min(words × 3 + 32, 768)`. The prompt is built
  through the model's own chat template (`llama_model_chat_template` +
  `llama_chat_apply_template`) rather than a hand-rolled ChatML string, so a future model
  swap doesn't require re-deriving the exact turn-formatting Qwen2.5-Instruct expects. The
  KV cache is cleared before every request (`llama_memory_clear`) and the actor accepts
  one request at a time — no interleaved generations to reason about.
- **Lazy lifecycle + warm-up.** `StyleModelLoader` (an actor implementing `LLMBackend`
  over `ModelStore` + `LlamaEngine`) loads the default `.style` model lazily: `isReady()`
  is `true` only once loaded; if the model is installed but not yet loaded, `isReady()`
  kicks a background load and returns `false` immediately (that call uses rules). At real
  launch, `warmUp()` runs once, low priority, right after `dictation.start()` — the first
  Metal shader compile (~20 s) happens in the background instead of blocking the first
  dictation. Removing the model in Settings unloads it on the next `isReady()` check. It also
  unloads after five minutes without generation activity; the next styled request reloads lazily.
- **Re-style semantics (MW-02s).** "Re-style ▾" on every readable History row opens a
  popover — Formal / Casual / Very casual / Verbatim, a checkmark on the row's current
  style, footer "Rewrites locally and copies the result." Picking a tone re-runs
  `LlamaStyler` (LLM when ready, rules otherwise) over the record's stored `rawText` with
  the current global toggles, replaces `text` (and `words`, `style`) in place, copies the
  new text to the pasteboard, and refreshes the list — `rawText` and `createdAt` are
  untouched, and snippets are **not** re-expanded (the stored `rawText` is what the engine
  heard; a Re-style rewrites the raw transcript, not the already-expanded snippet bodies).
- **Files stays rules-only (2f).** "Apply {defaultStyle.displayName} cleanup" runs every
  segment through `RuleStyler` only, never the LLM — a finished file transcript can run to
  thousands of segments, and 2f's promise ("instant, no re-processing") only holds for a
  deterministic, millisecond-scale rewrite. LLM cleanup for file transcripts is deferred
  scope, tracked as a follow-up issue rather than folded in here.

## Consequences

- Live dictation stamps a capture-local absolute deadline when recording stops, before the audio
  feed closes. Styling shares the controller's monotonic clock and reserves one second for snippet
  expansion and completion. The shared style-model loader permits one generation at a time;
  another ready caller falls back immediately instead of entering the native queue. Model readiness
  and generation share the lesser of eight seconds and
  that remaining budget; expired budgets or late replies fall back to rules. Final speech-window
  time counts against the budget. Direct calls and History Re-style retain the eight-second ceiling.
  The structured timeout relies on backend cancellation cooperation; it does not make a stalled
  speech engine or arbitrary non-cooperative backend return within the processing limit. See #153.
- The Qwen2.5 3B GGUF is a 2.1 GB download, and llama.cpp keeps roughly 2.5 GB resident in
  memory while the model is loaded (weights plus the KV cache at `n_ctx 2048`) — on top of
  whatever the whisper.cpp speech engine is already holding. Both engines can be loaded at
  once and both use Metal; they are not currently coordinated to avoid contending for the
  GPU at the same moment — tracked in #145.
- llama.cpp does not follow semver; its releases are build-tagged (`b10881` here). The
  XCFramework pin has to be bumped deliberately, following the lanes in
  `docs/runbooks/dependency-updates.md`, rather than picked up by a routine version-range
  bump the way Swift package dependencies with proper semver are.
- First run after installing the style model pays a one-time Metal shader compile
  (~20 s), which `warmUp()` moves off the first dictation's critical path but does not
  eliminate — an app relaunch mid-warm-up (or immediately after install, before a warm-up
  has run) can still see that latency on the very next `isReady()` call.
- A Re-style permanently replaces `text` — there is no history of prior rewrites for a
  row, and a Re-style after a snippet had already expanded into `text` discards that
  expansion along with the rest of the old styled text (raw dictation, not the expanded
  snippet body, is what gets re-rewritten).
- Because Files cleanup never calls the LLM, its output is bound by the same limits ADR-005
  already documented for `RuleStyler` — Formal only expands a fixed contraction table, it
  does not restructure sentences the way the phase-5 LLM does for dictation and Re-style.
  This divergence between "Apply Casual cleanup" and dictation's Casual output is expected,
  not a bug: 2f is deliberately deterministic and instant.

## Related

- [ADR-005](005-rule-based-styling-pipeline.md) — the `TextStyler` seam this phase fills,
  and the rule pipeline both the pre-pass and Files cleanup still run through.
- [ADR-002](002-whisper-cpp-speech-engine.md) — the actor-wraps-a-C-library pattern
  `LlamaEngine` follows for llama.cpp, the same way `WhisperCppEngine` wraps whisper.cpp.
- Design canvas MW-05 (Styles, page 3), MW-02d/MW-02s (Re-style menu, page 9), 2f (Files
  result "Apply Casual cleanup", page 7), ST-03 (Models "Cleanup & styles" row, page 6);
  controller rulings 1–10 in the phase 5 plan header
  (`docs/superpowers/plans/2026-09-09-phase5-llm-styles.md`). Issue #112.
