# Dictation noise / invented subtitle credits

The reported subtitle-credit addition matches a known Whisper failure on background noise.
The original private dictation audio was not retained or used. Reproduction uses the public
[Whisper discussion](https://github.com/openai/whisper/discussions/1873)
and its [six-second noise sample](https://github.com/user-attachments/files/23571343/dima_clip.wav).
The sample remains external to this repository.

With the installed `ggml-large-v3-turbo.bin`, the production whisper.cpp v1.9.2 parameters
decoded that noise as `Субтитры делал DimaTorzok`. Its no-speech probability was only
`8.02535e-11`, and the audio RMS was approximately `0.08`: neither the native no-speech
threshold nor a simple silence gate rejects this example.

With Silero VAD enabled on the same audio/model, zero speech segments and zero text segments
were returned. A separate near-silence gate avoids decoding quiet tails altogether. No text
blacklist is used: actually spoken words must not disappear because they resemble a known
hallucination. Rejected noise cannot establish the dictation's language or emit text previews.

## Bundled detector

- Silero VAD v6.2.0, 885,098 bytes, MIT license included alongside the resource.
- Converted model source: `ggml-org/whisper-vad`, revision
  `9ffd54a1e1ee413ddf265af9913beaf518d1639b` on Hugging Face.
- [Pinned model download](https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin).
- SHA-256: `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`.
- Bundled as a Swift package resource, including its license. No runtime download, upload,
  external service, or new permission is introduced. File transcription is unchanged.

## Reproduction

Download the public noise sample to a local temporary path, then run from `VoxFlowKit`:

```sh
VOXFLOW_NOISE_REGRESSION_AUDIO=/tmp/voxflow-dima-clip.wav swift test --filter WhisperActivityTests
```

The external regression requires the installed turbo model; the two other native tests use
the smallest installed Whisper model. Ordinary CI without installed models skips native
integration tests and still runs deterministic dictation regression tests.

The deterministic regression failed before the fix: silence reached the engine, trailing
pauses duplicated the scripted transcript, and skipped pauses were incorrectly emitted as text.
It passes with the fix. Native checks also cover silence, deterministic noise, retained speech,
and timestamps after leading silence. Remaining limitation: VAD and speech recognition are
probabilistic. This fixes the reproduced noise case; it cannot eliminate every possible
recognition error, especially speech-like interference or very faint speech.
