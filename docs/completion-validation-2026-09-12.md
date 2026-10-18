# VoxFlow completion validation — 2026-09-12

## Scope and source

Installed Release source: local integration commit `6172012`. The complete native suite passed at `7a17996`, which differs from the installed source only in test fixture setup. [PR 228](https://github.com/artemsemdev/VoxFlow/pull/228) contains the native capture lifecycle work; [PR 229](https://github.com/artemsemdev/VoxFlow/pull/229) and [PR 230](https://github.com/artemsemdev/VoxFlow/pull/230) contain the final native LLM cleanup and onboarding contrast fixes. Merged application/test source at [`6a8f6f2`](https://github.com/artemsemdev/VoxFlow/commit/6a8f6f2a895bfb1cf1bf79fd6153b72eecc28cef) matches the validated tree; only changelog entry order differs. The original checkout's pre-existing changes were preserved in place.

Implementation batch: [PR 214](https://github.com/artemsemdev/VoxFlow/pull/214), [215](https://github.com/artemsemdev/VoxFlow/pull/215), [216](https://github.com/artemsemdev/VoxFlow/pull/216), [217](https://github.com/artemsemdev/VoxFlow/pull/217), [218](https://github.com/artemsemdev/VoxFlow/pull/218), [219](https://github.com/artemsemdev/VoxFlow/pull/219), [220](https://github.com/artemsemdev/VoxFlow/pull/220), [221](https://github.com/artemsemdev/VoxFlow/pull/221), [222](https://github.com/artemsemdev/VoxFlow/pull/222), [223](https://github.com/artemsemdev/VoxFlow/pull/223), [224](https://github.com/artemsemdev/VoxFlow/pull/224), [225](https://github.com/artemsemdev/VoxFlow/pull/225), [226](https://github.com/artemsemdev/VoxFlow/pull/226), [227](https://github.com/artemsemdev/VoxFlow/pull/227). Final fixture/documentation integration is tracked separately.

## Validation gates

| Gate | Observed result | Evidence |
| --- | --- | --- |
| Standalone package baseline | 524 tests in 88 suites passed before the final two lifecycle tests; the final native run includes the updated package suites | `/tmp/voxflow-completion-package.log` |
| Script tests | 32 passed | `/tmp/voxflow-completion-scripts-final.log` |
| Complete native suite, with render, real HTTP, bookmarks and both real model backends | 1,365 cases: 1,360 passed, five skipped, zero failures; complete text and structured warning gates passed | `/tmp/voxflow-completion-delivery.{log,json,xcresult}`; compressed evidence in the [visual audit](validation/files-models-2026-09-12/README.md) |
| Onboarding focus regression | 66 render/view-model checks across three iterations passed; text and structured warnings clean | `/tmp/voxflow-onboarding-focus-fixed.{log,json,xcresult}` |
| Onboarding appearance regression | All eight states in both appearances; three final repetitions produced 48 clean captures | [Onboarding evidence](validation/onboarding-2026-09-12/README.md) |
| Actual Qwen inference and teardown | Eight targeted tests passed, two real tone outputs differed, process exit zero, warning gate clean | [Model metadata and complete log](validation/style-model-2026-09-12/result.json) |
| Signed Release build and local installation | Verified Release configuration built and installed; installed executable completed real stdio protocol smoke | [Release evidence](validation/release-2026-09-12/result.json) |

Earlier full attempts exposed onboarding activation warnings, a fake-clock ordering timeout and native sheet capture/dismissal warnings and a crash. The final changes use the owning onboarding window, causal actor/state barriers, settled content snapshots and actual native alert buttons. Those failed attempts are not recorded as green. The five remaining opt-in skips require a real microphone, prepared TextEdit caret fixture, interactive History popover, Keychain or Secure Enclave setup.

Earlier real-tone runs returned early because the default model path was absent, which Xcode incorrectly counted as passed. The catalog Qwen model was downloaded to an isolated temporary directory and verified against its 2,104,932,768-byte size and SHA-256 `626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d`. Actual inference exposed a queued native cleanup crash; paired context/model release now finishes before unload returns. Both the targeted test and final full hosted run execute real inference and exit normally. Missing models now produce an explicit skip. No owner-installed model was replaced.

The installed Release executable reports version `2.0.0`; this records a signed local Release build, not publication of an application version 2.1.0 release. Follow the [release checklist](RELEASE-CHECKLIST-2.1.0.md) for remaining acceptance.

## Published speech dependency — #198

- Published [whisper-v1.9.2-voxflow.1](https://github.com/artemsemdev/VoxFlow/releases/tag/whisper-v1.9.2-voxflow.1), containing `whisper-v1.9.2-metal-macos.xcframework.zip` (a dependency archive, not an installable app).
- SHA-256: `fbe2d8e5167c79d6ca31b9de1ad3884ef0c44910f120148ca92de0863cea0427`; [Package.swift](../VoxFlowKit/Package.swift) pins the release URL and checksum.
- Upstream whisper.cpp v1.9.2 commit `306c88f4d1286aec1bf96e544632897886af5501`; universal macOS static XCFramework, arm64/x86_64. Two canonical builds produced identical archives.
- The reviewed patch removes unused embedded Metal declarations while retaining GPU and flash attention. Cold embedded-shader compilation and actual installed-model GPU transcription passed; native-context cleanup and prioritized queue integration passed their focused checks.
- Reproduction and patch provenance: [Whisper Metal artifact](third-party-whisper-metal.md), [builder](../scripts/build_whisper_xcframework.sh). Retained session evidence includes `/tmp/voxflow-198-final-model.log` and `/tmp/voxflow-198-release-notes.md`.

## Actual model download and resume — #126

An optimized Swift 6 harness compiled the unchanged production downloader/network sources at `904402697a370ccdebe400c4cc91cb61eb9773fc`; no mock downloader or transport replaced them.

- Downloaded the real catalog Whisper small model; cancellation was observed with a persisted partial of 67,310,213 bytes.
- Resumed through the same downloader/URL; first resumed progress was 67,326,588 bytes and the total remained 487,601,967 bytes.
- Final SHA-256 matched the catalog: `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`.
- Measured throughput was 30.81 MB/s including interruption, or 35.16 MB/s during active transfer. No shaped 100-Mbit-network claim is made.
- Evidence/source hashes: `/tmp/voxflow-126-live-validation/EVIDENCE.md` and `result.log`. The check did not replace installed models or access user transcripts.

## Actual sandbox bookmark persistence — #132

A separately signed disposable helper used production bookmark/export/settings sources with App Sandbox and user-selected read/write entitlements. Selection and restoration ran in two distinct processes with the same isolated container settings.

- Original native check reproduced rejection of a writable own-container directory when `startAccessingSecurityScopedResource` returned false.
- Fixed selection persisted the bookmark; the second process restored it and exported sentinel fixture text successfully. Both launches still rejected an outside write with Cocoa error 513.
- Seven focused tests also cover container/external false-scope behavior, sibling-prefix and symlink boundaries, bookmarks and access leases.
- Evidence/source hashes: `/tmp/voxflow-132-sandbox/EVIDENCE.md`, `fixed-select.log`, `fixed-restore.log`; fixed source `0603e97`, integrated behavior includes `0147bcf`.
- This proves sandbox own-container selection/restoration across launches. It does not certify user-selected external-folder grants or upgrade migration. Production application identity, permissions, installed models and user transcripts were untouched by the helper.

## Installed native MCP stdio

The actual updated installed signed Release process, launched with `--mcp-stdio`, returned valid initialize, tools/list and ping replies, parse-error `-32700`, invalid-request `-32600`, and exit status 0 on EOF. Evidence: [installed Release smoke result](validation/release-2026-09-12/stdio.json).

This is a real process/protocol check; its retained results do not claim spoken dictation or installed-release file transcription through MCP. Setup and transport distinctions are documented in the [client runbook](runbooks/connect-an-mcp-client.md) and [ADR-008](adr/008-loopback-mcp-server.md).

## Visual and physical acceptance

Files/Models/result/alerts/icon coverage and all 54 chronological pairs are in the [approved visual audit](validation/files-models-2026-09-12/README.md), with full-resolution originals, source references, hashes and complete compressed validation logs. Native warning checks passed for the final integrated captures; the report documents the limits of component fixtures and intentional native layout differences.

[Hardware acceptance](HARDWARE-ACCEPTANCE.md) tracks the remaining physical checks for #110, #137, #162, #161, #144, #139, #138 and #145. The real TextEdit caret opt-in remains unverified; ordinary AX tests use fake targets. No claim of physical acceptance is inferred from unit tests, synthetic keys or renders.

This report contains only technical validation metadata and disposable-fixture evidence; no private recordings or transcript contents are included.
