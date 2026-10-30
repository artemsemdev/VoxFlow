# Extended Russian transcription corpus — 2026-10-30

Eight additional connected-speech cases build on the original 19-scenario matrix. Each runs
through the production file decoder/recognizer/exporters and through dictation in 100 ms chunks.
The text is newly authored for each case; longer recordings are not repetitions of short phrases.

| Case | Content | Duration | Words¹ | Language mode |
|---|---|---:|---:|---|
| reminder | Reminder with a prohibition | 16.24 s | 35 | Russian |
| conditions | Conditional instructions | 32.54 s | 71 | Auto |
| incident | Event sequence and preservation of the original | 69.57 s | 149 | Russian |
| planning | Weekly plan and ordered steps | 95.68 s | 212 | Auto |
| explanation | Long explanation with subordinate clauses | 126.30 s | 269 | Russian |
| handover | Handover, limitations and open questions | 158.41 s | 339 | Auto |
| proposal | Proposal, alternatives and exceptions | 190.98 s | 402 | Russian |
| retrospective | Extended retrospective and conclusions | **257.40 s** | **543** | Auto |

¹ Normalized WER words: hyphenated expressions split into separate tokens. The longest text
has 541 whitespace-separated words. All eight recordings total 15 minutes 47 seconds.

## Reproduce

```bash
cd VoxFlowKit
VOXFLOW_E2E_MODEL="$HOME/Library/Application Support/VoxFlow/Models/ggml-small.bin" \
VOXFLOW_E2E_REPORT_DIR=/tmp/voxflow-russian-reports \
  swift test --filter russianLongForm > /tmp/russian-small.log 2>&1
# Repeat with ggml-large-v3-turbo.bin. Strict quality checks can return nonzero (see results).
swift test --filter RussianSpeechCorpusTests  # corpus/anchor validation, no model required
```

The existing model opt-in and skip reason apply. The new long-form test has a ten-minute time
limit; audio is supplied without wall-clock pacing. It checks recognition and previews, not
microphone capture, the controller's real-time deadlines, UI insertion, history or styling.
Each model emits 16 compact `RUSSIAN_E2E` log records. The optional report directory also receives
16 JSON files containing the complete references, recognized text and measured discrepancies.

## Acceptance and provenance

The existing **WER ≤15%** budget is unchanged. Additional exact, ordered phrases check important
conditions, negations, intermediate content and the end of the recording. Punctuation, case and
ё/е are ignored. Phrase failures indicate a mismatch or reordering, not necessarily lost meaning:
an incorrect grammatical ending also fails. Progress, timing, cumulative previews, detected
language and all five exports are checked independently.

Audio is fixed local macOS Milena speech at 165 words/minute, 16 kHz mono. It is synthetic speech,
not the owner's voice or evidence of accuracy across accents, rooms and microphones. Each text
was synthesized as one recording, then split losslessly into storage parts of at most 30 seconds
so every FLAC stays below the repository's 1 MB fixture limit. Tests concatenate exact samples
before inference; storage boundaries do not introduce pauses or recognition window boundaries.
`manifest.json` records ordered parts, frame counts, voice/rate and the SHA-256 of the original PCM.
Regenerate explicitly from the repository root with `python3 scripts/generate_russian_speech_fixtures.py`
(requires the installed Milena voice and ffmpeg). Tests require neither speech synthesis nor ffmpeg.
Generation verifies every part against the original PCM, byte for byte. The model-free integrity
test validates sample counts, increasing durations, file limits and reference phrase ordering.

## Measured results

Run on the corrected implementation (`151d1b3`) on macOS arm64, using the same installed Small
and Large v3 Turbo models as the original audit. WER below is **file / dictation**; pass requires
both routes to satisfy every check, including exact ordered phrases.

| Case | Small WER | Turbo WER | Small / Turbo strict result |
|---|---:|---:|---|
| reminder | 11.4% / 11.4% | 0% / 0% | pass / pass |
| conditions | 4.2% / 1.4% | 5.6% / 5.6% | pass / pass |
| incident | 6.7% / 6.7% | 0% / 1.3% | fail / fail |
| planning | 2.4% / 3.3% | 0.5% / 6.1% | pass / pass |
| explanation | 7.4% / 7.4% | 3.0% / 4.1% | fail / pass |
| handover | 3.8% / 2.4% | 1.8% / 3.8% | pass / pass |
| proposal | 6.2% / 5.2% | 1.5% / 2.5% | fail / fail |
| retrospective | 4.8% / 4.2% | 1.7% / 5.7% | pass / pass |

All 32 route/model combinations meet the 15% WER budget and pass timing, progress, preview and
export checks. Exact phrase checks fail six times on Small and three times on Turbo:
**5/8 scenario pairs pass on Small, 6/8 on Turbo**. These failures remain enabled and visible.

- Small changes “описание события завершено” to “описанию события завершено”, and “объяснение
  завершено” to “объяснении завершено”. These are grammatical errors, not truncated recordings.
- Turbo dictation changes “не удаляй первую запись” to “не удаляй первую записи”: the negation
  survives, but the expected phrase does not match.
- Both models change “предыдущие версии” to “предыдущая версия”. Small also changes “если
  улучшения не будет” to “если улучшение не будет”.
- Inspection of Small's proposal/file transcript additionally finds “а не объявлять участников”
  rendered as “они объявляют участников”. This meaning-changing discrepancy is visible in the
  full transcript and is now covered by a dedicated phrase assertion as well.

The 4:17 case passes all checks on both models. Raw references and outputs for all 32 runs are
archived in `russian-longform-results.jsonl.gz` (`gzip -dc docs/testing/russian-longform-results.jsonl.gz`).
Default `swift test` passes, including corpus integrity and existing real-model smoke tests;
opt-in quality cases are explicitly skipped without the model environment variable. Build-log
warning checks and generator syntax validation also pass. No production transcription code changed.
