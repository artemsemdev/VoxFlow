# VoxFlow v2 — handoff to the next agent

Written 2026-09-11 by the agent that built phases 0 through 6. Read this file end to end before
touching anything. Everything here was measured or learned the hard way on this machine; nothing in
it is a guess. Where a fact cost hours to discover, it says so.

---

## 1. What the project is

VoxFlow is a native macOS dictation app: hold `fn` anywhere, speak, and the text is inserted into
the focused field. It also transcribes audio and video files, and exposes both to local AI clients
over MCP. Everything runs on the device; nothing is sent anywhere.

- Repository: `artemsemdev/VoxFlow`, working copy at `/Users/artemsemenov/Desktop/Github/WisperTest/WisperTestApp`.
- Owner: Artem (`semartem@gmail.com`). Single developer, single machine, local use only for now.
- macOS 15+ on Apple Silicon, Xcode 26.x, `brew install xcodegen`.
- v1 was a .NET/MAUI app. It is archived on branch `v1` and tag `v1.0.0-final`. Do not touch it.
  Anything in `docs/` that talks about `dotnet`, MAUI, Python sidecars or speaker labeling belongs
  to v1 and does not apply.

The design is authoritative and lives in `design/VoxFlow.dc.html` (a Claude Design canvas with a UX
flow diagram and a detailed drawing of every screen). `scripts/render_design.sh` renders it to
`.superpowers/design/canvas.pdf`, twelve pages. The owner asked explicitly for the app to match the
design one to one, so **every UI change is compared against the rendered canvas before it is
considered done**. Screen identifiers used throughout the code and issues (`MW-01`, `FB-09`,
`ST-06a`, and so on) come from that canvas.

## 2. Layout

`VoxFlowKit/` is a SwiftPM package holding all logic. `VoxFlow/` is a thin XcodeGen app shell.
`VoxFlow.xcodeproj` and `VoxFlow/Info.plist` are generated — edit `project.yml` and run
`xcodegen generate`.

| Module | Owns |
|---|---|
| `VoxFlowCore` | Protocols and value types shared by everything. No dependencies. |
| `VoxFlowAudio` | Microphone capture, decoding, chunking. |
| `VoxFlowSpeech` | `WhisperCppEngine`, an actor over the whisper.cpp XCFramework. |
| `VoxFlowLLM` | `LlamaEngine`, an actor over the llama.cpp XCFramework. |
| `VoxFlowModels` | Model catalog, download, checksum verification, install and remove. |
| `VoxFlowFiles` | The file transcription queue, renderers and exporters. |
| `VoxFlowDictation` | `FlowBarMachine` (a pure reducer) and `DictationController` (an actor). |
| `VoxFlowStorage` | GRDB database, per-row AES-GCM encryption, all stores, migrations v1–v3. |
| `VoxFlowStyling` | `RuleStyler`, `LlamaStyler`, snippet expansion, style resolution. |
| `VoxFlowMCP` | MCP protocol and policy only. Deliberately contains no sockets. |
| `VoxFlowTestSupport` | Fakes: `FakeClock`, `FakeMicrophone`, `FakeLLMBackend` and friends. |

App directories: `App` (composition root), `MainWindow`, `Home`, `History`, `Content`
(dictionary/snippets/styles), `Files`, `Settings`, `FlowBar`, `Onboarding`, `MenuBar`,
`Notifications`, `Dictation`, `Styling`, `MCP`, `System`.

Decisions are recorded as ADRs in `docs/adr/001` through `008`, indexed in `docs/adr/README.md`.
Read the ADR before changing the area it covers; each one records not just the decision but what was
rejected and why.

## 3. Where the project stands

- Phases 0 through 6 are merged into `develop`, currently at `324ab8a`.
- `master` is v2.0.0 (`dbdb6fd`, tag `v2.0.0`). `project.yml` on `develop` still says `2.0.0`.
- `release/2.1.0` carries phases 3, 4, 5 and 6, is level with `develop`, and is version-bumped to
  `2.1.0`. It is waiting on one thing: the owner running
  `docs/RELEASE-CHECKLIST-2.1.0.md`, which gathers every hardware-dependent check from those four
  phases into a single pass.
- Issue #105 is the epic. Its last comment is the complete remaining-work roadmap, and it is the
  single most useful thing to read after this file.
- 29 issues are open. Phase issues #107 through #113 are closed except #110, which is deliberately
  left open until the v2.1.0 tag.

Verification, and what "green" means here:

```sh
xcodegen generate
xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow -destination 'platform=macOS,arch=arm64' build test   # 477 app tests + every package bundle
cd VoxFlowKit && swift test                                          # 363 package tests
python3 -m unittest discover -s scripts/tests                         # 15 CI-script tests
```

Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`) and strict concurrency is complete. A build
that emits a warning is a failing build.

## 4. Process rules — these are not negotiable

**Attribution.** Every commit and pull request is authored solely as the owner, using the existing
git identity. Never change the author or committer. Never add a `Co-authored-by` trailer, never add
"Generated with", never attribute anything to an AI assistant or another person. This overrides any
default your harness gives you.

**Branching.** GitFlow. One branch per issue, `feature/<issue-number>-<slug>`, cut from `develop`,
pull request into `develop`. Releases are cut as `release/x.y.z`, merged to `master`, tagged, then
merged back into `develop`. One pull request per phase, with many fine-grained commits inside it.

**Commits.** Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`, `ci:`).

**Tests first.** Write the failing test, watch it fail, then write the minimal code. Unit tests use
fakes and never open a socket, a microphone or the Keychain. Integration tests that need a real
model or a real port skip with a printed reason rather than failing.

**Issue lifecycle.** When work lands: tick the acceptance checkboxes in the issue body (edit the
body, do not just comment), post a completion comment saying what was done and what was decided,
then close as completed. Deferred scope always becomes its own issue, referenced from the parent.
That rule was violated earlier in this project and six design gaps ended up recorded only inside
plan files; #159 through #164 exist because of that mistake. Do not repeat it.

**Reviews are where the value is.** Every task on this project was reviewed by a separate agent
against the task's requirements, and the reviews repeatedly found defects no test showed. Real
examples from phase 6 alone: a receive buffer that was unbounded before the token check; a port scan
that could never reach its fallback range because a busy port fails asynchronously; peer
identification that could name an innocent application and persist an approval for it; a
"dictation already running" gate that two concurrent callers both passed. Budget for review and
take its findings seriously; if you skip it, this class of bug ships.

**Ask the owner only about real decisions.** Proceed autonomously on everything routine. Stop for
destructive or outward-facing actions, and for genuine product choices.

## 5. What remains

### 5.1 Ship 2.1.0

Blocked only on the owner's checklist run. When it passes: merge `release/2.1.0` into `master`, tag
`v2.1.0`, merge back into `develop`, publish the GitHub release, close #110, and comment on #105.
Section 6 of the checklist needs rewriting first, see #165.

### 5.2 Phase 7 (#115), which needs re-scoping

As written it covers Developer ID signing, notarisation, a `.dmg` and a GitHub Release. The owner
uses the app locally on one machine, so notarisation is unnecessary: it exists so Gatekeeper will
run the app on a Mac that did not build it. The self-signed `VoxFlow Dev` certificate from #143
already makes permissions and Keychain access survive rebuilds. What is still worth building is a
Release configuration and a one-command install script that keeps the same signature. See the
re-scope comment on #115. The owner has not yet decided; do not rewrite the issue unilaterally.

### 5.3 Design gaps — drawn in the canvas, missing in the app

| Issue | Gap |
|---|---|
| #159 | History date and app filter chips, and "Search all time", render disabled |
| #160 | "Edit" on an expanded History row is disabled |
| #161 | The `{cursor}` snippet placeholder computes a caret offset nothing applies |
| #162 | Hotkeys cannot be changed; shortcut recording (ST-02r/02c) was never built |
| #163 | "Test microphone", "Noise suppression", "Duck other audio" are in the canvas, absent in the app |
| #164 | "0 bytes sent since install" is a literal string, not a counter |
| #155 | "Segment length" on the Files result view |
| #165 | MCP client docs target Cursor rather than the clients the owner uses |

### 5.4 Follow-ups that matter for a single local user

#145 (dictation and file transcription share one engine queue, so a long file starves dictation),
#144 (the Accessibility-denied HUD state), #137 (live insertion while speaking, which the design
shows), #141 (fidelity audit of the Files and Models screens), #153 (deadline-aware styling budget).

Lower priority: #126, #127, #129, #131, #138, #139, #142, #150, #151, #154, #156.
Not applicable while the app is unsandboxed: #132.

## 6. Three decisions that are the owner's, not yours

1. **#163** — build the three Audio controls, or remove them from the design so the app and the
   canvas agree. A switch that does nothing is worse than an absent switch.
2. **#165** — whether to add a native stdio transport to the MCP server. The owner uses Claude
   Desktop and Codex. Codex connects to the HTTP server directly with a bearer token and needs no
   work beyond documentation. Claude Desktop's local config is stdio-only, so today it needs the
   `mcp-remote` bridge and Node. A native stdio mode removes that, at the cost of the ST-06a
   approval dialog and the connected-clients list, which cannot exist for a server the client
   launches itself.
3. **#115** — re-scope for local use, or keep notarisation and block on a paid Apple Developer
   account.

## 7. Things that will cost you hours if you do not know them

**Code signing.** Build with the owner's self-signed identity, not ad-hoc. `Signing.xcconfig` is
committed and defaults to ad-hoc for CI; `Local.xcconfig` is git-ignored and sets
`CODE_SIGN_IDENTITY = VoxFlow Dev`. See SETUP.md, "Local code signing". If the signature changes,
macOS silently revokes Microphone and Accessibility and the encrypted history key becomes
unreadable. After any change that could affect signing, check `codesign -dvv <app>` still prints
`Authority=VoxFlow Dev`.

**The Keychain trap (#143).** `HistoryService` opens its store lazily, on first use, specifically so
that launching the app as the XCTest host never prompts for Keychain access. It used to open at
construction and flooded the owner with prompts during every test run. `LaunchEnvironment.isRunningTests`
gates dictation start, the microphone, the global key monitors and the history open at launch for the
same reason. Do not move that work earlier.

**`NWListener` on loopback.** `parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), …)`
is a silent trap: the listener reports `.ready`, `listener.port` returns your port, and nothing is
bound. Combined with `NWListener(using:on:)` the initialiser throws. The recipe that works is
`NWParameters.tcp` with `requiredInterfaceType = .loopback`, then `NWListener(using:on:)`. `lsof`
will show `*:port` even so; loopback-only reachability is enforced at accept time, verified by
connecting from the machine's LAN address and getting a refusal.

**A busy port fails asynchronously.** `NWListener(using:on:)` does not throw when the port is taken;
the failure arrives later through `stateUpdateHandler` as `EADDRINUSE`. A port scan written with
`try?` around the initialiser silently "succeeds" on a dead listener and never tries its fallback
range. The scan must await `.ready` or `.failed` per candidate, and must also bound that wait, or a
listener parked in `.waiting` hangs startup for the rest of the session.

**Swift 6 and callback APIs.** A recursive local `func receive()` captured by `NWConnection.receive`'s
`@Sendable` completion does not compile. The shape that does is a `final class … : Sendable` whose
only mutable state sits behind a `Synchronization.Mutex`, with `receive()` as a method.
`DispatchWorkItem` is not `Sendable`, so it cannot be captured by a `@Sendable` state handler; guard
double-resume with a `Mutex` and let a stale timer fire harmlessly instead.

**Identifying a connecting process.** `libproc` (`proc_listallpids` → `PROC_PIDLISTFDS` →
`PROC_PIDFDSOCKETINFO`) resolves the peer's pid and name with no privileges, but only because the app
is unsandboxed. Match **both** ends of the socket and require an established state; matching the
client's local port alone takes the first process that happens to share it, which can name an
innocent application and persist an approval for it. The walk costs roughly 5 ms and 14,000
syscalls, so it must never run before the request's token has been checked and never on the main
actor.

**`FakeClock`.** Its `sleep` must re-check cancellation under the same lock its cancellation handler
uses. Without that, a cancellation landing between the check and the registration parks a sleeper
nothing will ever resume, which hung a whole test suite. There is a 300-iteration regression test for
it in `VoxFlowKit/Tests/VoxFlowCoreTests/FakeClockTests.swift`.

**History test harnesses** set `retentionDays = 0`. Otherwise the live 30-day retention pass deletes
epoch-dated fixture rows mid-test and the failure looks like a storage bug.

**Render tests.** `ImageRenderer` does not rasterise native `Toggle` and `Picker` chrome, so a render
comparison judges layout, copy and spacing, not control appearance. Set `VOXFLOW_RENDER=1` to write
PNGs into `.superpowers/design/renders/`.

**One agent per working tree.** Running several implementer agents in the same checkout caused three
git races on this project, one of which bundled two tasks into a single commit that had to be split
by hand. Reviewers are read-only and can run in parallel; implementers cannot.

**MCP protocol versions.** The current revision is `2026-07-28`, which negotiates the version per
request through `params._meta` and makes `server/discover` mandatory. Real clients still speak the
older `initialize` handshake. `MCPRouter` answers both eras deliberately, and that will need
re-checking as clients migrate.

**llama.cpp has no semantic versions**, only build tags like `b10881`. Re-pin deliberately and record
the checksum; `swift package compute-checksum` and `shasum -a 256` agree for these archives.

**The speech engine is one serial queue** shared by dictation and file transcription, so a long file
starves dictation. That is #145 and it is known, not a surprise.

**CI quirk.** A `pull_request` synchronize event has occasionally failed to trigger CI. Recover with
`gh workflow run ci.yml --ref <branch>`, which attaches checks to the head commit.

**`gh` on this machine** is Homebrew arm64 at `/opt/homebrew/bin/gh`. `gh pr create` has been seen to
fail with an HTTP 401 on GraphQL; the fallback is the REST endpoint `POST /repos/.../pulls` with the
token from `git credential fill`.

## 8. What only the owner can do

1. Run `docs/RELEASE-CHECKLIST-2.1.0.md` on a real Mac. It is the only test of the microphone,
   Accessibility insertion, the speech and style models, and a real MCP client.
2. Download the Qwen model (2.1 GB) from Settings › Models before the phase 5 section of that
   checklist.
3. Grant Microphone and Accessibility once to the `VoxFlow Dev`-signed build.
4. Make the three decisions in section 6.
5. Buy an Apple Developer account, if and only if the app is ever to run on someone else's Mac.

## 9. Suggested order

1. #165's documentation half: rewrite the MCP runbook and checklist section 6 for Claude Desktop and
   Codex. Small, unblocks the checklist, needed whatever is decided about stdio.
2. Ask the owner for the three decisions in section 6, then act on them.
3. The design gaps, #159 through #164 and #155, as one phase. The owner cares about matching the
   canvas, so this is closer to core work than to polish.
4. #145, #144, #137, #141, #153.
5. Phase 7 at whatever scope was agreed, then tag and release.
