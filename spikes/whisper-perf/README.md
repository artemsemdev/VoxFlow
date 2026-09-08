# whisper-perf spike

Throwaway benchmark used in phase 1 (#108) to decide streaming vs batch dictation. Not built
in CI, not shipped. Run: `swift run -c release spike <model.bin> <audio-16k.wav> [threads]`.

Results 2026-09-08, M1 Max 64 GB, whisper.cpp v1.9.2, Metal, 31.7 s synthetic speech:

| Model | Load | Transcribe | RTF | Peak RSS |
|---|---|---|---|---|
| large-v3-turbo | 0.72 s | 1.98 s | 0.063 (16×) | 1.8 GB |
| small | 0.20 s | 0.75 s | 0.024 (42×) | 716 MB |
| base | 0.12 s | 0.34 s | 0.011 (94×) | 307 MB |

First run after install: ~12 s one-time Metal shader compilation. Thread count is irrelevant (GPU-bound).

Language auto-detect (whisper_lang_auto_detect): turbo 0.75 s · small 0.29 s · base 0.45 s.
