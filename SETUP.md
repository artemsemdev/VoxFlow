# Setting up VoxFlow for development

## Prerequisites

- macOS 15 or later on Apple Silicon.
- Xcode 26.x (`xcode-select --install` is not enough; the full Xcode is required for SwiftUI and the whisper.cpp XCFramework).
- XcodeGen: `brew install xcodegen`.

## First build

```bash
git clone https://github.com/artemsemdev/VoxFlow.git
cd VoxFlow
xcodegen generate
xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test
```

The first build downloads the pinned whisper.cpp XCFramework (~51 MB) into the SwiftPM cache.

## Running the app

Open `VoxFlow.xcodeproj`, select the `VoxFlow` scheme and run. On first launch go to
Settings › Models and download a speech model (large-v3-turbo is recommended on Macs with 16 GB or
more; small on 8 GB). Then drop an audio file on the window or the Dock icon.

Models live in `~/Library/Application Support/VoxFlow/Models`; transcripts in `~/Transcripts` by
default (change it in Files › Save to).

### First-launch onboarding

A first launch (or one where onboarding never finished) opens the onboarding window instead of the
main window: welcome → grant Microphone and Accessibility → choose push-to-talk or hands-free →
install a speech model → try dictation once into a scratchpad. Progress and completion are stored
in `UserDefaults` under the app's bundle id, `dev.artemsem.voxflow` — `UserDefaultsKeyValueStore`
namespaces every key with a `voxflow.` prefix, and `OnboardingState` (`VoxFlow/Onboarding/OnboardingState.swift`)
uses these three:

| Key (as stored) | Meaning |
|---|---|
| `voxflow.onboarding.completed` | `1` once the flow has finished; `AppDelegate` checks this on launch |
| `voxflow.onboarding.step` | Which step to resume at after a mid-flow relaunch |
| `voxflow.onboarding.clipboardFallback` | Set when Accessibility was denied and the user chose the clipboard fallback (ONB-02a) |

To see onboarding again, quit VoxFlow and reset those keys:

```bash
defaults delete dev.artemsem.voxflow voxflow.onboarding.completed
defaults delete dev.artemsem.voxflow voxflow.onboarding.step
defaults delete dev.artemsem.voxflow voxflow.onboarding.clipboardFallback
```

or force it back to the welcome step without touching anything else:

```bash
defaults write dev.artemsem.voxflow voxflow.onboarding.completed -string 0
defaults write dev.artemsem.voxflow voxflow.onboarding.step -string 0
```

`defaults delete dev.artemsem.voxflow` wipes the whole domain (onboarding, dictation and Files
settings) if you want a clean slate rather than onboarding alone.

Microphone and Accessibility grants and the history-encryption key (ADR-004) are tied to the app's
code signing identity, not to these defaults — deleting the keys above does not revoke permissions
or Keychain access, and a Keychain reset or ad-hoc re-signing can make history unreadable
(`HistoryService.Status.disabled(reason:)`, shown on the History page and under the header in
Settings → Privacy) independently of onboarding. `HistoryService` also
opens the store lazily, on first use rather than at construction, specifically so that launching
the app as the XCTest host never prompts for Keychain access — see #143.

## Tests

- Package logic, fast: `cd VoxFlowKit && swift test`
- Everything, as CI runs it: `xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`
- Integration tests that need a real model run only when one is installed and skip otherwise.

## Notes

- `VoxFlow.xcodeproj` and `VoxFlow/Info.plist` are generated; edit `project.yml` instead.
- Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`), strict concurrency is complete.
- Local builds are ad-hoc signed. macOS ties Accessibility and Microphone permissions to the signing
  identity, so dictation development (2.1) will need a stable local certificate; see ADR-001.
