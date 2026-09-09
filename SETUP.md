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

### Style model

The Formal / Casual / Very casual style cleanup (Styles page, Re-style, and the Files result's
"Apply {Style} cleanup") is rule-based on its own; installing the style model upgrades the
dictation and Re-style paths to LLM rewrites (Files cleanup stays rule-based either way — see
[ADR-007](docs/adr/007-llm-styling-on-llama-cpp.md)). Download it from Settings › Models — the
"Qwen2.5 3B Instruct (4-bit)" row, 2.1 GB, sha256-verified before it counts as installed, same
download/pause/resume/remove flow as the speech models. It's saved to

```
~/Library/Application Support/VoxFlow/Models/qwen2.5-3b-instruct-q4_k_m.gguf
```

Without it (not yet downloaded, still downloading, or removed), styling falls back to the
deterministic rule pipeline (`RuleStyler`) automatically — dictation, Re-style and Files cleanup
all keep working, just without the LLM's tone rewriting. First launch after installing the model
pays a one-time Metal shader compile (~20 s), which runs in the background right after dictation
starts, not on your first dictation's critical path.

`VoxFlowLLMTests`' integration test (tagged `.requiresModel`) exercises the real model and needs
it installed at the path above, or `VOXFLOW_STYLE_MODEL` set to a GGUF file elsewhere:

```bash
cd VoxFlowKit && VOXFLOW_STYLE_MODEL=/path/to/qwen2.5-3b-instruct-q4_k_m.gguf swift test --filter LlamaEngineIntegrationTests
```

Without either, it prints `skipped: style model not installed` and returns — this is why it's
absent from CI.

### Contacts permission

VoxFlow does not ask for Contacts access at launch. It prompts only if you turn on "Learn names
from Contacts" on the Dictionary page — the prompt string is `NSContactsUsageDescription` in
`project.yml`. Denying it (or later revoking it in System Settings → Privacy & Security →
Contacts) snaps the toggle back off; no names are imported or read.

## Local code signing (once per Mac)

macOS ties Microphone/Accessibility grants and Keychain access to the app's code signature. An
ad-hoc signature changes on every build, so every rebuild would ask again. Use a self-signed
certificate instead (#143):

1. Keychain Access › menu Keychain Access › Certificate Assistant › Create a Certificate… —
   Name `VoxFlow Dev`, Identity Type *Self Signed Root*, Certificate Type *Code Signing*.
2. Trust it for code signing (no admin password needed for the login keychain):

   ```sh
   security find-certificate -c "VoxFlow Dev" -p > /tmp/voxflow-dev.pem
   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/voxflow-dev.pem
   security find-identity -v -p codesigning   # must list "VoxFlow Dev"
   ```
3. Create the git-ignored override next to `project.yml`:

   ```sh
   echo 'CODE_SIGN_IDENTITY = VoxFlow Dev' > Local.xcconfig
   xcodegen generate
   ```
4. Build once; macOS may ask to let `codesign` use the key — choose *Always Allow*. Then grant
   Microphone and Accessibility to `VoxFlow.app` one more time; from now on they survive rebuilds.
   `codesign -dvv <path to VoxFlow.app>` should print `Authority=VoxFlow Dev`.

## Tests

- Package logic, fast: `cd VoxFlowKit && swift test`
- Everything, as CI runs it: `xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`
- Integration tests that need a real model run only when one is installed and skip otherwise.

## Notes

- `VoxFlow.xcodeproj` and `VoxFlow/Info.plist` are generated; edit `project.yml` instead.
- Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`), strict concurrency is complete.
- Signing lives in `Signing.xcconfig` (ad-hoc by default, used by CI). See "Local code signing".
