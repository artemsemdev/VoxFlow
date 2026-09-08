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

## Tests

- Package logic, fast: `cd VoxFlowKit && swift test`
- Everything, as CI runs it: `xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`
- Integration tests that need a real model run only when one is installed and skip otherwise.

## Notes

- `VoxFlow.xcodeproj` and `VoxFlow/Info.plist` are generated; edit `project.yml` instead.
- Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`), strict concurrency is complete.
- Local builds are ad-hoc signed. macOS ties Accessibility and Microphone permissions to the signing
  identity, so dictation development (2.1) will need a stable local certificate; see ADR-001.
