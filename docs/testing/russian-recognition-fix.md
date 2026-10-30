# Russian recognition: decoding change — 2026-10-30

The extended corpus exposed grammatical substitutions and, on Small, a lost negation.
Recognition now uses beam search with five candidates instead of greedy decoding. Both
file transcription and dictation use the same policy. Five candidates are retained for
the existing temperature fallback: upstream's beam defaults alone leave `greedy.best_of`
unset, unlike its greedy defaults. See the pinned [whisper.cpp implementation](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/src/whisper.cpp).

No vocabulary hints, expected text, transcript replacements or relaxed assertions are used.
The VAD settings, window planner and temperature fallback schedule are unchanged.

## Results

Results compare the unchanged eight-case corpus at `ce8b21e` with this decoding change,
using the same installed models on macOS arm64. WER is normalized word edit distance;
the aggregate weights each route by its reference word count. A strict case passes only
when both file and dictation satisfy every check, including exact ordered phrases.

| Model | Aggregate WER before / after | Strict cases before / after |
|---|---:|---:|
| Small | 4.95% / 4.75% | 5/8 → 5/8 |
| Large v3 Turbo | 2.92% / 1.58% | 6/8 → 7/8 |

| Case | Small WER: file / dictation | Turbo WER: file / dictation |
|---|---:|---:|
| reminder | 11.4% / 11.4% | 0.0% / 0.0% |
| conditions | 4.2% / 4.2% | 0.0% / 0.0% |
| incident | 5.4% / 4.0% | 0.0% / 0.0% |
| planning | 2.4% / 2.4% | 0.5% / 2.8% |
| explanation | 6.3% / 7.1% | 3.3% / 3.0% |
| handover | 3.2% / 2.9% | 0.9% / 0.6% |
| proposal | 6.2% / 5.5% | 1.5% / 1.5% |
| retrospective | 5.0% / 4.2% | 1.8% / 2.4% |

The eight cases across both production routes took 87.1 seconds on Small and 135.7 seconds
on Turbo in the final runs (model loading included, audio supplied without real-time pacing).
A separate Small run took 80.2 seconds and produced identical transcripts and metrics.
All 32 production-route results meet the 15% WER budget and pass timing, progress, preview
and export checks. Turbo's `incident` now has zero word errors on both routes; its formerly
failing “не удаляй первую запись” phrase is preserved.

The corpus is fixed synthetic Milena speech, from 16 seconds to 4 minutes 17 seconds.
These measurements do not establish accuracy on other speakers or noisy microphones.
Some individual routes get worse even when aggregate WER improves. Beam search also adds
decoding work; these test runtimes are observations, not interactive-latency guarantees.

## Diagnosis and remaining failures

- Small still misrecognizes the final grammatical endings in `incident` and `explanation`.
- Small still changes “если улучшения не будет” to “если улучшение не будет”, and loses
  “не объявлять участников” in the file route of `proposal`.
- Both models still replace “предыдущие версии” in `proposal` with a different grammatical
  form. The strict checks remain enabled and fail; the extended suite is not fully green.
- All original acceptance thresholds and exact English repetition checks remain unchanged.

An experimental prior-text prompt for file windows restored one negation but caused repeated
words in an existing English regression. That change was rejected; the file pipeline retains
the behavior documented in ADR-009.

Three optional whole-recording controls feed `incident`, `explanation` and `proposal` directly
to the real engine, bypassing application windowing while keeping VAD. They distinguish model
errors from application cuts; they are diagnostic controls, not a replacement for either
production route. Results are archived alongside file/dictation reports.
Both models pass the exact phrases in the whole-recording `incident` and `explanation`
controls, but still fail `proposal`: Small misses “если улучшения не будет” and “предыдущие
версии”; Turbo misses “предыдущие версии”. Those errors therefore also occur without
application window cuts. The archive contains 32 production-route and six control results.

## Reproduce

```bash
cd VoxFlowKit
VOXFLOW_E2E_MODEL="$HOME/Library/Application Support/VoxFlow/Models/ggml-small.bin" \
VOXFLOW_E2E_REPORT_DIR=/tmp/russian-small \
VOXFLOW_E2E_BATCH_CONTROLS=1 \
  swift test --filter TranscriptionE2ETests > /tmp/russian-small.log 2>&1
# Repeat with ggml-large-v3-turbo.bin and a separate output directory.
```

The model environment variable gates the existing real-model suite. The additional
`VOXFLOW_E2E_BATCH_CONTROLS=1` opt-in enables only the three diagnostic controls; each has a
ten-minute limit. The command exits nonzero for the known exact-phrase failures above.
Each report contains its reference, actual text, model, route, WER and missing phrases.
Baseline outputs remain in `russian-longform-results.jsonl.gz`; outputs after this fix are
in `russian-recognition-fixed-results.jsonl.gz`.

## Regression validation

- All original 19 audio scenarios pass on both Small and Turbo, including long Russian/English
  speech, repeated phrases, noise, silence, formats and exports. The separate cancellation,
  corrupt-file and engine-reuse regression also passes on both models.
- Default `swift test` passes. The full model-enabled Small run fails only the documented
  Russian exact-phrase checks; all other package tests pass.
- `xcodegen generate` and the full macOS arm64 `xcodebuild build test` pass.
- `scripts/check_build_logs.py` passes on both E2E logs, the default package run and the
  Xcode log, including the structured xcresult warning scan.
