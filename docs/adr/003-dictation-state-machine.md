# ADR-003: Dictation as a pure state machine with windowed transcription

Status: Accepted · Date: 2026-09-08

## Context

The Flow Bar has 12 HUD states (FB-01…FB-12) driven by timers (hold 250 ms, double-tap
350 ms, silence stop 3 s, cap 15 min, "Taking longer…" at 8 s, give up at 20 s, four
auto-dismiss durations) and three independent async sources: the fn hotkey, the
microphone, and the speech engine. Mixing all of that into one actor makes the
transition logic untestable without real clocks and real audio, and mixes UI-visible
state with I/O.

## Decision

- `FlowBarMachine` is a pure value type: `handle(event, now:) -> [FlowBarEffect]`.
  States (`idle`, `loadingModel`, `armed`, `tapped`, `listening`, `processing`,
  `inserted`, `copied`, `didntCatch`, `discarded`, `micUnavailable`,
  `modelNotInstalled`, `excluded`, `error`) and effects (`startCapture`,
  `finishCapture`, `abortCapture`, `loadModel`, `startTimer`/`cancelTimer` by id,
  `insert`, `copyToClipboard`, `saveHistory`) are both plain enums. Timers are
  effects with an id (`FlowBarTimer`), so a transition table is a unit test with an
  injected `now`, no real clock.

  | State | Canvas | Enters on | Leaves on |
  |---|---|---|---|
  | `idle` | FB-01 | start, every dismiss timer | fn-down |
  | `loadingModel(Pending)` | FB-12 "Loading model… keep talking" | fn-down when model installed but not loaded; capture starts at once | `modelLoaded` → `armed`/`listening` per resolved mode; `modelLoadFailed` → `error` |
  | `armed(Pending)` | (invisible) | fn-down with model loaded; capture starts | hold timer (250 ms) → listening(pushToTalk); fn-up → `tapped` |
  | `tapped(Pending)` | (invisible) | fn-up before 250 ms | fn-down within 350 ms → listening(handsFree); double-tap timer → idle + abortCapture |
  | `listening(Listening)` | FB-02 / FB-02b | above | PTT fn-up, hands-free fn-down, silence timer, cap timer → processing; esc → discarded |
  | `processing(Processing)` | FB-03 (+ "Taking longer…") | above | `transcriptReady` → insert; `insertionFinished` → inserted/copied; empty/low → didntCatch; 20 s → didntCatch(rawAvailable); esc → discarded; failure → error |
  | `inserted(appName, words, limitReached)` | FB-04 | insertion | dismiss 1.5 s |
  | `copied` | FB-04b | insertion fallback | dismiss 2.5 s |
  | `didntCatch(rawAvailable)` | FB-05 | empty / low confidence / timeout | dismiss 4 s, fn-down retries, `copyRawRequested` → copyToClipboard |
  | `discarded` | FB-06 | esc | dismiss 0.8 s |
  | `micUnavailable(MicrophoneAccess)` | FB-07 | preflight or `microphoneFailed` | dismiss 4 s |
  | `modelNotInstalled(sizeBytes)` | FB-08 | preflight | dismiss 4 s |
  | `excluded(app)` | FB-10 | preflight (excluded app or secure input) | dismiss 4 s |
  | `error(message)` | FB-07 pattern "… · Open Settings" | model load / transcription failure | dismiss 4 s |

- `DictationController` (actor) is the only thing that runs effects. It owns the mic
  task, the transcriber task, and one `Task` per running timer, each tagged with a
  generation token: `captureID` invalidates every callback from a torn-down capture
  (a stale mic chunk, transcript, insertion or failure from an aborted dictation can
  never reach a newer one), and a per-timer `(generation, task)` pair means a `sleep`
  that already returned when its id was re-registered cannot fire in the new
  registration's place.
- Capture starts on fn-down, before the hold/double-tap decision resolves, so no
  syllable is lost; a lone short tap discards the buffer silently.
- Live audio is cut into windows by `WindowPlanner` — at least 3 s, ending in ≥ 0.4 s
  of trailing silence, or cut at 10 s regardless — and each window is transcribed by
  `WindowedTranscriber` against `SpeechEngine`, with the previous window's decoded
  text tail (last 200 chars, `WindowedTranscriber.promptTailLength`) fed back in as
  `TranscriptionOptions.promptContext` so whisper conditions on what was just said.
  Text streams to the HUD as `partialText` while the user keeps talking, but
  insertion is a single final write at the end of the dictation — nothing is
  inserted before the user stops (live insertion is a phase-4 follow-up).
- Issue #125 (the engine's `transcribe` stream may end silently when the consuming
  task is cancelled mid-run): ruled option 1 — every consumer checks
  `Task.isCancelled` after its loop and treats a silent end as cancellation.
  `WindowedTranscriber` does this after each window's inner loop and once more
  after the outer capture loop, throwing `DictationError.cancelled`.

## Consequences

- The whole FB-01…FB-12 transition table is tested as pure `handle` calls with a
  fake clock; no sleeps, no real microphone, no real engine.
- Live insertion while speaking (streaming Flow Bar text into the focused app) is
  explicitly out of scope here and tracked as a follow-up issue.
- `SpeechEngine.transcribe`'s cancellation contract stays "may end silently on
  mid-run cancellation" rather than a hard error — weaker than ideal, but now
  documented and enforced by convention (`Task.isCancelled` after every consuming
  loop) instead of being an open question.
- A capture that is torn down (abort, or superseded by a new fn-down) drops every
  in-flight callback by generation; nothing from an old dictation can leak into a
  new one's state or history row.
