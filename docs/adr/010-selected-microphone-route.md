# ADR-010: Isolate an explicit microphone route

Status: Accepted — 2026-11-11

The raw macOS AVAudioEngine HAL unit shares input/output device selection. Selecting an
input-only USB device while system audio uses Bluetooth can invalidate the output and retain
the old input format. The reported crash attempted a 16 kHz tap on 48 kHz hardware.

For an explicit microphone with voice processing off, use an input-only AudioQueue pinned to
the selected CoreAudio UID. AudioQueue converts to the existing 16 kHz mono Float32 contract
without configuring an output graph or changing system defaults. Check device presence before
startup and before emitting samples; disconnects fail rather than falling back to another mic.
Callbacks, buffer ownership and teardown share one serial queue. Dispose outside the native
callback and release the shared capture lease only after disposal completes.

Default routing and voice processing retain AVAudioEngine. Contain tap-installation NSExceptions
inside Objective-C and surface recording errors to Swift. Use the native NSError API where the
SDK/runtime supports it, with the guarded legacy path for macOS 15/26. Reject changed-format
buffers before conversion and remove only a successfully installed tap from its owning node.

References: [Apple input-node contract](https://developer.apple.com/documentation/avfaudio/avaudioinputnode),
AudioToolbox `AudioQueue.h` input-queue/current-device contract, and the [release evidence](../delivery/2.1.2.md).
