# ADR-010: Isolate an explicit microphone route

Status: Accepted — 2026-11-11

The raw macOS AVAudioEngine HAL unit shares input/output device selection. Selecting an
input-only USB device while system audio uses Bluetooth can invalidate the output and retain
the old input format. The reported crash attempted a 16 kHz tap on 48 kHz hardware.

For an explicit microphone with voice processing off, use an input-only AudioQueue pinned to
the selected CoreAudio UID. AudioQueue converts to the existing 16 kHz mono Float32 contract
without configuring an output graph or changing system defaults. Check device presence before
startup and before emitting samples; disconnects fail rather than falling back to another mic.
Callbacks and session state share one serial queue. Mark the session stopped on that queue,
then transfer native teardown to a separate serial queue. Pending callbacks reject buffers while
synchronous Stop/Dispose drain them. Release the shared capture lease only after disposal completes;
publish startup/callback failures after release so a retry cannot race cleanup.

The original same-queue teardown blocked callbacks needed by Stop/Dispose, causing two native
timeouts and approximately 29 seconds of self-reported microphone contention. Merely dispatching
disposal outside the callback was insufficient: its executor must also be independent. Default CI
models pending native callbacks and tests repeated capture, cancellation and failure cleanup.
An opt-in hardware test performs three selected-input captures and requires each shutdown to
complete within two seconds (audio is discarded):

```bash
VOXFLOW_MIC_TESTS=1 VOXFLOW_MIC_DEVICE_UID='<CoreAudio input UID>' \
  swift test --package-path VoxFlowKit --filter MicrophoneSourceIntegrationTests/selectedInputRepeats
```

Default routing and voice processing retain AVAudioEngine. Contain tap-installation NSExceptions
inside Objective-C and surface recording errors to Swift. Use the native NSError API where the
SDK/runtime supports it, with the guarded legacy path for macOS 15/26. Reject changed-format
buffers before conversion and remove only a successfully installed tap from its owning node.

References: [Apple input-node contract](https://developer.apple.com/documentation/avfaudio/avaudioinputnode),
AudioToolbox `AudioQueue.h` input-queue/current-device contract, and the [release evidence](../delivery/2.1.2.md).
