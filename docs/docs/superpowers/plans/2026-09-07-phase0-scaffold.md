# VoxFlow v2 Phase 0 — Scaffold, CI and .gitignore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buildable, tested `v2/` Swift project: SwiftPM package `VoxFlowKit` with the nine spec modules, a SwiftUI app that shows a menu bar item and a main window with the seven sidebar pages, and green `ci-v2.yml` / `codeql-v2.yml`.

**Architecture:** All logic lives in the SwiftPM package `v2/VoxFlowKit` (nine modules, each with its own Swift Testing target). The app target `v2/VoxFlow` is a thin SwiftUI shell defined by XcodeGen `project.yml`; the generated `.xcodeproj` is gitignored. One scheme `VoxFlow` builds the app and runs both the app tests and the package tests.

**Tech Stack:** Swift 6 language mode, SwiftUI + AppKit, macOS 15.0 deployment target, Xcode 26.x locally and in CI, SwiftPM, Swift Testing, XcodeGen 2.46, GitHub Actions `macos-15`.

**Spec:** `v2/docs/superpowers/specs/2026-09-07-voxflow-v2-design.md` (sections 3, 6, 7). Issue: #107.

## Global Constraints

- Deployment target `macOS 15.0`; Swift language mode 6; `SWIFT_STRICT_CONCURRENCY: complete`.
- `VoxFlowCore` imports only Foundation. Other modules import `VoxFlowCore` and Foundation/AVFoundation/etc., never the app. The app imports modules.
- No v1 (.NET) code is referenced or copied. No ffmpeg, no CLI.
- Commits: Conventional Commits (`type(scope): summary`), authored by the repository owner only. No `Co-authored-by`, no AI attribution anywhere (commits, PR bodies, code comments).
- Work happens on branch `feature/107-v2-scaffold-ci` (from `develop`); PR into `develop`.
- Every command below runs from the repository root unless a `cd` is shown.
- Generated artifacts (`VoxFlow.xcodeproj`, `.build`, DerivedData, `*.xcresult`) are never committed.

---

### Task 1: SwiftPM package `VoxFlowKit` with nine modules and nine test targets

**Files:**
- Create: `v2/VoxFlowKit/Package.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/Version.swift`
- Create: `v2/VoxFlowKit/Sources/<Module>/<Module>Module.swift` for each of `VoxFlowAudio`, `VoxFlowSpeech`, `VoxFlowModels`, `VoxFlowFiles`, `VoxFlowDictation`, `VoxFlowStorage`, `VoxFlowStyling`, `VoxFlowMCP`
- Test: `v2/VoxFlowKit/Tests/VoxFlowCoreTests/VersionTests.swift`
- Test: `v2/VoxFlowKit/Tests/<Module>Tests/<Module>ModuleTests.swift` for each of the eight other modules

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum VoxFlowVersion { public static let string: String }` in `VoxFlowCore`; library products `VoxFlowCore`, `VoxFlowAudio`, `VoxFlowSpeech`, `VoxFlowModels`, `VoxFlowFiles`, `VoxFlowDictation`, `VoxFlowStorage`, `VoxFlowStyling`, `VoxFlowMCP`. Task 2 links `VoxFlowCore` from the app.

- [ ] **Step 1: Write the failing Core test**

`v2/VoxFlowKit/Tests/VoxFlowCoreTests/VersionTests.swift`:

```swift
import Testing
@testable import VoxFlowCore

@Suite("VoxFlowVersion")
struct VersionTests {
    @Test("version string is semver with a -dev suffix until the first release")
    func versionIsDevSemver() {
        let parts = VoxFlowVersion.string.split(separator: "-", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(parts[1] == "dev")
        let numbers = parts[0].split(separator: ".")
        #expect(numbers.count == 3)
        #expect(numbers.allSatisfy { Int($0) != nil })
    }
}
```

- [ ] **Step 2: Write `Package.swift` with all targets**

`v2/VoxFlowKit/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

// Module dependency graph (spec section 3). Core depends on nothing but Foundation;
// every other module depends on Core; Files may use Audio/Speech/Models later.
let package = Package(
    name: "VoxFlowKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoxFlowCore", targets: ["VoxFlowCore"]),
        .library(name: "VoxFlowAudio", targets: ["VoxFlowAudio"]),
        .library(name: "VoxFlowSpeech", targets: ["VoxFlowSpeech"]),
        .library(name: "VoxFlowModels", targets: ["VoxFlowModels"]),
        .library(name: "VoxFlowFiles", targets: ["VoxFlowFiles"]),
        .library(name: "VoxFlowDictation", targets: ["VoxFlowDictation"]),
        .library(name: "VoxFlowStorage", targets: ["VoxFlowStorage"]),
        .library(name: "VoxFlowStyling", targets: ["VoxFlowStyling"]),
        .library(name: "VoxFlowMCP", targets: ["VoxFlowMCP"]),
    ],
    targets: [
        .target(name: "VoxFlowCore"),
        .target(name: "VoxFlowAudio", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowSpeech", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowModels", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowFiles", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowDictation", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowStorage", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowStyling", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowMCP", dependencies: ["VoxFlowCore"]),

        .testTarget(name: "VoxFlowCoreTests", dependencies: ["VoxFlowCore"]),
        .testTarget(name: "VoxFlowAudioTests", dependencies: ["VoxFlowAudio"]),
        .testTarget(name: "VoxFlowSpeechTests", dependencies: ["VoxFlowSpeech"]),
        .testTarget(name: "VoxFlowModelsTests", dependencies: ["VoxFlowModels"]),
        .testTarget(name: "VoxFlowFilesTests", dependencies: ["VoxFlowFiles"]),
        .testTarget(name: "VoxFlowDictationTests", dependencies: ["VoxFlowDictation"]),
        .testTarget(name: "VoxFlowStorageTests", dependencies: ["VoxFlowStorage"]),
        .testTarget(name: "VoxFlowStylingTests", dependencies: ["VoxFlowStyling"]),
        .testTarget(name: "VoxFlowMCPTests", dependencies: ["VoxFlowMCP"]),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 3: Run the package tests to verify they fail**

Run: `cd v2/VoxFlowKit && swift test 2>&1 | tail -20`
Expected: build error — `cannot find 'VoxFlowVersion' in scope` (and errors that the other Sources directories do not exist). That is RED.

- [ ] **Step 4: Write the Core implementation**

`v2/VoxFlowKit/Sources/VoxFlowCore/Version.swift`:

```swift
/// Product version shown in About, the menu bar footer and MCP `serverInfo`.
/// Bumped by the release process (spec section 6); "-dev" is dropped on `release/x.y.z`.
public enum VoxFlowVersion {
    public static let string = "2.0.0-dev"
}
```

- [ ] **Step 5: Write one placeholder source + one test per remaining module**

For each `M` in `VoxFlowAudio VoxFlowSpeech VoxFlowModels VoxFlowFiles VoxFlowDictation VoxFlowStorage VoxFlowStyling VoxFlowMCP` create the two files below, replacing `Audio` with the module's short name (`Speech`, `Models`, `Files`, `Dictation`, `Storage`, `Styling`, `MCP`) and the doc line with the module's responsibility from the table:

| Module | Responsibility (spec section 3) |
|---|---|
| VoxFlowAudio | file decode to 16 kHz mono Float32; microphone capture; RMS for the waveform |
| VoxFlowSpeech | `SpeechEngine` implementations; `WhisperCppEngine` actor over whisper.cpp |
| VoxFlowModels | model catalog and store: download, resume, verify, free-space check, remove |
| VoxFlowFiles | file queue, transcript writers (TXT/SRT/VTT/JSON/MD), export |
| VoxFlowDictation | Flow Bar state machine: hotkey timing, silence stop, insertion policy |
| VoxFlowStorage | history, dictionary, snippets, styles on SQLite; encryption at rest |
| VoxFlowStyling | `TextStyler` implementations: rule-based now, llama.cpp later |
| VoxFlowMCP | loopback HTTP MCP server, access token, client approval, path policy |

`v2/VoxFlowKit/Sources/VoxFlowAudio/AudioModule.swift`:

```swift
import VoxFlowCore

/// VoxFlowAudio — file decode to 16 kHz mono Float32; microphone capture; RMS for the waveform.
/// Filled in from phase 1. The enum exists so the module has a compiled symbol and a
/// declared dependency on VoxFlowCore from day one.
public enum AudioModule {
    public static let name = "VoxFlowAudio"
    public static let coreVersion = VoxFlowVersion.string
}
```

`v2/VoxFlowKit/Tests/VoxFlowAudioTests/AudioModuleTests.swift`:

```swift
import Testing
@testable import VoxFlowAudio

@Suite("VoxFlowAudio module")
struct AudioModuleTests {
    @Test("module links against VoxFlowCore")
    func linksCore() {
        #expect(AudioModule.name == "VoxFlowAudio")
        #expect(AudioModule.coreVersion.isEmpty == false)
    }
}
```

The enum names are `AudioModule`, `SpeechModule`, `ModelsModule`, `FilesModule`, `DictationModule`, `StorageModule`, `StylingModule`, `MCPModule`; test files are named `<Short>ModuleTests.swift` with suites `"VoxFlow<Short> module"`.

- [ ] **Step 6: Run the package tests to verify they pass**

Run: `cd v2/VoxFlowKit && swift test 2>&1 | grep -E "Test run with|error:" `
Expected: `✔ Test run with 9 tests in 9 suites passed` and no `error:` lines.

- [ ] **Step 7: Verify the Core boundary rule**

Run: `grep -rn "^import" v2/VoxFlowKit/Sources/VoxFlowCore/`
Expected: no output (Core has no imports) or only `import Foundation`.

- [ ] **Step 8: Commit**

```bash
git add v2/VoxFlowKit
git commit -m "feat(v2): add VoxFlowKit package with the nine spec modules

Nine SwiftPM library targets with one Swift Testing target each, mirroring
spec section 3. Core exposes VoxFlowVersion; other modules hold a placeholder
that links Core so the dependency graph is declared from day one. Refs #107."
```

---

### Task 2: App target, XcodeGen project and scheme

**Files:**
- Create: `v2/project.yml`
- Create: `v2/VoxFlow/App/VoxFlowApp.swift`
- Create: `v2/VoxFlow/App/MenuBarContent.swift`
- Create: `v2/VoxFlow/MainWindow/SidebarPage.swift`
- Create: `v2/VoxFlow/MainWindow/MainWindow.swift`
- Create: `v2/VoxFlow/MainWindow/SidebarView.swift`
- Create: `v2/VoxFlow/MainWindow/PlaceholderPageView.swift`
- Create: `v2/VoxFlow/Design/Palette.swift`
- Test: `v2/VoxFlowTests/SidebarPageTests.swift`

**Interfaces:**
- Consumes: `VoxFlowVersion.string` from Task 1.
- Produces: `enum SidebarPage: String, CaseIterable, Identifiable { case home, history, dictionary, snippets, styles, files, settings }` with `title: String`, `systemImage: String`, `shortcutNumber: Int` (1…7); `enum Palette` with `static let onDevice: Color` and `static func accent(_ name: AccentName) -> Color`. Later phases replace `PlaceholderPageView` per page.

- [ ] **Step 1: Write the failing app test**

`v2/VoxFlowTests/SidebarPageTests.swift`:

```swift
import Testing
@testable import VoxFlow

@Suite("SidebarPage")
struct SidebarPageTests {
    @Test("seven pages in the order the design's sidebar shows them")
    func orderMatchesDesign() {
        #expect(SidebarPage.allCases.map(\.title) == [
            "Home", "History", "Dictionary", "Snippets", "Styles", "Files", "Settings",
        ])
    }

    @Test("⌘1…⌘7 map to the pages in sidebar order")
    func shortcutsAreSequential() {
        #expect(SidebarPage.allCases.map(\.shortcutNumber) == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test("every page has a distinct SF Symbol")
    func symbolsAreDistinct() {
        let symbols = SidebarPage.allCases.map(\.systemImage)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { $0.isEmpty == false })
    }

    @Test("home is the default page")
    func defaultPage() {
        #expect(SidebarPage.default == .home)
    }
}
```

- [ ] **Step 2: Write `project.yml`** (validated on 2026-09-07 with XcodeGen 2.46 and Xcode 26.6)

`v2/project.yml`:

```yaml
name: VoxFlow
options:
  bundleIdPrefix: dev.artemsem
  deploymentTarget:
    macOS: "15.0"
  xcodeVersion: "16.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    # Ad-hoc signing so local builds and CI need no team or certificate.
    # Developer ID signing is configured in phase 7 (release pipeline).
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ""
    ENABLE_HARDENED_RUNTIME: NO
packages:
  VoxFlowKit:
    path: VoxFlowKit
targets:
  VoxFlow:
    type: application
    platform: macOS
    sources:
      - path: VoxFlow
    dependencies:
      - package: VoxFlowKit
        product: VoxFlowCore
    info:
      path: VoxFlow/Info.plist
      properties:
        CFBundleDisplayName: VoxFlow
        LSApplicationCategoryType: public.app-category.productivity
        NSHumanReadableCopyright: "© 2026 Artem Semenov"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.artemsem.voxflow
        SWIFT_EMIT_LOC_STRINGS: YES
  VoxFlowTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: VoxFlowTests
    dependencies:
      - target: VoxFlow
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
schemes:
  VoxFlow:
    build:
      targets:
        VoxFlow: all
    run:
      config: Debug
    test:
      config: Debug
      gatherCoverageData: false
      targets:
        - VoxFlowTests
        - package: VoxFlowKit/VoxFlowCoreTests
        - package: VoxFlowKit/VoxFlowAudioTests
        - package: VoxFlowKit/VoxFlowSpeechTests
        - package: VoxFlowKit/VoxFlowModelsTests
        - package: VoxFlowKit/VoxFlowFilesTests
        - package: VoxFlowKit/VoxFlowDictationTests
        - package: VoxFlowKit/VoxFlowStorageTests
        - package: VoxFlowKit/VoxFlowStylingTests
        - package: VoxFlowKit/VoxFlowMCPTests
```

Note: `VoxFlow/Info.plist` is generated by XcodeGen from the `info.properties` block; it is committed (XcodeGen writes it on every generate, so the file stays in sync).

- [ ] **Step 3: Write the sidebar model**

`v2/VoxFlow/MainWindow/SidebarPage.swift`:

```swift
import Foundation

/// The seven sidebar destinations of the main window (design 1c, MW-01…06, ST-01).
/// Order is the order in the sidebar and the ⌘1…⌘7 shortcuts (design 3d, "Main window").
enum SidebarPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, snippets, styles, files, settings

    static let `default`: SidebarPage = .home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .styles: "Styles"
        case .files: "Files"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .snippets: "text.insert"
        case .styles: "textformat"
        case .files: "doc.text"
        case .settings: "gearshape"
        }
    }

    /// 1-based position, used for ⌘1…⌘7.
    var shortcutNumber: Int {
        SidebarPage.allCases.firstIndex(of: self)! + 1
    }
}
```

- [ ] **Step 4: Write the palette**

`v2/VoxFlow/Design/Palette.swift`:

```swift
import SwiftUI

/// Colors from the design's Tweaks panel (accent options) and the brand's "on-device" green.
enum Palette {
    /// The green status dot shown on every surface (Flow Bar, menu bar, sidebar footer, Privacy).
    static let onDevice = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255) // #34c759

    enum AccentName: String, CaseIterable {
        case blue, purple, pink, orange, green, graphite
    }

    static func accent(_ name: AccentName) -> Color {
        switch name {
        case .blue: Color(red: 0, green: 122 / 255, blue: 1)                    // #007aff
        case .purple: Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255)   // #af52de
        case .pink: Color(red: 1, green: 45 / 255, blue: 85 / 255)              // #ff2d55
        case .orange: Color(red: 1, green: 149 / 255, blue: 0)                  // #ff9500
        case .green: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)     // #34c759
        case .graphite: Color(red: 110 / 255, green: 110 / 255, blue: 115 / 255) // #6e6e73
        }
    }
}
```

- [ ] **Step 5: Write the views**

`v2/VoxFlow/MainWindow/PlaceholderPageView.swift`:

```swift
import SwiftUI

/// Stand-in content until each page is built (phases 2–4).
struct PlaceholderPageView: View {
    let page: SidebarPage

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: page.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(page.title)
                .font(.title2.weight(.semibold))
            Text("Coming in a later phase.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(page.title)
    }
}
```

`v2/VoxFlow/MainWindow/SidebarView.swift`:

```swift
import SwiftUI
import VoxFlowCore

/// Full-height sidebar (design 1c): the seven pages plus the "Everything on this Mac" footer.
struct SidebarView: View {
    @Binding var selection: SidebarPage

    var body: some View {
        List(SidebarPage.allCases, selection: $selection) { page in
            Label(page.title, systemImage: page.systemImage)
                .tag(page)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
                Text("Everything on this Mac").font(.callout.weight(.semibold))
            }
            Text("VoxFlow \(VoxFlowVersion.string) · 0 bytes sent since install")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
```

`v2/VoxFlow/MainWindow/MainWindow.swift`:

```swift
import SwiftUI

/// Main window content (design 1c): sidebar + detail, 1120×720 by default, ⌘1…⌘7 jump to pages.
struct MainWindow: View {
    @State private var selection: SidebarPage = .default

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            PlaceholderPageView(page: selection)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background {
            // Hidden buttons give ⌘1…⌘7 without a custom menu; replaced by a Commands menu in phase 4.
            ForEach(SidebarPage.allCases) { page in
                Button("") { selection = page }
                    .keyboardShortcut(KeyEquivalent(Character("\(page.shortcutNumber)")), modifiers: .command)
                    .hidden()
            }
        }
    }
}
```

`v2/VoxFlow/App/MenuBarContent.swift`:

```swift
import SwiftUI

/// Menu bar dropdown, phase-0 subset of MB-01: status line, Open, Quit.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
            Text("Ready · on-device")
        }
        Divider()
        Button("Open VoxFlow") { openWindow(id: MainWindowID.main) }
            .keyboardShortcut("o")
        Divider()
        Button("Quit VoxFlow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum MainWindowID {
    static let main = "main"
}
```

`v2/VoxFlow/App/VoxFlowApp.swift`:

```swift
import SwiftUI

@main
struct VoxFlowApp: App {
    var body: some Scene {
        Window("VoxFlow", id: MainWindowID.main) {
            MainWindow()
        }
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra("VoxFlow", systemImage: "waveform") {
            MenuBarContent()
        }
    }
}
```

- [ ] **Step 6: Generate the project and run the scheme (build + all tests)**

Run:

```bash
cd v2 && xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test 2>&1 | grep -E "error:|Test run with|BUILD|TEST"
```

Expected: `** BUILD SUCCEEDED **`, ten `✔ Test run with … passed` lines (1 app suite with 4 tests + 9 package suites), `** TEST SUCCEEDED **`, no `error:` lines. If the first run shows a SwiftUI `Window`/`openWindow` availability error, the deployment target is wrong: check `MACOSX_DEPLOYMENT_TARGET` is `15.0`.

- [ ] **Step 7: Launch the app once and check it visually**

Run:

```bash
cd v2 && APP=$(xcodebuild -scheme VoxFlow -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/VoxFlow.app && open "$APP" && sleep 3 && screencapture -x /tmp/voxflow-phase0.png && osascript -e 'tell application "VoxFlow" to quit'
```

Expected: the screenshot shows a window titled VoxFlow with a sidebar listing Home … Settings, the green "Everything on this Mac" footer, and a waveform icon in the menu bar. Attach `/tmp/voxflow-phase0.png` to the PR.

- [ ] **Step 8: Commit**

```bash
git add v2/project.yml v2/VoxFlow v2/VoxFlowTests
git commit -m "feat(v2): add SwiftUI app shell with sidebar and menu bar item

XcodeGen project with app target VoxFlow and scheme VoxFlow whose test action
runs the app tests and all VoxFlowKit package tests. Main window shows the
seven sidebar pages from the design with ⌘1–7; menu bar item shows the
on-device status. Refs #107."
```

---

### Task 3: `.gitignore`, design files, README and ADR-001

**Files:**
- Create: `v2/.gitignore`
- Create: `v2/design/VoxFlow.dc.html`, `v2/design/support.js` (copied from the owner's export; source path is given by the orchestrator)
- Create: `v2/design/README.md`
- Create: `v2/README.md`
- Create: `v2/docs/adr/README.md`
- Create: `v2/docs/adr/001-project-structure.md`

**Interfaces:**
- Consumes: the layout produced by Tasks 1–2.
- Produces: documentation only.

- [ ] **Step 1: Write `.gitignore`**

`v2/.gitignore`:

```gitignore
# ── macOS ───────────────────────────────────────────────────────────────────
.DS_Store
.AppleDouble
.LSOverride
._*

# ── Xcode (project is generated by XcodeGen from project.yml) ───────────────
VoxFlow.xcodeproj/
*.xcworkspace/
!*.xcodeproj/project.xcworkspace/
xcuserdata/
*.xcuserstate
*.xcscmblueprint
*.xccheckout
*.moved-aside
DerivedData/
build/
*.hmap
*.ipa
*.dSYM
*.dSYM.zip
timeline.xctimeline
playground.xcworkspace

# ── Swift Package Manager ───────────────────────────────────────────────────
.build/
.swiftpm/
# Package.resolved IS tracked for reproducible builds.
*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# ── Test output ─────────────────────────────────────────────────────────────
*.xcresult
TestResults/
*.profraw
*.profdata

# ── Models and media (downloaded at runtime, never committed) ───────────────
*.bin
*.gguf
*.mlmodelc
*.mlpackage
Models/
Fixtures/**/*.m4a
Fixtures/**/*.mp3
Fixtures/**/*.mp4
Fixtures/**/*.mov
# short WAV fixtures for tests ARE tracked (keep them under 1 MB each)
!Fixtures/**/*.wav

# ── Signing, secrets, local config ──────────────────────────────────────────
*.p12
*.p8
*.cer
*.certSigningRequest
*.mobileprovision
*.provisionprofile
AuthKey_*.p8
.env
.env.*
*.local.json
ExportOptions.local.plist

# ── Tooling ─────────────────────────────────────────────────────────────────
.idea/
.vscode/
*.swp
*.swo
*~
.swiftlint-cache/
```

- [ ] **Step 2: Verify the ignore file behaves**

Run: `cd v2 && xcodegen generate >/dev/null && git status --porcelain --ignored -- . | grep -E "^!!" | head`
Expected: `!! v2/VoxFlow.xcodeproj/` and `!! v2/VoxFlowKit/.build/` appear as ignored; `git status --short` shows no `.xcodeproj` or `.build` entries as untracked.

- [ ] **Step 3: Copy the design files and write `design/README.md`**

Run: `mkdir -p v2/design && cp "<orchestrator-provided-path>/VoxFlow.dc.html" "<orchestrator-provided-path>/support.js" v2/design/`

`v2/design/README.md`:

```markdown
# Design source

`VoxFlow.dc.html` is the Claude Design canvas that specifies v2 (three design turns:
Flow Bar, menu bar, main window, onboarding, settings, sheets, empty states, edge cases,
plus the screen inventory in section 3b and interaction timings in 3d). `support.js` is
its runtime; open the HTML in a browser to browse the screens interactively.

Treat it as the product spec: screen IDs such as `FB-04b` or `ST-03v` in issues, code
comments and tests refer to this file. Export from
https://claude.ai/design/p/4f3875cb-2265-49cb-90e2-829c17812240 when it changes.
```

- [ ] **Step 4: Write `v2/README.md`**

```markdown
# VoxFlow v2

Native macOS dictation and file transcription, entirely on-device. Swift 6, SwiftUI,
whisper.cpp, macOS 15+, Apple Silicon.

This directory is the v2 rewrite growing on the `develop` branch until promotion (see
issue #105 and `docs/superpowers/specs/2026-09-07-voxflow-v2-design.md`). The .NET v1
code at the repository root is frozen and will be removed at promotion.

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen definition of the app target and the `VoxFlow` scheme |
| `VoxFlow/` | SwiftUI app shell: App, MainWindow, MenuBar, FlowBar, Onboarding, Settings, Design |
| `VoxFlowTests/` | App-layer tests |
| `VoxFlowKit/` | SwiftPM package with all logic: Core, Audio, Speech, Models, Files, Dictation, Storage, Styling, MCP |
| `design/` | The Claude Design canvas that is the product spec |
| `docs/adr/` | Architecture decision records for v2 |
| `docs/superpowers/` | Design specs and implementation plans |

## Build and test

Requires Xcode 26.x and XcodeGen (`brew install xcodegen`).

```bash
cd v2
xcodegen generate                       # creates VoxFlow.xcodeproj (gitignored)
xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test
```

Package-only tests, no Xcode project needed:

```bash
cd v2/VoxFlowKit && swift test
```

Open `VoxFlow.xcodeproj` in Xcode to run the app (scheme `VoxFlow`).

## CI

`.github/workflows/ci-v2.yml` runs the same two commands on `macos-15`;
`.github/workflows/codeql-v2.yml` runs CodeQL for Swift. Both trigger only for `v2/**`.
```

- [ ] **Step 5: Write ADR-001 and the ADR index**

`v2/docs/adr/001-project-structure.md`:

```markdown
# ADR-001: v2 project structure — SwiftPM package for logic, XcodeGen app shell

Status: Accepted · Date: 2026-09-07

## Context

VoxFlow v2 is a from-scratch Swift rewrite (spec: `docs/superpowers/specs/2026-09-07-voxflow-v2-design.md`).
The app has several independent concerns (audio, speech engine, models, files, dictation,
storage, styling, MCP) that must be testable without launching UI, and the project is
edited mostly by AI agents working on small, well-bounded files.

## Decision

- All logic lives in the SwiftPM package `VoxFlowKit` as nine library modules, one per
  concern, each with its own Swift Testing target. `VoxFlowCore` imports only Foundation
  and declares the protocols the other modules implement; every other module depends on
  Core; modules never import the app.
- The app target `VoxFlow` is a thin SwiftUI/AppKit shell that only assembles screens.
- The Xcode project is generated by XcodeGen from `project.yml` and is gitignored.
- One scheme, `VoxFlow`, builds the app and runs the app tests plus all package tests.
- Swift 6 language mode with complete strict concurrency from the first commit.

## Alternatives considered

- **Checked-in `.xcodeproj`**: standard, but the pbxproj is hostile to review and to
  agent edits and produces merge conflicts.
- **Pure SwiftPM executable + bundling script**: simplest, but entitlements, TCC prompts
  and notarization all want a real app target.
- **One big app target, no package**: fastest to start, but logic tests would need
  `xcodebuild` and the module boundaries would erode.

## Consequences

- Contributors and CI need XcodeGen (`brew install xcodegen`, ~30 s).
- New concerns get a new module and test target, not a folder in the app.
- Strict concurrency makes AppKit bridging more verbose; accepted for dictation safety.
```

`v2/docs/adr/README.md`:

```markdown
# v2 Architecture Decision Records

| ADR | Decision | Status |
|-----|----------|--------|
| [001](001-project-structure.md) | SwiftPM package for logic, XcodeGen app shell, Swift 6 | Accepted |

v1 ADRs (001–027) live in the repository root under `docs/adr/` and `docs/architecture/06-decision-log.md`
until promotion; they describe the archived .NET implementation and do not apply to v2.
```

- [ ] **Step 6: Commit**

```bash
git add v2/.gitignore v2/design v2/README.md v2/docs/adr
git commit -m "docs(v2): add .gitignore, design source, README and ADR-001

Detailed grouped .gitignore (generated Xcode project, SPM, test output,
model files, signing secrets). Design canvas checked in as the product spec.
ADR-001 records the package-plus-shell structure. Refs #107."
```

---

### Task 4: CI workflows for v2 (`ci-v2.yml`, `codeql-v2.yml`)

**Files:**
- Modify: `.github/workflows/ci-v2.yml` (exists on `develop` once PR #106 is merged; if it is not yet merged, `git merge develop` first and, if the file is still absent, create it with the full content below)
- Modify: `.github/workflows/codeql-v2.yml` (same rule)

**Interfaces:**
- Consumes: `v2/project.yml` scheme `VoxFlow` from Task 2.
- Produces: green checks on the PR.

- [ ] **Step 1: Bring the branch up to date**

Run: `git fetch origin && git merge --no-edit origin/develop && ls .github/workflows/`
Expected: `ci-v2.yml` and `codeql-v2.yml` listed. If not, create them from the content in Steps 2–3.

- [ ] **Step 2: Write `ci-v2.yml`**

```yaml
name: CI v2

# Validate the v2 native Swift rewrite that lives under v2/ (see issue #105).
# Runs only when v2/ (or this workflow) changes; the .NET v1 code is covered by ci.yml.
on:
  push:
    branches:
      - master
      - develop
    paths:
      - 'v2/**'
      - '.github/workflows/ci-v2.yml'
  pull_request:
    paths:
      - 'v2/**'
      - '.github/workflows/ci-v2.yml'
  workflow_dispatch:

concurrency:
  group: ci-v2-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    name: Build & test (Swift)
    # macos-15 runners are Apple Silicon, the only target v2 supports.
    runs-on: macos-15

    defaults:
      run:
        working-directory: v2

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # The image defaults to Xcode 16.x; v2 is developed with Xcode 26.x. Pick the newest 26.
      - name: Select Xcode 26
        run: |
          XCODE=$(ls -d /Applications/Xcode_26*.app | sort -V | tail -1)
          sudo xcode-select -s "$XCODE"
          xcodebuild -version
          swift --version

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Cache SPM packages and DerivedData
        uses: actions/cache@v4
        with:
          path: |
            ~/Library/Developer/Xcode/DerivedData
            v2/VoxFlowKit/.build
          key: ${{ runner.os }}-spm-${{ hashFiles('v2/VoxFlowKit/Package.swift', 'v2/**/Package.resolved') }}
          restore-keys: |
            ${{ runner.os }}-spm-

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Build
        run: |
          set -o pipefail
          xcodebuild -scheme VoxFlow -destination 'platform=macOS' build | tee build.log

      - name: Test
        run: |
          set -o pipefail
          xcodebuild -scheme VoxFlow -destination 'platform=macOS' test -resultBundlePath TestResults.xcresult | tee test.log

      - name: Package tests without Xcode project
        run: swift test
        working-directory: v2/VoxFlowKit

      - name: Upload logs and results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: v2-test-results
          path: |
            v2/build.log
            v2/test.log
            v2/TestResults.xcresult
          if-no-files-found: ignore
```

- [ ] **Step 3: Write `codeql-v2.yml`**

```yaml
name: CodeQL v2

# CodeQL for the v2 Swift rewrite under v2/ (see issue #105).
# CodeQL supports Swift only on macOS runners, hence macos-15 rather than ubuntu-latest.
on:
  push:
    branches:
      - master
      - develop
    paths:
      - 'v2/**'
      - '.github/workflows/codeql-v2.yml'
  pull_request:
    paths:
      - 'v2/**'
      - '.github/workflows/codeql-v2.yml'
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:

jobs:
  analyze:
    name: Analyze Swift
    runs-on: macos-15

    permissions:
      security-events: write
      actions: read
      contents: read

    strategy:
      fail-fast: false
      matrix:
        language: ['swift']

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # The weekly schedule fires on master, which has no v2/ until promotion; skip until it does.
      - name: Probe for Swift sources
        id: probe
        run: |
          if [ -n "$(find v2 -name '*.swift' -print -quit 2>/dev/null)" ]; then
            echo "has_swift=true" >> "$GITHUB_OUTPUT"
          else
            echo "has_swift=false" >> "$GITHUB_OUTPUT"
            echo "::notice::No Swift sources under v2/ on this ref; skipping CodeQL Swift analysis."
          fi

      - name: Select Xcode 26
        if: steps.probe.outputs.has_swift == 'true'
        run: |
          XCODE=$(ls -d /Applications/Xcode_26*.app | sort -V | tail -1)
          sudo xcode-select -s "$XCODE"
          xcodebuild -version

      - name: Install XcodeGen
        if: steps.probe.outputs.has_swift == 'true'
        run: brew install xcodegen

      - name: Initialize CodeQL
        if: steps.probe.outputs.has_swift == 'true'
        uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}

      - name: Build
        if: steps.probe.outputs.has_swift == 'true'
        working-directory: v2
        run: |
          xcodegen generate
          xcodebuild -scheme VoxFlow -destination 'platform=macOS' build

      - name: Perform CodeQL Analysis
        if: steps.probe.outputs.has_swift == 'true'
        uses: github/codeql-action/analyze@v3
        with:
          category: '/language:${{ matrix.language }}'
```

- [ ] **Step 4: Validate the YAML locally**

Run: `for f in .github/workflows/ci-v2.yml .github/workflows/codeql-v2.yml; do ruby -ryaml -e "YAML.load_file('$f'); puts '$f ok'"; done`
Expected: two `ok` lines.

- [ ] **Step 5: Commit and push**

```bash
git add .github/workflows/ci-v2.yml .github/workflows/codeql-v2.yml
git commit -m "ci(v2): select Xcode 26, install XcodeGen and run package tests

The scheme needs the generated project, so the workflows install XcodeGen
and run xcodegen generate before xcodebuild. Xcode 26.x matches the local
toolchain. Triggers now include the develop integration branch. Refs #107."
git push -u origin feature/107-v2-scaffold-ci
```

- [ ] **Step 6: Watch CI**

Run: `gh run list --branch feature/107-v2-scaffold-ci --limit 5` then `gh run watch <id> --exit-status` for the `CI v2` run.
Expected: `CI v2` and `CodeQL v2` both succeed. If `Select Xcode 26` fails because no `Xcode_26*` exists on the image, fall back to `Xcode_16.4.app` in the workflow and note the toolchain difference in the PR.

---

### Task 5: Pull request and issue update

**Files:** none new.

- [ ] **Step 1: Open the PR into `develop`**

Body must follow `.github/pull_request_template.md` (Summary, Testing, Checklist) and map each acceptance criterion of #107 to what was done. Attach `/tmp/voxflow-phase0.png`. End with `Closes #107`. No AI attribution.

```bash
gh pr create --base develop --head feature/107-v2-scaffold-ci \
  --title "feat(v2): phase 0 scaffold, CI and .gitignore" --body-file <body.md>
```

- [ ] **Step 2: Tick the acceptance criteria on #107 and comment**

Edit the issue body: `- [ ]` → `- [x]` for every criterion that is met; post a comment with test counts (app tests 4, package tests 9) and CI run links. Leave the issue open until the PR is merged; close it as completed after the merge.

---

## Self-review

- **Spec coverage.** Section 3 layout → Tasks 1–3. Section 7 CI → Task 4. Section 6 branching → Global Constraints and Task 5. Issue #107 acceptance criteria: `.gitignore` (T3), local build/test command (T2 step 6), `swift test` (T1 step 6), green workflows (T4), 7-page window + menu bar item (T2 step 7), `design/` (T3), README + ADR (T3). Empty per-screen folders from the issue scope are intentionally not created (git cannot track empty folders; they appear when their phase adds files) — say so in the PR.
- **Placeholders.** None: every file has full content; the only external input is the design file path, supplied by the orchestrator.
- **Type consistency.** `SidebarPage` (title, systemImage, shortcutNumber, default) is used identically in the test, `SidebarView`, `MainWindow`, `PlaceholderPageView`. `Palette.onDevice` used in `SidebarView` and `MenuBarContent`. `MainWindowID.main` used in `VoxFlowApp` and `MenuBarContent`. `VoxFlowVersion.string` used in `SidebarView`, tests and module placeholders.
