# Transcription E2E audit — 2026-10-30

Baseline run on macOS 27.0.1, arm64, from `develop` at `a1ccce9`, branch `feature/transcription-e2e`.
Corrections on `fix/transcription-quality` pass all **19/19 scenario pairs on both models**;
the baseline and after-fix measurements are preserved below.
An [additional eight-case Russian corpus](russian-longform-e2e.md) extends coverage up to 4:17;
its separate results include new strict phrase mismatches, so the 19/19 result below applies
to the original corpus only.
The suite uses the production decoder, Whisper/Metal, file windowing, dictation windowing and
all five exporters. There are no recognition fakes. It does **not** exercise microphone capture,
Fn/permissions, UI, Accessibility insertion, history or style cleanup. Synthetic speech is a
controlled regression corpus, not a measurement of real-world accent/room/microphone accuracy.

## Reproduce

```bash
cd VoxFlowKit
VOXFLOW_E2E_MODEL="$HOME/Library/Application Support/VoxFlow/Models/ggml-small.bin" \
  swift test --filter 'TranscriptionE2ETests|WordErrorRateTests' > /tmp/e2e-small.log 2>&1
# Repeat with ggml-large-v3-turbo.bin. The fixed suite should exit successfully.
```

Without `VOXFLOW_E2E_MODEL`, recognition cases explicitly skip; the metric test still runs.
An invalid supplied model path fails rather than silently selecting another model.
The current suite emits 44 `TRANSCRIPTION_E2E` JSON records: 19 scenarios × file/dictation,
five full-context controls, and one recovery after cancellation/error. The original audit used
17 scenarios and three controls. Captured baseline observations (38 records per model):
`gzip -dc docs/testing/transcription-e2e-results.jsonl.gz` (run from repository root).

## Corpus and acceptance

Four committed recordings are local macOS TTS at 165 words/minute: Samantha (English) and Milena
(Russian), converted with `afconvert -f WAVE -d LEI16@16000 -c 1`. Short texts are in the test;
long texts are adjacent `.txt` files. Long WAVs were losslessly compressed to FLAC to keep each
fixture below the repository’s 1 MB limit; decoded 16-bit PCM was verified byte-for-byte. Regenerate long audio with `say -v Samantha -r 165 -f
<text> -o /tmp/long.aiff`, then convert; use Milena for Russian. FLAC packaging uses `ffmpeg -i <wav> -c:a flac <flac>`;
ffmpeg is not a test dependency. Tests never regenerate speech.
English long speech is **102 words / 32.36 s**, Russian **92 normalized words / 42.27 s**;
these are connected clauses, not repeated word lists. Six repeated short utterances separately
exercise repeated content/window boundaries. Fixed-seed noise, reduced gain, silent padding,
48 kHz stereo and AAC conversions are generated in temporary directories.

Word error rate (WER) counts insertions, deletions and substitutions; case, punctuation and
Russian ё/е are ignored. Budgets were set before the model runs: ≤15%, or ≤25% for quiet/noisy
speech. Long speech additionally must preserve specified clauses, conditions and negations.
No-speech input must yield an actually empty string (even punctuation fails). For an empty
reference the JSON metric uses a denominator of one; interpret it as inserted-token count,
not a percentage. Timeline/progress, live previews, export content/JSON timings, cancellation,
corrupt-file rejection and reuse of the same loaded engine are checked independently of WER.

## Baseline results (before fixes)

WER percentages below are **file / dictation**. Passing WER alone does not imply acceptance.

| Scenario | Small | Large v3 Turbo | Other findings |
|---|---:|---:|---|
| Short English, Russian; auto EN/RU | 0 / 0 | 0 / 0 | Pass |
| Stereo 48 kHz; AAC; quiet; noisy speech | 0 / 0 | 0 / 0 | Pass |
| Long English | 0 / 6.9 | 0 / 7.8 | Both dictations lose “If you”; full-context control: 0% |
| Long Russian, explicit and auto | 3.3 / 6.5 | 2.2 / 13.0 | Small loses “не” in “не удаляй”; Turbo retains tested anchors |
| Speech with leading/trailing silence | 11.8 / 0 | 11.8 / 0 | File adds text and produces out-of-range timings |
| Six utterances, explicit and auto | 2.0 / 0 | 2.0 / 0 | File produces out-of-range final timings |
| Back-to-back speech | 0 / 2.9 | 0 / 0 | Within acceptance budget |
| Silence | nonempty / empty | nonempty / empty | Small: `[BLANK_AUDIO]`; Turbo: `Thank you.` |
| Noise only | nonempty / empty | nonempty / empty | Small: `(water splashing)`; Turbo: `.` |
| Cancel → corrupt file → valid file | 0 | 0 | Typed errors and recovery pass |

Small: **9/17 scenario pairs pass, 9 failed assertions**. Turbo: **11/17 pairs pass, 7 failed
assertions**. All three full-context controls and cancellation/recovery pass on each model.
The long Russian full-context controls score 3.3% (Small) / 2.2% (Turbo) and retain negations.
Export checks pass for the document supplied, including faithfully exporting bad source timings;
they do not repair recognition errors. The metric test passes. Compilation/native warning checks pass.
The full default `swift test` run passes; the opt-in E2E, microphone, external-noise and Keychain/
Secure Enclave cases retain their documented skips. Existing model-backed speech tests also pass.

## Root causes found in the baseline

1. **Meaning changes in windowed dictation.** Small changes “не удаляй предыдущую версию” to
   “Удаляй предыдущую версию”. Both models lose the English condition and invent a phrase about
   “the new version is correct”. Whole-recording controls retain the tested meaning. This implicates
   window/context handling; it does not by itself isolate the planner from per-window VAD effects.
2. **File hallucinations on silence/noise.** The file engine bypassed the speech detector used by
   dictation (`WhisperCppEngine.run`). The baseline strict acceptance cases detected this omission.
3. **File timing beyond EOF.** A 6 s silent file ends at 10 s (Small) / 29.98 s (Turbo). The 39.77 s
   repeated file ends at 49.2 s / 69.18 s. Native segment ends were forwarded without a
   duration bound, so invalid times propagate into subtitle exports.

Model SHA-256: Small `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`;
Turbo `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.

## Implemented corrections

- Both native inference entry points now use the bundled speech detector.
- Native segments are clipped to their input audio duration; segments entirely outside the
  recording are discarded, and text/confidence metadata is retained for valid segments.
- At the ten-second dictation limit, the planner searches backwards for the latest 200 ms pause
  after the three-second minimum. All following samples move into the next window. If no such
  pause exists it keeps the hard limit; it never creates a spoken tail below the flush minimum.
- Unit regressions cover exact sample conservation, latest-pause selection, short tails, device
  gaps, timestamp clipping and metadata preservation. Two extra long-speech scenarios prepend
  700 ms of silence to move speech relative to the window boundaries.

The WER budgets, condition/negation checks and no-speech expectations are unchanged. The older
attention-fixture comparison now applies its existing Y/why normalization after punctuation
splitting, so both “Y fixed” and “Y-fixed” receive the already documented treatment.

## After-fix model validation — 2026-10-30

**19/19 scenario pairs pass on Small and on Large v3 Turbo**, including both 700 ms offset
cases. All five whole-recording controls, cancellation/error recovery and metric checks pass.
Full `swift test` with `VOXFLOW_E2E_MODEL=.../ggml-small.bin` also passes, including the existing
speech, audio, files, dictation, styling, model lifecycle, storage and MCP regression suites.

| Long dictated speech | Small before → after | Turbo before → after |
|---|---:|---:|
| English WER | 6.9% → **0%** | 7.8% → **0%** |
| Russian WER (explicit and auto) | 6.5% → **3.3%** | 13.0% → **4.3%** |
| Tested conditions and negations | failure → **pass** | failure → **pass** |

Silence/noise now produce empty transcripts on both routes; the file timing checks also pass.
Speech accuracy is still model-dependent: the remaining Russian substitutions are visible in
`gzip -dc docs/testing/transcription-e2e-fixed-results.jsonl.gz` (88 complete observations).
This validates the committed synthetic corpus, not all possible natural speech or microphones.

Final application validation: `xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow -destination
'platform=macOS,arch=arm64' -resultBundlePath /tmp/voxflow-quality-final-20261030.xcresult build test`
passes, including 752 app-level tests. `scripts/check_build_logs.py` passes for both model runs,
the complete package run and Xcode stdout/stderr plus the exported structured xcresult warnings.
