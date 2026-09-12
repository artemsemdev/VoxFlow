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
- Dedicated shortcuts (#162) carry their selected mode into the same reducer: push-to-talk starts
  immediately and finishes on release; hands-free starts on one press and finishes on the next.
  They use the same preflight gates, capture, insertion and history effects. A press assigned to
  the other mode cannot change an active capture. The shared fn hold/double-tap path retains its
  timing. Hold timers only resolve undecided gestures, so a timer left after a failed fn attempt
  cannot change the mode of a dedicated retry.
  A stop received while the model loads is remembered and finishes the capture when loading
  completes. The controller obtains preflight only when starting: stopping must preserve the
  insertion target captured at the start. An event without preflight can stop but cannot start.
- Re-insert last (#162) retains the last completed non-ephemeral result in session memory, independent
  of whether `HistoryWriter` persists it. Later cancelled dictations do not erase that result. An
  injected history lookup can supply a previous result when the session cache is empty; the app
  controls that lookup according to its history setting. Reinsertion prepares a fresh target through
  an insertion-only privacy check, without microphone/model preflight, and neither saves history nor
  broadcasts another dictation result. Capture preparation and reinsertion exclude one another.
  Escape invalidates pending storage/target preparation. Dispatch to `TextInserting.insert` is the
  commit point: the protocol cannot roll back an edit already handed to another application.
  The app rechecks exclusions, secure input and frontmost-app identity after awaiting focus capture;
  a changed app abandons the attempt. Persisted fallback is read only with history enabled, checked
  again after the read; unreadable or empty records cannot be replayed.
- Live audio is cut into windows by `WindowPlanner` — at least 3 s, ending in ≥ 0.4 s
  of trailing silence, or cut at 10 s regardless — and each window is transcribed by
  `WindowedTranscriber` against `SpeechEngine`, with the previous window's decoded
  text tail (last 200 chars, `WindowedTranscriber.promptTailLength`) fed back in as
  `TranscriptionOptions.promptContext` so whisper conditions on what was just said.
  The controller awaits cumulative previews through the optional `LiveTextInserting` capability.
  A capture context is invalidated synchronously on teardown, including Escape; suspended partial
  or final callbacks cannot write into a newer capture. Escape preserves already-inserted text.
  The AX adapter snapshots the focused field's text and selection during preflight, checks the
  same focused target and unchanged full text/selection before each write, and appends or replaces
  only the capture-owned tail on UTF-16 grapheme boundaries. Final styling and snippet caret
  placement reconcile the same range, without calling ordinary `insert` a second time.
  Observed ownership loss permanently disables that capture's external edits: only the full final
  text is copied, once. Unreadable AX snapshots also use this fallback. Ephemeral onboarding and
  History scratchpads keep final-only insertion. Async cancellation cleanup releases the matching
  live snapshot without changing another capture's target.
  Any remainder shorter than `minFlush` (0.3 s) at the end of the feed is dropped
  rather than transcribed as its own tiny window — a deliberate trade against
  spending a whisper pass on a fragment too short to be meaningful; the last spoken
  word can occasionally be lost if the user trails off right at the cutoff.
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
- `Listening.startedAt`/`Processing.startedAt` are seconds from the controller's
  own `MonotonicClock`, not wall-clock time. `DictationController.elapsed` (the
  HUD's "00:12" counter) is derived from that same clock, so it stays correct
  across a system clock change or sleep/wake; history rows, by contrast, store
  `Date` (wall-clock) timestamps, because "when was this dictated" is a calendar
  question, not a duration one. The two are not interchangeable and a 3b view
  model must not mix them.
- `DictationResult` → `DictationDraft` has no bridge in phase 3a: the mapping is
  the composition root's job in phase 3b (`language = result.language?.code`
  discarding the detection's confidence, `style = nil` until phase 5 adds
  styling, `createdAt = Date()` taken at save time rather than from the result).
  Deferred deliberately rather than left undecided.
