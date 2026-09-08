# VoxFlow v2 Phase 3a — Dictation logic (capture, Flow Bar machine, windows, history) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything the Flow Bar needs below the UI: microphone capture as 16 kHz chunks with RMS, a pure Flow Bar state machine covering FB-01…FB-12 with the design's timings, windowed transcription over `SpeechEngine` so text arrives while the user keeps talking, a `DictationController` that drives machine + microphone + transcriber + inserter, and encrypted dictation history on GRDB with 30-day retention. Phase 3b adds the HUD panel, the fn hotkey monitor, the Accessibility inserter, onboarding and the History page.

**Architecture:** `FlowBarMachine` is a value type: `handle(event, now) -> [effect]`; timers are effects with ids, so every transition is a unit test without a clock. `DictationController` (actor) executes effects with injected `MicrophoneCapturing`, `DictationTranscribing`, `TextInserting` and `MonotonicClock`. `WindowedTranscriber` cuts the live audio into windows (≥ 3 s ending in silence, ≤ 10 s) and runs `SpeechEngine.transcribe` per window with the previous text's tail as prompt context. `DictationStore` (GRDB) encrypts `text`/`raw_text` per row with AES-GCM; the key comes from a `HistoryKeyProviding` (Secure Enclave wrap, Keychain fallback).

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing, AVFoundation (`AVAudioEngine` tap + `AVAudioConverter`), CryptoKit, Security.framework (Keychain), GRDB.swift 7.11.1.

**Spec:** design spec §1 (dictation loop), §4 (`MicrophoneSource`, windows), §5 (storage, encryption, retention); canvas FB-01…FB-12, 3d "Hotkey timing", "Listening", "Processing", "Auto-dismiss", 3e "Long dictation", "Mic busy", "Secure input", "Focus changes mid-dictation", "Wrong language detected", MW-02/ST-05 copy for retention. Issue #110 (logic half); ruling on #125 below.

**Rulings taken in this plan (record in the ledger, do not re-decide):**
1. **#125 cancellation contract.** Option 1: the stream may end silently when the consumer is cancelled mid-run; every consumer checks `Task.isCancelled` after the loop. `WindowedTranscriber` throws `DictationError.cancelled` in that case. #125 closes with this PR.
2. **Capture starts on fn-down**, before the 250 ms hold / 350 ms double-tap decision, so no syllable is lost. A lone short tap discards the buffer silently.
3. **Insertion is one final write** at the end of a dictation. Windows are transcribed while listening and the partial text is kept for the chip / "Copy raw transcript", but nothing is inserted before the user stops. Live insertion is a phase-4 follow-up issue.
4. **Focus target** is captured by the inserter at start (phase 3b); the machine only knows `InsertionResult`.
5. **FB-09 Paused** belongs to phase 4 (menu bar). Not in this plan.
6. **Search over encrypted history** runs in memory after decryption (history is thousands of rows, not millions).
7. **Exclusive-use detection** ("Microphone in use by Zoom") is reported as `MicrophoneError.engineFailed` in 3a and rendered as the generic FB-07 variant; naming the other app needs CoreAudio hog-mode queries — a follow-up issue.

## Global Constraints

- Swift 6 language mode, strict concurrency. No `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated` except one documented box confined to the audio queue in `MicrophoneSource` (same pattern as `ContextBox` in `WhisperCppEngine`).
- `VoxFlowCore` imports Foundation only. `VoxFlowDictation` imports Core only (no AVFoundation, no Speech). `VoxFlowStorage` imports Core, GRDB, CryptoKit, Security. `VoxFlowAudio` gains `MicrophoneSource`.
- No sleeps in tests. Gates, `FakeClock.advance`, and stream reads drive time.
- Timings and copy are the design's: hold ≥ 250 ms, double-tap ≤ 350 ms, silence stop 3 s (range 1…10 s), cap 15 min (900 s), "Taking longer…" after 8 s, give up after 20 s, auto-dismiss Inserted 1.5 s / Copied 2.5 s / Discarded 0.8 s / errors 4 s.
- Nothing is inserted for an empty result; "< 2 words with low confidence" is FB-05.
- Audio is never written to disk. History stores text only.
- Commits: Conventional Commits, owner-authored, no attribution trailers. Branch `feature/110-phase3a-dictation-logic` from `develop`; PR into `develop`.
- Verification per task: `cd VoxFlowKit && swift test --filter <Module>Tests`; at the end `swift test` for the package and `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test` from the repo root.

---

### Task 1: Core — dictation protocols, clock, prompt context; TestSupport fakes

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowCore/Dictation.swift`
- Create: `VoxFlowKit/Sources/VoxFlowCore/MonotonicClock.swift`
- Modify: `VoxFlowKit/Sources/VoxFlowCore/Speech.swift` (`TranscriptionOptions.promptContext`)
- Create: `VoxFlowKit/Sources/VoxFlowTestSupport/FakeMicrophone.swift`, `FakeTextInserter.swift`, `FakeClock.swift`
- Test: `VoxFlowKit/Tests/VoxFlowCoreTests/DictationProtocolsTests.swift`, `VoxFlowKit/Tests/VoxFlowCoreTests/FakeClockTests.swift`

**Interfaces:**
- Produces: `AudioChunk`, `MicrophoneError`, `MicrophoneEvent`, `MicrophoneCapturing`, `InsertionResult`, `TextInserting`, `MonotonicClock`, `SystemMonotonicClock`, `TranscriptionOptions.promptContext`; fakes `FakeMicrophone`, `FakeTextInserter`, `FakeClock`.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowCoreTests/DictationProtocolsTests.swift`:
```swift
import Foundation
import Testing
@testable import VoxFlowCore

@Suite("Dictation protocols")
struct DictationProtocolsTests {
    @Test("AudioChunk computes RMS and duration at 16 kHz")
    func chunk() {
        let chunk = AudioChunk(samples: [0.5, -0.5, 0.5, -0.5])
        #expect(abs(chunk.rms - 0.5) < 1e-6)
        #expect(chunk.duration == 4 / 16_000)
        #expect(AudioChunk(samples: []).rms == 0)
    }

    @Test("initial prompt joins vocabulary and prompt context; nil when both empty")
    func prompt() {
        #expect(TranscriptionOptions().initialPrompt == nil)
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow", "GRDB"]).initialPrompt == "VoxFlow, GRDB")
        #expect(TranscriptionOptions(promptContext: "so we said").initialPrompt == "so we said")
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow"], promptContext: "so we said").initialPrompt == "VoxFlow\nso we said")
    }

    @Test("SystemMonotonicClock never goes backwards and sleeps at least the requested time")
    func systemClock() async throws {
        let clock = SystemMonotonicClock()
        let a = clock.now()
        try await clock.sleep(for: 0.01)
        let b = clock.now()
        #expect(b - a >= 0.01)
    }
}
```

`Tests/VoxFlowCoreTests/FakeClockTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport

@Suite("FakeClock")
struct FakeClockTests {
    @Test("advance resumes sleepers whose deadline passed, in deadline order")
    func advance() async throws {
        let clock = FakeClock()
        let order = OrderLog()
        let long = Task { try await clock.sleep(for: 2); await order.append("long") }
        let short = Task { try await clock.sleep(for: 1); await order.append("short") }
        await clock.waitForSleepers(2)
        await clock.advance(by: 1)
        _ = try await short.value
        #expect(await order.entries == ["short"])
        await clock.advance(by: 1)
        _ = try await long.value
        #expect(await order.entries == ["short", "long"])
        #expect(clock.now() == 2)
    }

    @Test("cancelling a sleeping task throws CancellationError and drops the sleeper")
    func cancel() async {
        let clock = FakeClock()
        let task = Task { try await clock.sleep(for: 5) }
        await clock.waitForSleepers(1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await clock.sleeperCount == 0)
    }
}

actor OrderLog {
    var entries: [String] = []
    func append(_ s: String) { entries.append(s) }
}
```

- [ ] **Step 2: Run** `cd VoxFlowKit && swift test --filter VoxFlowCoreTests` — expect compile failures (types missing).

- [ ] **Step 3: Implementation**

`Sources/VoxFlowCore/Dictation.swift`:
```swift
import Foundation

/// A slice of microphone audio in the internal format (16 kHz mono Float32) with its loudness.
public struct AudioChunk: Sendable, Equatable {
    public var samples: [Float]
    /// Root mean square of `samples`, 0 for an empty chunk. Drives the 14-bar waveform and silence detection.
    public var rms: Float

    public init(samples: [Float]) {
        self.samples = samples
        rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    public var duration: TimeInterval { Double(samples.count) / AudioSamples.sampleRate }
}

public enum MicrophoneError: Error, Equatable, Sendable {
    case accessDenied
    case noInputDevice
    /// The audio engine could not start or stopped; the other app, when known, is in the string.
    case engineFailed(String)
}

public enum MicrophoneEvent: Sendable, Equatable {
    case chunk(AudioChunk)
    /// The default input device changed (design ST-04n); nil when no device is left.
    case deviceChanged(name: String?)
}

/// Live microphone input. Capture runs until the consuming task is cancelled.
public protocol MicrophoneCapturing: Sendable {
    func start() -> AsyncThrowingStream<MicrophoneEvent, Error>
}

public enum InsertionResult: Sendable, Equatable {
    /// Text went into the focused field of `appName` (FB-04).
    case inserted(appName: String?)
    /// No editable field, or Accessibility unavailable: text is on the clipboard (FB-04b).
    case copiedToClipboard
}

/// Puts dictated text where the user was typing. Never throws: the clipboard is the fallback.
public protocol TextInserting: Sendable {
    func insert(_ text: String) async -> InsertionResult
}
```

`Sources/VoxFlowCore/MonotonicClock.swift`:
```swift
import Foundation

/// Time for the dictation loop: monotonic seconds plus a cancellable sleep. Fakes advance it by hand.
public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemMonotonicClock: MonotonicClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> TimeInterval {
        let elapsed = origin.duration(to: ContinuousClock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
```

In `Speech.swift`, `TranscriptionOptions` gains:
```swift
    /// Tail of the text recognized so far, so whisper conditions the next window on it (phase 3 windows).
    public var promptContext: String?

    public init(language: String? = nil, vocabulary: [String] = [], threadCount: Int? = nil,
                noSpeechThreshold: Double = 0.6, promptContext: String? = nil) { … promptContext = promptContext }

    public var initialPrompt: String? {
        let parts = [vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", "), promptContext].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
```
Keep `Equatable` synthesis working (add the field only).

`Sources/VoxFlowTestSupport/FakeClock.swift`:
```swift
import Foundation
import Synchronization
import VoxFlowCore

/// Manual clock: time moves only through `advance(by:)`, which resumes sleepers in deadline order.
public final class FakeClock: MonotonicClock, Sendable {
    private struct Sleeper { let id: UUID; let deadline: TimeInterval; let continuation: CheckedContinuation<Void, any Error> }
    private struct State { var now: TimeInterval = 0; var sleepers: [Sleeper] = []; var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = [] }
    private let state = Mutex(State())

    public init() {}

    public func now() -> TimeInterval { state.withLock { $0.now } }
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + seconds, continuation: continuation))
                    let ready = s.waiters.filter { $0.count <= s.sleepers.count }
                    s.waiters.removeAll { $0.count <= s.sleepers.count }
                    return ready.map(\.continuation)
                }
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `count` tasks are parked in `sleep`.
    public func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.sleepers.count >= count { return true }
                s.waiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has passed, earliest first.
    public func advance(by seconds: TimeInterval) async {
        let due = state.withLock { s -> [Sleeper] in
            s.now += seconds
            let due = s.sleepers.filter { $0.deadline <= s.now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        due.forEach { $0.continuation.resume() }
        await Task.yield()
    }
}
```

`Sources/VoxFlowTestSupport/FakeMicrophone.swift`:
```swift
import Foundation
import Synchronization
import VoxFlowCore

/// Scripted microphone: tests push chunks with `emit`, fail it with `fail`, and see when capture starts/stops.
public final class FakeMicrophone: MicrophoneCapturing, Sendable {
    private struct State {
        var continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation?
        var startCount = 0
        var stopCount = 0
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    public init() {}

    public var startCount: Int { state.withLock { $0.startCount } }
    public var stopCount: Int { state.withLock { $0.stopCount } }
    public var isCapturing: Bool { state.withLock { $0.continuation != nil } }

    public func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [state] _ in
                let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                    s.continuation = nil; s.stopCount += 1
                    defer { s.stopWaiters.removeAll() }
                    return s.stopWaiters
                }
                waiters.forEach { $0.resume() }
            }
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.continuation = continuation; s.startCount += 1
                defer { s.startWaiters.removeAll() }
                return s.startWaiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    public func emit(_ chunk: AudioChunk) { state.withLock { $0.continuation?.yield(.chunk(chunk)) } }
    public func emit(rms: Float, seconds: Double = 0.1) {
        let count = Int(seconds * AudioSamples.sampleRate)
        emit(AudioChunk(samples: Array(repeating: rms, count: count)))
    }
    public func fail(_ error: MicrophoneError) { state.withLock { $0.continuation?.finish(throwing: error) } }

    public func waitUntilCapturing() async {
        await withCheckedContinuation { c in
            let ready = state.withLock { s -> Bool in
                if s.continuation != nil { return true }
                s.startWaiters.append(c); return false
            }
            if ready { c.resume() }
        }
    }

    public func waitUntilStopped() async {
        await withCheckedContinuation { c in
            let ready = state.withLock { s -> Bool in
                if s.continuation == nil && s.startCount > 0 { return true }
                s.stopWaiters.append(c); return false
            }
            if ready { c.resume() }
        }
    }
}
```

`Sources/VoxFlowTestSupport/FakeTextInserter.swift`:
```swift
import Foundation
import Synchronization
import VoxFlowCore

public final class FakeTextInserter: TextInserting, Sendable {
    private let result: Mutex<InsertionResult>
    private let inserted = Mutex<[String]>([])

    public init(result: InsertionResult = .inserted(appName: "Mail")) { self.result = Mutex(result) }

    public func setResult(_ r: InsertionResult) { result.withLock { $0 = r } }
    public var insertedTexts: [String] { inserted.withLock { $0 } }

    public func insert(_ text: String) async -> InsertionResult {
        inserted.withLock { $0.append(text) }
        return result.withLock { $0 }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter VoxFlowCoreTests` — expect PASS (all Core tests, including the new suites).

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit/Sources/VoxFlowCore VoxFlowKit/Sources/VoxFlowTestSupport VoxFlowKit/Tests/VoxFlowCoreTests
git commit -m "feat(core): dictation protocols, monotonic clock and prompt context"
```

---
### Task 2: `FlowBarMachine` — the pure Flow Bar state machine

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowDictation/FlowBarConfig.swift`
- Create: `VoxFlowKit/Sources/VoxFlowDictation/FlowBarMachine.swift`
- Delete: `VoxFlowKit/Sources/VoxFlowDictation/DictationModule.swift`, `VoxFlowKit/Tests/VoxFlowDictationTests/DictationModuleTests.swift`
- Test: `VoxFlowKit/Tests/VoxFlowDictationTests/FlowBarMachineTests.swift`

**Interfaces:**
- Consumes: `InsertionResult`, `LanguageDetection`, `MicrophoneError` (Core).
- Produces: `HotkeyMode`, `FlowBarConfig`, `Preflight`, `MicrophoneAccess`, `ModelReadiness`, `FlowBarTimer`, `FlowBarEvent`, `FlowBarEffect`, `FlowBarState`, `FlowBarMachine`. Task 4's controller executes the effects; phase 3b renders the states.

**Design (maps 1:1 to the canvas):**

| State | Canvas | Enters on | Leaves on |
|---|---|---|---|
| `idle` | FB-01 | start, every dismiss timer | fn-down |
| `loadingModel(Pending)` | FB-12 "Loading model… keep talking" | fn-down when model installed but not loaded; capture starts at once | `modelLoaded` → `armed`/`listening` per resolved mode; `modelLoadFailed` → `error` |
| `armed(Pending)` | (invisible) | fn-down with model loaded; capture starts | hold timer (250 ms) → listening(pushToTalk); fn-up → `tapped` |
| `tapped(Pending)` | (invisible) | fn-up before 250 ms | fn-down within 350 ms → listening(handsFree); double-tap timer → idle + abortCapture |
| `listening(Listening)` | FB-02 / FB-02b | above | PTT fn-up, hands-free fn-down, silence timer, cap timer → processing; esc → discarded |
| `processing(Processing)` | FB-03 (+ "Taking longer…") | above | `transcriptReady` → insert; `insertionFinished` → inserted/copied; empty/low → didntCatch; 20 s → didntCatch(rawAvailable); esc → discarded; failure → error |
| `inserted(appName, words, limitReached)` | FB-04 | insertion | dismiss 1.5 s |
| `copied` | FB-04b | insertion fallback | dismiss 2.5 s |
| `didntCatch(rawAvailable)` | FB-05 | empty / low confidence / timeout | dismiss 4 s, fn-down retries, `copyRawRequested` → copyToClipboard |
| `discarded` | FB-06 | esc | dismiss 0.8 s |
| `micUnavailable(MicrophoneAccess)` | FB-07 | preflight or `microphoneFailed` | dismiss 4 s |
| `modelNotInstalled(sizeBytes)` | FB-08 | preflight | dismiss 4 s |
| `excluded(app)` | FB-10 | preflight (excluded app or secure input) | dismiss 4 s |
| `error(message)` | FB-07 pattern "… · Open Settings" | model load / transcription failure | dismiss 4 s |

Rules: any fn-down while in a dismissable state behaves like fn-down from idle (retry). `anyKey` dismisses errors early ("or on any key"). Both hotkey modes are always active; `HotkeyMode` only picks the idle hint (3d). In hands-free listening a voiced chunk (`rms ≥ config.voiceRMS`) restarts the silence timer; push-to-talk ignores silence. Cap fires in both modes with `limitReached = true` ("15:00 · limit reached").

- [ ] **Step 1: Failing tests** — `Tests/VoxFlowDictationTests/FlowBarMachineTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowDictation

@Suite("FlowBarMachine")
struct FlowBarMachineTests {
    let ok = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded)
    let config = FlowBarConfig()

    @Test("fn-down starts capture and the hold timer; holding 250 ms → push-to-talk listening")
    func pushToTalk() {
        var m = FlowBarMachine()
        var effects = m.handle(.fnDown(ok), now: 10)
        #expect(effects == [.startCapture, .startTimer(.hold, seconds: 0.25)])
        #expect(m.state == .armed(Pending(downAt: 10, fnIsDown: true, resolvedMode: nil)))
        effects = m.handle(.timer(.hold), now: 10.25)
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 10, language: nil)))
        #expect(effects == [.startTimer(.cap, seconds: 900)])
        effects = m.handle(.fnUp, now: 12)
        #expect(m.state == .processing(Processing(startedAt: 12, takingLonger: false, limitReached: false, partialText: "")))
        #expect(effects == [.cancelTimer(.cap), .cancelTimer(.silence), .finishCapture,
                            .startTimer(.takingLonger, seconds: 8), .startTimer(.processingTimeout, seconds: 20)])
    }

    @Test("two taps within 350 ms → hands-free; a single tap discards silently")
    func handsFree() {
        var m = FlowBarMachine()
        _ = m.handle(.fnDown(ok), now: 0)
        var effects = m.handle(.fnUp, now: 0.1)
        #expect(m.state == .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)))
        #expect(effects == [.cancelTimer(.hold), .startTimer(.doubleTap, seconds: 0.35)])
        effects = m.handle(.fnDown(ok), now: 0.3)
        #expect(m.state == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        #expect(effects == [.cancelTimer(.doubleTap), .startTimer(.cap, seconds: 900), .startTimer(.silence, seconds: 3)])
        #expect(m.handle(.fnUp, now: 0.4).isEmpty)   // the release of the second tap is ignored

        var single = FlowBarMachine()
        _ = single.handle(.fnDown(ok), now: 0)
        _ = single.handle(.fnUp, now: 0.1)
        #expect(single.handle(.timer(.doubleTap), now: 0.45) == [.abortCapture])
        #expect(single.state == .idle)
    }

    @Test("hands-free: voice restarts the silence timer, silence stops, a tap stops, cap stops with limitReached")
    func handsFreeStops() {
        var m = FlowBarMachine.listening(.handsFree, at: 0)
        #expect(m.handle(.level(rms: 0.2), now: 1) == [.startTimer(.silence, seconds: 3)])
        #expect(m.handle(.level(rms: 0.001), now: 2).isEmpty)
        _ = m.handle(.timer(.silence), now: 5)
        #expect(m.state.isProcessing)

        var tap = FlowBarMachine.listening(.handsFree, at: 0)
        _ = tap.handle(.fnDown(ok), now: 4)
        #expect(tap.state.isProcessing)

        var cap = FlowBarMachine.listening(.pushToTalk, at: 0)
        _ = cap.handle(.timer(.cap), now: 900)
        guard case .processing(let p) = cap.state else { Issue.record("expected processing"); return }
        #expect(p.limitReached)
    }

    @Test("push-to-talk ignores silence; custom silence stop is clamped to 1…10 s")
    func silenceRules() {
        var m = FlowBarMachine.listening(.pushToTalk, at: 0)
        #expect(m.handle(.level(rms: 0.5), now: 1).isEmpty)
        #expect(FlowBarConfig(silenceStop: 0.2).silenceStop == 1)
        #expect(FlowBarConfig(silenceStop: 42).silenceStop == 10)
    }

    @Test("transcript → insert → inserted with words and 1.5 s dismiss; clipboard fallback → copied 2.5 s")
    func insertion() {
        var m = FlowBarMachine.processing(at: 0)
        var effects = m.handle(.transcriptReady(text: "hello there world", lowConfidence: false), now: 1)
        #expect(effects == [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .insert("hello there world")])
        effects = m.handle(.insertionFinished(.inserted(appName: "Mail")), now: 1.2)
        #expect(m.state == .inserted(appName: "Mail", words: 3, limitReached: false))
        #expect(effects == [.saveHistory, .startTimer(.dismiss, seconds: 1.5)])
        #expect(m.handle(.timer(.dismiss), now: 3) == [])
        #expect(m.state == .idle)

        var c = FlowBarMachine.processing(at: 0)
        _ = c.handle(.transcriptReady(text: "one two", lowConfidence: false), now: 1)
        #expect(c.handle(.insertionFinished(.copiedToClipboard), now: 1) == [.saveHistory, .startTimer(.dismiss, seconds: 2.5)])
        #expect(c.state == .copied)
    }

    @Test("empty or < 2 low-confidence words → didn't catch (4 s); a retry fn-down works from there")
    func didntCatch() {
        var m = FlowBarMachine.processing(at: 0)
        #expect(m.handle(.transcriptReady(text: "", lowConfidence: false), now: 1) ==
                [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .didntCatch(rawAvailable: false))
        #expect(m.handle(.fnDown(ok), now: 2) == [.cancelTimer(.dismiss), .startCapture, .startTimer(.hold, seconds: 0.25)])

        var low = FlowBarMachine.processing(at: 0)
        _ = low.handle(.transcriptReady(text: "um", lowConfidence: true), now: 1)
        #expect(low.state == .didntCatch(rawAvailable: false))

        var fine = FlowBarMachine.processing(at: 0)
        _ = fine.handle(.transcriptReady(text: "um", lowConfidence: false), now: 1)
        #expect(fine.state.isProcessing)   // one confident word is still inserted
    }

    @Test("8 s → Taking longer…; 20 s → didn't catch with raw available and capture aborted; copy raw")
    func slowProcessing() {
        var m = FlowBarMachine.processing(at: 0)
        _ = m.handle(.partialText("so far so"), now: 3)
        #expect(m.handle(.timer(.takingLonger), now: 8).isEmpty)
        guard case .processing(let p) = m.state else { Issue.record("expected processing"); return }
        #expect(p.takingLonger && p.partialText == "so far so")
        #expect(m.handle(.timer(.processingTimeout), now: 20) == [.abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .didntCatch(rawAvailable: true))
        #expect(m.handle(.copyRawRequested, now: 21) == [.copyToClipboard("so far so")])
    }

    @Test("esc while listening or processing → discarded 0.8 s, nothing saved")
    func escape() {
        var l = FlowBarMachine.listening(.pushToTalk, at: 0)
        #expect(l.handle(.escape, now: 1) == [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: 0.8)])
        #expect(l.state == .discarded)
        var p = FlowBarMachine.processing(at: 0)
        #expect(p.handle(.escape, now: 1) == [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .abortCapture, .startTimer(.dismiss, seconds: 0.8)])
        var i = FlowBarMachine()
        #expect(i.handle(.escape, now: 0).isEmpty)
    }

    @Test("preflight gates: excluded app, secure input, mic denied / no device, model missing", arguments: [
        (Preflight(excludedApp: "1Password", secureInput: false, microphone: .granted, model: .loaded), FlowBarState.excluded(app: "1Password")),
        (Preflight(excludedApp: nil, secureInput: true, microphone: .granted, model: .loaded), .excluded(app: "a secure field")),
        (Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded), .micUnavailable(.denied)),
        (Preflight(excludedApp: nil, secureInput: false, microphone: .noDevice, model: .loaded), .micUnavailable(.noDevice)),
        (Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .notInstalled(sizeBytes: 1_624_555_275)), .modelNotInstalled(sizeBytes: 1_624_555_275)),
    ])
    func gates(preflight: Preflight, expected: FlowBarState) {
        var m = FlowBarMachine()
        #expect(m.handle(.fnDown(preflight), now: 0) == [.startTimer(.dismiss, seconds: 4)])
        #expect(m.state == expected)
        #expect(m.handle(.anyKey, now: 1) == [.cancelTimer(.dismiss)])
        #expect(m.state == .idle)
    }

    @Test("model installed but not loaded: capture + load; loaded while still holding → listening; released → armed rules")
    func loadingModel() {
        let cold = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .installedNotLoaded)
        var m = FlowBarMachine()
        #expect(m.handle(.fnDown(cold), now: 0) == [.startCapture, .loadModel, .startTimer(.hold, seconds: 0.25)])
        #expect(m.state == .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        #expect(m.handle(.timer(.hold), now: 0.25).isEmpty)
        #expect(m.state == .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: .pushToTalk)))
        #expect(m.handle(.modelLoaded, now: 1.5) == [.startTimer(.cap, seconds: 900)])
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))

        var early = FlowBarMachine()
        _ = early.handle(.fnDown(cold), now: 0)
        _ = early.handle(.fnUp, now: 0.1)
        _ = early.handle(.timer(.doubleTap), now: 0.45)
        #expect(early.state == .idle)   // lone tap while loading: nothing to transcribe, model stays warm

        var released = FlowBarMachine()
        _ = released.handle(.fnDown(cold), now: 0)
        _ = released.handle(.timer(.hold), now: 0.25)
        #expect(released.handle(.fnUp, now: 0.9).isEmpty)   // released before the model is ready: remembered
        #expect(released.handle(.modelLoaded, now: 1.5) == [.finishCapture, .startTimer(.takingLonger, seconds: 8), .startTimer(.processingTimeout, seconds: 20)])
        #expect(released.state.isProcessing)

        var failed = FlowBarMachine()
        _ = failed.handle(.fnDown(cold), now: 0)
        #expect(failed.handle(.modelLoadFailed("bad file"), now: 1) == [.cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(failed.state == .error("Couldn't load the speech model"))
    }

    @Test("microphone failure while listening → mic unavailable; language detection updates the chip")
    func micFailureAndLanguage() {
        var m = FlowBarMachine.listening(.pushToTalk, at: 0)
        #expect(m.handle(.languageDetected(LanguageDetection(code: "de", confidence: 0.4)), now: 1).isEmpty)
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: LanguageDetection(code: "de", confidence: 0.4))))
        #expect(m.handle(.microphoneFailed(.engineFailed("stopped")), now: 2) ==
                [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .micUnavailable(.inUse(by: nil)))
    }

    @Test("idle hint follows the default mode")
    func hints() {
        #expect(FlowBarState.idle.hint(mode: .pushToTalk) == "Hold fn to dictate")
        #expect(FlowBarState.idle.hint(mode: .handsFree) == "Press fn to dictate")
        #expect(FlowBarState.listening(Listening(mode: .handsFree, startedAt: 0, language: nil)).hint(mode: .pushToTalk) == "fn — stop")
    }
}

extension FlowBarMachine {
    static func listening(_ mode: HotkeyMode, at start: TimeInterval) -> FlowBarMachine {
        var m = FlowBarMachine()
        m.state = .listening(Listening(mode: mode, startedAt: start, language: nil))
        return m
    }
    static func processing(at start: TimeInterval) -> FlowBarMachine {
        var m = FlowBarMachine()
        m.state = .processing(Processing(startedAt: start, takingLonger: false, limitReached: false, partialText: ""))
        return m
    }
}
```
- [ ] **Step 2: Run** `swift test --filter VoxFlowDictationTests` — compile failure.

- [ ] **Step 3: Implementation**

`Sources/VoxFlowDictation/FlowBarConfig.swift`:
```swift
import Foundation

public enum HotkeyMode: String, Sendable, Codable, CaseIterable, Equatable {
    case pushToTalk, handsFree
}

/// Timings from the design (3d "Hotkey timing", "Listening", "Processing", "Auto-dismiss").
public struct FlowBarConfig: Sendable, Equatable {
    public static let silenceStopRange: ClosedRange<TimeInterval> = 1...10

    public var holdThreshold: TimeInterval = 0.25
    public var doubleTapWindow: TimeInterval = 0.35
    public private(set) var silenceStop: TimeInterval = 3
    public var maxDuration: TimeInterval = 900
    public var takingLongerAfter: TimeInterval = 8
    public var processingTimeout: TimeInterval = 20
    public var dismissInserted: TimeInterval = 1.5
    public var dismissCopied: TimeInterval = 2.5
    public var dismissDiscarded: TimeInterval = 0.8
    public var dismissError: TimeInterval = 4
    /// RMS at or above this counts as voice for the hands-free silence timer.
    public var voiceRMS: Float = 0.01

    public init(silenceStop: TimeInterval = 3) {
        self.silenceStop = min(max(silenceStop, Self.silenceStopRange.lowerBound), Self.silenceStopRange.upperBound)
    }
}
```

`Sources/VoxFlowDictation/FlowBarMachine.swift`:
```swift
import Foundation
import VoxFlowCore

public enum MicrophoneAccess: Sendable, Equatable {
    case granted, denied, noDevice
    case inUse(by: String?)
}

public enum ModelReadiness: Sendable, Equatable {
    case loaded, installedNotLoaded
    case notInstalled(sizeBytes: Int64)
}

/// What the app knows at the moment fn goes down (phase 3b gathers it; tests build it directly).
public struct Preflight: Sendable, Equatable {
    public var excludedApp: String?
    public var secureInput: Bool
    public var microphone: MicrophoneAccess
    public var model: ModelReadiness
    public init(excludedApp: String?, secureInput: Bool, microphone: MicrophoneAccess, model: ModelReadiness) { … }
}

public enum FlowBarTimer: Sendable, Hashable { case hold, doubleTap, silence, cap, takingLonger, processingTimeout, dismiss }

public enum FlowBarEvent: Sendable, Equatable {
    case fnDown(Preflight), fnUp, escape, anyKey
    case level(rms: Float)
    case timer(FlowBarTimer)
    case modelLoaded, modelLoadFailed(String)
    case languageDetected(LanguageDetection)
    case partialText(String)
    case transcriptReady(text: String, lowConfidence: Bool)
    case transcriptionFailed(String)
    case microphoneFailed(MicrophoneError)
    case insertionFinished(InsertionResult)
    case copyRawRequested
}

public enum FlowBarEffect: Sendable, Equatable {
    case startCapture          // open the mic and start the windowed transcriber on its feed
    case finishCapture         // stop the mic, let the transcriber flush → `.transcriptReady`
    case abortCapture          // stop the mic and cancel the transcriber; no result
    case loadModel             // → `.modelLoaded` / `.modelLoadFailed`
    case startTimer(FlowBarTimer, seconds: TimeInterval)
    case cancelTimer(FlowBarTimer)
    case insert(String)        // → `.insertionFinished`
    case copyToClipboard(String)
    case saveHistory           // controller persists the last `DictationResult`
}

public struct Pending: Sendable, Equatable {
    public var downAt: TimeInterval
    public var fnIsDown: Bool
    public var resolvedMode: HotkeyMode?
    public init(downAt: TimeInterval, fnIsDown: Bool, resolvedMode: HotkeyMode?) { … }
}

public struct Listening: Sendable, Equatable {
    public var mode: HotkeyMode
    public var startedAt: TimeInterval
    public var language: LanguageDetection?
    public init(mode: HotkeyMode, startedAt: TimeInterval, language: LanguageDetection?) { … }
}

public struct Processing: Sendable, Equatable {
    public var startedAt: TimeInterval
    public var takingLonger: Bool
    public var limitReached: Bool
    public var partialText: String
    public init(startedAt: TimeInterval, takingLonger: Bool, limitReached: Bool, partialText: String) { … }
}

public enum FlowBarState: Sendable, Equatable {
    case idle
    case loadingModel(Pending)
    case armed(Pending)
    case tapped(Pending)
    case listening(Listening)
    case processing(Processing)
    case inserted(appName: String?, words: Int, limitReached: Bool)
    case copied
    case didntCatch(rawAvailable: Bool)
    case discarded
    case micUnavailable(MicrophoneAccess)
    case modelNotInstalled(sizeBytes: Int64)
    case excluded(app: String)
    case error(String)

    public var isProcessing: Bool { if case .processing = self { true } else { false } }

    /// States that auto-dismiss and treat fn-down as a retry.
    public var isDismissable: Bool {
        switch self {
        case .inserted, .copied, .didntCatch, .discarded, .micUnavailable, .modelNotInstalled, .excluded, .error: true
        default: false
        }
    }

    /// Hint text under the pill (FB-01 idle hint follows the default mode; FB-02b shows "fn — stop").
    public func hint(mode: HotkeyMode) -> String? {
        switch self {
        case .idle: mode == .pushToTalk ? "Hold fn to dictate" : "Press fn to dictate"
        case .listening(let l): l.mode == .handsFree ? "fn — stop" : nil
        default: nil
        }
    }
}

/// Pure reducer for the Flow Bar. `handle` returns the effects the driver must run, in order.
public struct FlowBarMachine: Sendable, Equatable {
    public var state: FlowBarState = .idle
    public var config: FlowBarConfig
    /// Text recognized so far in the current dictation (for FB-03 partials and "Copy raw transcript").
    public private(set) var partialText = ""
    private var lastTranscript = ""

    public init(config: FlowBarConfig = FlowBarConfig()) { self.config = config }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public mutating func handle(_ event: FlowBarEvent, now: TimeInterval) -> [FlowBarEffect] {
        switch (state, event) {
        // ── fn-down: from idle or any dismissable state ──
        case (.idle, .fnDown(let p)):
            return begin(p, now: now, cancelDismiss: false)
        case (let s, .fnDown(let p)) where s.isDismissable:
            return begin(p, now: now, cancelDismiss: true)
        case (let s, .anyKey) where s.isDismissable:
            state = .idle
            return [.cancelTimer(.dismiss)]
        case (let s, .timer(.dismiss)) where s.isDismissable:
            state = .idle
            return []

        // ── armed / loading: deciding between hold and tap ──
        case (.armed(var p), .timer(.hold)):
            p.resolvedMode = .pushToTalk
            state = .listening(Listening(mode: .pushToTalk, startedAt: p.downAt, language: nil))
            return [.startTimer(.cap, seconds: config.maxDuration)]
        case (.loadingModel(var p), .timer(.hold)):
            p.resolvedMode = .pushToTalk
            state = .loadingModel(p)
            return []
        case (.armed(var p), .fnUp), (.loadingModel(var p), .fnUp) where p.resolvedMode == nil:
            p.fnIsDown = false
            if case .loadingModel = state { state = .loadingModel(p) } else { state = .tapped(p) }
            return [.cancelTimer(.hold), .startTimer(.doubleTap, seconds: config.doubleTapWindow)]
        case (.loadingModel(var p), .fnUp):          // hold already resolved, released before the model is ready
            p.fnIsDown = false
            state = .loadingModel(p)
            return []
        case (.tapped(var p), .fnDown):
            p.fnIsDown = true
            p.resolvedMode = .handsFree
            state = .listening(Listening(mode: .handsFree, startedAt: p.downAt, language: nil))
            return [.cancelTimer(.doubleTap), .startTimer(.cap, seconds: config.maxDuration),
                    .startTimer(.silence, seconds: config.silenceStop)]
        case (.loadingModel(var p), .fnDown) where p.resolvedMode == nil && !p.fnIsDown:
            p.fnIsDown = true
            p.resolvedMode = .handsFree
            state = .loadingModel(p)
            return [.cancelTimer(.doubleTap)]
        case (.tapped, .timer(.doubleTap)):
            state = .idle
            return [.abortCapture]
        case (.loadingModel(let p), .timer(.doubleTap)) where p.resolvedMode == nil:
            state = .idle
            return [.abortCapture]
        case (.loadingModel(let p), .modelLoaded):
            switch p.resolvedMode {
            case .pushToTalk where p.fnIsDown:
                state = .listening(Listening(mode: .pushToTalk, startedAt: p.downAt, language: nil))
                return [.startTimer(.cap, seconds: config.maxDuration)]
            case .pushToTalk:                          // released while loading → straight to processing
                return startProcessing(now: now, limitReached: false, cancelling: [])
            case .handsFree:
                state = .listening(Listening(mode: .handsFree, startedAt: p.downAt, language: nil))
                return [.startTimer(.cap, seconds: config.maxDuration), .startTimer(.silence, seconds: config.silenceStop)]
            case nil:
                state = .armed(p)
                return []
            }
        case (.loadingModel, .modelLoadFailed):
            state = .error("Couldn't load the speech model")
            return [.cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]
        case (.armed, .fnDown), (.listening, .fnUp), (.loadingModel, .fnDown), (.tapped, .fnUp):
            return []

        // ── listening ──
        case (.listening(let l), .fnUp) where l.mode == .pushToTalk:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening(let l), .fnDown) where l.mode == .handsFree:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening(let l), .level(let rms)):
            guard l.mode == .handsFree, rms >= config.voiceRMS else { return [] }
            return [.startTimer(.silence, seconds: config.silenceStop)]
        case (.listening(let l), .timer(.silence)) where l.mode == .handsFree:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening, .timer(.cap)):
            return startProcessing(now: now, limitReached: true, cancelling: [.cap, .silence])
        case (.listening(var l), .languageDetected(let d)):
            l.language = d
            state = .listening(l)
            return []
        case (.listening, .escape):
            state = .discarded
            return [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: config.dismissDiscarded)]
        case (.listening, .microphoneFailed(let e)), (.armed, .microphoneFailed(let e)), (.loadingModel, .microphoneFailed(let e)), (.tapped, .microphoneFailed(let e)):
            state = .micUnavailable(Self.access(for: e))
            return [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]

        // ── partial text arrives while listening or processing ──
        case (.listening, .partialText(let t)):
            partialText = t
            return []
        case (.processing(var p), .partialText(let t)):
            partialText = t
            p.partialText = t
            state = .processing(p)
            return []

        // ── processing ──
        case (.processing(var p), .timer(.takingLonger)):
            p.takingLonger = true
            state = .processing(p)
            return []
        case (.processing, .timer(.processingTimeout)):
            state = .didntCatch(rawAvailable: !partialText.isEmpty)
            return [.abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]
        case (.processing, .transcriptReady(let text, let low)):
            lastTranscript = text
            let words = Self.wordCount(text)
            let cancel: [FlowBarEffect] = [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout)]
            if words == 0 || (words < 2 && low) {
                state = .didntCatch(rawAvailable: false)
                return cancel + [.startTimer(.dismiss, seconds: config.dismissError)]
            }
            return cancel + [.insert(text)]
        case (.processing(let p), .insertionFinished(let result)):
            switch result {
            case .inserted(let app):
                state = .inserted(appName: app, words: Self.wordCount(lastTranscript), limitReached: p.limitReached)
                return [.saveHistory, .startTimer(.dismiss, seconds: config.dismissInserted)]
            case .copiedToClipboard:
                state = .copied
                return [.saveHistory, .startTimer(.dismiss, seconds: config.dismissCopied)]
            }
        case (.processing, .transcriptionFailed):
            state = .error("Couldn't transcribe")
            return [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .startTimer(.dismiss, seconds: config.dismissError)]
        case (.processing, .escape):
            state = .discarded
            return [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .abortCapture, .startTimer(.dismiss, seconds: config.dismissDiscarded)]

        // ── FB-05 "Copy raw transcript" ──
        case (.didntCatch(rawAvailable: true), .copyRawRequested):
            return [.copyToClipboard(partialText)]

        default:
            return []
        }
    }

    private mutating func begin(_ p: Preflight, now: TimeInterval, cancelDismiss: Bool) -> [FlowBarEffect] {
        let prefix: [FlowBarEffect] = cancelDismiss ? [.cancelTimer(.dismiss)] : []
        partialText = ""
        lastTranscript = ""
        if let app = p.excludedApp { state = .excluded(app: app) }
        else if p.secureInput { state = .excluded(app: "a secure field") }
        else if p.microphone != .granted { state = .micUnavailable(p.microphone) }
        else if case .notInstalled(let bytes) = p.model { state = .modelNotInstalled(sizeBytes: bytes) }
        else {
            let pending = Pending(downAt: now, fnIsDown: true, resolvedMode: nil)
            if p.model == .loaded {
                state = .armed(pending)
                return prefix + [.startCapture, .startTimer(.hold, seconds: config.holdThreshold)]
            }
            state = .loadingModel(pending)
            return prefix + [.startCapture, .loadModel, .startTimer(.hold, seconds: config.holdThreshold)]
        }
        return prefix + [.startTimer(.dismiss, seconds: config.dismissError)]
    }

    private mutating func startProcessing(now: TimeInterval, limitReached: Bool, cancelling: [FlowBarTimer]) -> [FlowBarEffect] {
        state = .processing(Processing(startedAt: now, takingLonger: false, limitReached: limitReached, partialText: partialText))
        return cancelling.map { .cancelTimer($0) } + [.finishCapture,
                .startTimer(.takingLonger, seconds: config.takingLongerAfter),
                .startTimer(.processingTimeout, seconds: config.processingTimeout)]
    }

    private static func access(for error: MicrophoneError) -> MicrophoneAccess {
        switch error {
        case .accessDenied: .denied
        case .noInputDevice: .noDevice
        case .engineFailed: .inUse(by: nil)
        }
    }
}
```
Notes for the implementer: the `case (.armed(var p), .fnUp), (.loadingModel(var p), .fnUp) where …` multi-pattern binds `p` in both arms; if the compiler rejects the `where` on the combined pattern, split it into two cases with identical bodies. Every `[Effect]` order in the tests is binding — the controller runs effects in order and `cancelTimer` must precede `startTimer` of the same id.

- [ ] **Step 4: Run** `swift test --filter VoxFlowDictationTests` — PASS.

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit/Sources/VoxFlowDictation VoxFlowKit/Tests/VoxFlowDictationTests
git commit -m "feat(dictation): Flow Bar state machine with the design's timings"
```

---
### Task 3: `WindowPlanner` and `WindowedTranscriber` — text while you talk

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowDictation/DictationTranscribing.swift`
- Create: `VoxFlowKit/Sources/VoxFlowDictation/WindowPlanner.swift`
- Create: `VoxFlowKit/Sources/VoxFlowDictation/WindowedTranscriber.swift`
- Modify: `VoxFlowKit/Package.swift` — `VoxFlowSpeechTests` dependencies add `"VoxFlowDictation"` (for the RequiresModel test).
- Test: `VoxFlowKit/Tests/VoxFlowDictationTests/WindowPlannerTests.swift`, `WindowedTranscriberTests.swift`; `VoxFlowKit/Tests/VoxFlowSpeechTests/WindowedTranscriberIntegrationTests.swift`

**Interfaces:**
- Consumes: `SpeechEngine`, `TranscriptionOptions(promptContext:)`, `AudioChunk`, `AudioSamples`, `LanguageDetection`, `TranscriptSegment` (Core); `FakeSpeechEngine` (TestSupport).
- Produces: `DictationEvent`, `DictationResult`, `DictationError`, `DictationTranscribing`, `WindowPlanner`, `WindowedTranscriber`.

**Windowing rule (design 3e "Long dictation", spike numbers: turbo ≈ 16× realtime):** a window closes when ≥ `minWindow` (3 s) is buffered and the last `trailingSilence` (0.4 s) is below `voiceRMS`, or when `maxWindow` (10 s) is buffered regardless. When the feed ends, the remainder is flushed if it is ≥ `minFlush` (0.3 s). Each window is transcribed with `language` fixed to the first detection (auto mode) and `promptContext` = the last 200 characters of the text so far. Segment timestamps are shifted by the window's start offset.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowDictationTests/WindowPlannerTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowDictation

@Suite("WindowPlanner")
struct WindowPlannerTests {
    func chunk(seconds: Double, rms: Float) -> AudioChunk {
        AudioChunk(samples: Array(repeating: rms, count: Int(seconds * AudioSamples.sampleRate)))
    }

    @Test("closes a window after ≥ 3 s when the last 0.4 s are silent; reports its start offset")
    func silenceCut() {
        var planner = WindowPlanner()
        #expect(planner.append(chunk(seconds: 2.9, rms: 0.3)) == nil)
        #expect(planner.append(chunk(seconds: 0.3, rms: 0.0)) == nil)          // 3.2 s but only 0.3 s of silence
        let window = planner.append(chunk(seconds: 0.2, rms: 0.0))
        #expect(window?.startOffset == 0)
        #expect(window?.samples.duration == 3.4)
        #expect(planner.append(chunk(seconds: 3.0, rms: 0.3)) == nil)
        let second = planner.append(chunk(seconds: 0.5, rms: 0.0))
        #expect(second?.startOffset == 3.4)
    }

    @Test("closes at 10 s even without silence")
    func hardCut() {
        var planner = WindowPlanner()
        for _ in 0..<9 { #expect(planner.append(chunk(seconds: 1, rms: 0.3)) == nil) }
        let window = planner.append(chunk(seconds: 1.5, rms: 0.3))
        #expect(window?.samples.duration == 10.5)
    }

    @Test("flush returns the remainder when ≥ 0.3 s, nil otherwise")
    func flush() {
        var planner = WindowPlanner()
        _ = planner.append(chunk(seconds: 0.2, rms: 0.3))
        #expect(planner.flush() == nil)
        _ = planner.append(chunk(seconds: 0.2, rms: 0.3))
        let rest = planner.flush()
        #expect(rest?.samples.duration == 0.4)
        #expect(planner.flush() == nil)
    }

    @Test("prompt context is the last 200 characters of the text so far")
    func promptTail() {
        #expect(WindowedTranscriber.promptContext(from: "") == nil)
        let long = String(repeating: "abcdefghij", count: 30)
        #expect(WindowedTranscriber.promptContext(from: long)?.count == 200)
        #expect(WindowedTranscriber.promptContext(from: "short") == "short")
    }
}
```

`Tests/VoxFlowDictationTests/WindowedTranscriberTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("WindowedTranscriber")
struct WindowedTranscriberTests {
    func feed(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() }
    }
    func voiced(_ seconds: Double) -> AudioChunk { AudioChunk(samples: Array(repeating: 0.3, count: Int(seconds * 16_000))) }
    func silent(_ seconds: Double) -> AudioChunk { AudioChunk(samples: Array(repeating: 0, count: Int(seconds * 16_000))) }

    @Test("two windows: segments are offset, the second window gets the first text as prompt context, language detected once")
    func twoWindows() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "hello world", confidence: 0.9)!)],
                                      detection: LanguageDetection(code: "en", confidence: 0.95))
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let transcriber = WindowedTranscriber(engine: engine)
        let events = EventLog()
        let result = try await transcriber.transcribe(feed([voiced(3), silent(0.5), voiced(3), silent(0.5)]),
                                                      options: TranscriptionOptions(vocabulary: ["VoxFlow"])) { await events.append($0) }
        #expect(result.text == "hello world hello world")
        #expect(result.rawText == result.text)
        #expect(result.segments.map(\.start) == [0, 3.5])
        #expect(result.language == LanguageDetection(code: "en", confidence: 0.95))
        #expect(result.wordCount == 4)
        #expect(result.lowConfidence == false)
        #expect(abs(result.duration - 7.0) < 0.001)
        #expect(await engine.transcribeCalls == 2)
        #expect(await engine.lastOptions == TranscriptionOptions(language: "en", vocabulary: ["VoxFlow"], promptContext: "hello world"))
        #expect(await events.entries == [.language(LanguageDetection(code: "en", confidence: 0.95)),
                                         .partialText("hello world"), .partialText("hello world hello world")])
    }

    @Test("short feed below 0.3 s produces an empty result without calling the engine")
    func tooShort() async throws {
        let engine = FakeSpeechEngine(script: [])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let result = try await WindowedTranscriber(engine: engine).transcribe(feed([voiced(0.1)]), options: TranscriptionOptions()) { _ in }
        #expect(result.text.isEmpty && result.wordCount == 0)
        #expect(await engine.transcribeCalls == 0)
    }

    @Test("low confidence when the mean segment confidence is below 0.5")
    func lowConfidence() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "um", confidence: 0.2)!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let result = try await WindowedTranscriber(engine: engine).transcribe(feed([voiced(1)]), options: TranscriptionOptions(language: "en")) { _ in }
        #expect(result.lowConfidence)
    }

    @Test("cancelling the consumer mid-run throws DictationError.cancelled (ruling on #125)")
    func cancellation() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "one", confidence: 0.9)!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let started = Gate()
        let task = Task {
            try await WindowedTranscriber(engine: engine).transcribe(stream, options: TranscriptionOptions(language: "en")) { event in
                if case .partialText = event { await started.open() }
            }
        }
        continuation.yield(voiced(3)); continuation.yield(silent(0.5))   // first window completes → partial text
        await started.wait()
        task.cancel()
        continuation.finish()
        await #expect(throws: DictationError.cancelled) { _ = try await task.value }
    }

    @Test("engine failure surfaces as DictationError.engineFailed")
    func engineFailure() async throws {
        let engine = FakeSpeechEngine(script: [])   // never loaded → modelNotLoaded
        await #expect(throws: DictationError.engineFailed("modelNotLoaded")) {
            _ = try await WindowedTranscriber(engine: engine).transcribe(feed([voiced(1)]), options: TranscriptionOptions(language: "en")) { _ in }
        }
    }
}

actor EventLog {
    var entries: [DictationEvent] = []
    func append(_ e: DictationEvent) { entries.append(e) }
}

/// One-shot gate: `wait()` suspends until `open()` was called (returns at once afterwards).
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
```

`Tests/VoxFlowSpeechTests/WindowedTranscriberIntegrationTests.swift` (real engine, skipped without a model):
```swift
import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlowSpeech

@Suite("WindowedTranscriber over WhisperCppEngine (RequiresModel)", .enabled(if: InstalledModel.url != nil,
       "No Whisper model in ~/Library/Application Support/VoxFlow/Models"))
struct WindowedTranscriberIntegrationTests {
    @Test("attention-10s.wav in 100 ms chunks yields the same words as one batch")
    func windowsMatchBatch() async throws {
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try await AudioDecoder().decode(fixture)
        let chunks = stride(from: 0, to: audio.samples.count, by: 1600).map { AudioChunk(samples: Array(audio.samples[$0..<min($0 + 1600, audio.samples.count)])) }
        let result = try await WindowedTranscriber(engine: engine).transcribe(AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() },
                                                                             options: TranscriptionOptions(language: "en")) { _ in }
        #expect(result.wordCount >= 8)
        #expect(result.text.lowercased().contains("attention"))
    }
}
```
(Check the existing integration test for the exact `AudioDecoder` API name and the fixture lookup it already uses; mirror them.)

- [ ] **Step 2: Run** `swift test --filter 'WindowPlanner|WindowedTranscriber'` — compile failure.

- [ ] **Step 3: Implementation**

`Sources/VoxFlowDictation/DictationTranscribing.swift`:
```swift
import Foundation
import VoxFlowCore

public enum DictationEvent: Sendable, Equatable {
    case language(LanguageDetection)
    /// All text recognized so far (not a delta).
    case partialText(String)
}

public struct DictationResult: Sendable, Equatable {
    public var text: String
    /// Engine output before any cleanup. Identical to `text` until phase 5 adds styles.
    public var rawText: String
    public var segments: [TranscriptSegment]
    public var language: LanguageDetection?
    public var duration: TimeInterval
    public var lowConfidence: Bool

    public init(text: String, rawText: String, segments: [TranscriptSegment], language: LanguageDetection?, duration: TimeInterval, lowConfidence: Bool) { … }

    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    public static let empty = DictationResult(text: "", rawText: "", segments: [], language: nil, duration: 0, lowConfidence: false)
}

public enum DictationError: Error, Equatable, Sendable {
    case cancelled
    case engineFailed(String)
}

/// Turns a live chunk feed into text. Returns when the feed ends; throws `.cancelled` when the task is cancelled.
public protocol DictationTranscribing: Sendable {
    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult
}
```

`Sources/VoxFlowDictation/WindowPlanner.swift`:
```swift
import Foundation
import VoxFlowCore

/// Cuts a live feed into transcription windows. Pure; the transcriber owns one per dictation.
public struct WindowPlanner: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var samples: AudioSamples
        public var startOffset: TimeInterval
    }

    public var minWindow: TimeInterval = 3
    public var maxWindow: TimeInterval = 10
    public var trailingSilence: TimeInterval = 0.4
    public var minFlush: TimeInterval = 0.3
    public var voiceRMS: Float = 0.01

    private var buffer: [Float] = []
    /// Seconds of trailing audio below `voiceRMS`.
    private var silentTail: TimeInterval = 0
    private var consumed: TimeInterval = 0

    public init() {}

    public mutating func append(_ chunk: AudioChunk) -> Window? {
        buffer.append(contentsOf: chunk.samples)
        silentTail = chunk.rms < voiceRMS ? silentTail + chunk.duration : 0
        let buffered = Double(buffer.count) / AudioSamples.sampleRate
        if buffered >= maxWindow || (buffered >= minWindow && silentTail >= trailingSilence) {
            return cut()
        }
        return nil
    }

    public mutating func flush() -> Window? {
        Double(buffer.count) / AudioSamples.sampleRate >= minFlush ? cut() : { buffer.removeAll(); return nil }()
    }

    private mutating func cut() -> Window {
        let window = Window(samples: AudioSamples(buffer), startOffset: consumed)
        consumed += Double(buffer.count) / AudioSamples.sampleRate
        buffer.removeAll(keepingCapacity: true)
        silentTail = 0
        return window
    }
}
```
(Write `flush` as an ordinary `if` — the closure form above is shorthand for the plan, not a style to copy.)

`Sources/VoxFlowDictation/WindowedTranscriber.swift`:
```swift
import Foundation
import VoxFlowCore

/// Runs `SpeechEngine.transcribe` per window while the feed is still open, so text streams during speech.
public struct WindowedTranscriber: DictationTranscribing {
    public static let promptTailLength = 200
    private let engine: any SpeechEngine
    private let planner: WindowPlanner

    public init(engine: any SpeechEngine, planner: WindowPlanner = WindowPlanner()) {
        self.engine = engine
        self.planner = planner
    }

    public static func promptContext(from text: String) -> String? {
        text.isEmpty ? nil : String(text.suffix(promptTailLength))
    }

    public func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                           onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
        var planner = planner
        var segments: [TranscriptSegment] = []
        var language: LanguageDetection?
        var duration: TimeInterval = 0
        var text = ""

        func run(_ window: WindowPlanner.Window) async throws {
            var windowOptions = options
            if options.language == nil {
                if language == nil {
                    let detected = try await detect(window.samples)
                    language = detected
                    await onEvent(.language(detected))
                }
                windowOptions.language = language?.code
            }
            windowOptions.promptContext = Self.promptContext(from: text)
            for try await event in engine.transcribe(window.samples, options: windowOptions) {
                guard case .segment(let s) = event else { continue }
                let shifted = TranscriptSegment(start: s.start + window.startOffset, end: s.end + window.startOffset,
                                                text: s.text, confidence: s.confidence)!
                segments.append(shifted)
            }
            if Task.isCancelled { throw DictationError.cancelled }    // #125: the stream may end silently
            text = Self.join(segments)
            await onEvent(.partialText(text))
        }

        do {
            for await chunk in chunks {
                duration += chunk.duration
                if let window = planner.append(chunk) { try await run(window) }
            }
            if let rest = planner.flush() { try await run(rest) }
        } catch let error as DictationError {
            throw error
        } catch is CancellationError {
            throw DictationError.cancelled
        } catch {
            throw DictationError.engineFailed(String(describing: error))
        }
        if Task.isCancelled { throw DictationError.cancelled }

        let mean = segments.isEmpty ? 1.0 : segments.map(\.confidence).reduce(0, +) / Double(segments.count)
        return DictationResult(text: text, rawText: text, segments: segments, language: language,
                               duration: duration, lowConfidence: mean < 0.5)
    }

    private func detect(_ samples: AudioSamples) async throws -> LanguageDetection {
        try await engine.detectLanguage(in: samples)
    }

    static func join(_ segments: [TranscriptSegment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
```
`TranscriptSegment.confidence` — check the initializer in `Transcript.swift` for its type (Double); the failable init rejects `end < start`, which shifting preserves. Local `func run` capturing `inout`-like state: Swift 6 rejects mutation of captured vars from a nested async function only across isolation boundaries; since this is one non-isolated async context it compiles. If the compiler complains, hoist the state into a small non-Sendable `final class Accumulator` local to the call.

- [ ] **Step 4: Run** `swift test --filter 'WindowPlanner|WindowedTranscriber'` — PASS; `swift test --filter VoxFlowSpeechTests` — the RequiresModel test runs on the owner's Mac (model present) and is skipped on CI.

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit/Package.swift VoxFlowKit/Sources/VoxFlowDictation VoxFlowKit/Tests
git commit -m "feat(dictation): windowed transcription with prompt context and offsets"
```

---
### Task 4: `DictationController` — runs the machine's effects

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowDictation/DictationController.swift`
- Test: `VoxFlowKit/Tests/VoxFlowDictationTests/DictationControllerTests.swift` (+ `Fakes.swift` in the same folder for `FakeDictationTranscriber`)

**Interfaces:**
- Consumes: `FlowBarMachine`, `DictationTranscribing`, `MicrophoneCapturing`, `TextInserting`, `MonotonicClock`, `Preflight`.
- Produces: `DictationController` (actor) — `init(config:microphone:transcriber:inserter:clock:preflight:loadModel:options:onSave:copyToClipboard:)`, `states() -> AsyncStream<FlowBarState>`, `fnDown()`, `fnUp()`, `escape()`, `anyKey()`, `copyRaw()`, `state`, `lastResult`. Phase 3b feeds it from the hotkey monitor and renders `states()`.

**Effect execution (one method per effect, all on the actor):**
- `.startCapture` — `feed = AsyncStream<AudioChunk>.makeStream()`; `captureTask` iterates `microphone.start()`: `.chunk` → `feed.yield` + `handle(.level(rms:))`; `.deviceChanged` ignored in 3a; error → `handle(.microphoneFailed(error))`, other errors → `.engineFailed(description)`. `transcribeTask` runs `transcriber.transcribe(feed.stream, options: options(), onEvent:)` where `.language` → `handle(.languageDetected)`, `.partialText` → `handle(.partialText)`; on return → `lastResult = result; handle(.transcriptReady(text: result.text, lowConfidence: result.lowConfidence))`; on `DictationError.cancelled` → nothing; other errors → `handle(.transcriptionFailed(description))`.
- `.finishCapture` — cancel `captureTask`, `feed.finish()` (the transcriber flushes and returns).
- `.abortCapture` — cancel both tasks, `feed.finish()`, discard `lastResult`.
- `.loadModel` — `Task { do { try await loadModel(); handle(.modelLoaded) } catch { handle(.modelLoadFailed(description)) } }`.
- `.startTimer(id, seconds)` — cancel any existing timer with that id, then `timers[id] = Task { try await clock.sleep(for:); handle(.timer(id)) }` (a cancelled sleep never delivers). `.cancelTimer(id)` cancels and removes.
- `.insert(text)` — `Task { handle(.insertionFinished(await inserter.insert(text))) }`.
- `.copyToClipboard(text)` — call the injected closure.
- `.saveHistory` — `if let r = lastResult { await onSave(r, appName) }` where `appName` is the last `InsertionResult.inserted(appName:)`.

`handle(_:)` is `private func handle(_ event: FlowBarEvent)`: `let effects = machine.handle(event, now: clock.now())`, publish `machine.state` to every subscriber when it changed, then run effects in order. Re-entrancy: effects that produce events do so from their own tasks, never synchronously inside `handle`.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowDictationTests/Fakes.swift`:
```swift
import Foundation
import Synchronization
import VoxFlowCore
@testable import VoxFlowDictation

/// Collects the feed and returns a scripted result when it ends; `cancelledCount` proves aborts propagate.
final class FakeDictationTranscriber: DictationTranscribing, Sendable {
    private struct State { var result = DictationResult.empty; var events: [DictationEvent] = []; var calls = 0; var cancelled = 0; var received: [AudioChunk] = [] }
    private let state = Mutex(State())

    init(result: DictationResult, events: [DictationEvent] = []) { state.withLock { $0.result = result; $0.events = events } }

    var calls: Int { state.withLock { $0.calls } }
    var cancelledCount: Int { state.withLock { $0.cancelled } }
    var receivedSeconds: TimeInterval { state.withLock { $0.received.reduce(0) { $0 + $1.duration } } }

    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
        state.withLock { $0.calls += 1 }
        for event in state.withLock({ $0.events }) { await onEvent(event) }
        for await chunk in chunks { state.withLock { $0.received.append(chunk) } }
        if Task.isCancelled { state.withLock { $0.cancelled += 1 }; throw DictationError.cancelled }
        return state.withLock { $0.result }
    }
}
```

`Tests/VoxFlowDictationTests/DictationControllerTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("DictationController")
struct DictationControllerTests {
    struct Harness {
        let mic = FakeMicrophone()
        let inserter = FakeTextInserter()
        let clock = FakeClock()
        let saved = Mutex<[(DictationResult, String?)]>([])
        let clipboard = Mutex<[String]>([])
        let transcriber: FakeDictationTranscriber
        let controller: DictationController
        var states: AsyncStream<FlowBarState>.Iterator

        init(result: DictationResult = DictationResult(text: "hello there world", rawText: "hello there world", segments: [], language: nil, duration: 2, lowConfidence: false),
             preflight: Preflight = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded)) async {
            transcriber = FakeDictationTranscriber(result: result)
            let saved = saved, clipboard = clipboard
            controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: inserter, clock: clock,
                                             preflight: { preflight }, loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { r, app in saved.withLock { $0.append((r, app)) } },
                                             copyToClipboard: { t in clipboard.withLock { $0.append(t) } })
            states = await controller.states().makeAsyncIterator()
        }

        mutating func next() async -> FlowBarState? { await states.next() }
    }

    @Test("hold fn, speak, release: capture → processing → inserted → idle, history saved")
    func happyPath() async throws {
        var h = await Harness()
        await h.controller.fnDown()
        #expect(await h.next() == .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1)                 // hold timer
        await h.clock.advance(by: 0.25)
        #expect(await h.next() == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        h.mic.emit(rms: 0.3, seconds: 1)
        await h.controller.fnUp()
        guard case .processing = await h.next() else { Issue.record("expected processing"); return }
        await h.mic.waitUntilStopped()
        #expect(await h.next() == .inserted(appName: "Mail", words: 3, limitReached: false))
        #expect(h.inserter.insertedTexts == ["hello there world"])
        #expect(h.saved.withLock { $0.map(\.1) } == ["Mail"])
        #expect(h.transcriber.receivedSeconds == 1)
        await h.clock.waitForSleepers(1)                 // dismiss
        await h.clock.advance(by: 1.5)
        #expect(await h.next() == .idle)
    }

    @Test("a lone tap aborts capture without transcribing")
    func loneTap() async throws {
        var h = await Harness()
        await h.controller.fnDown()
        _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.controller.fnUp()
        #expect(await h.next() == .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)))
        await h.clock.waitForSleepers(1)                 // double-tap window
        await h.clock.advance(by: 0.35)
        #expect(await h.next() == .idle)
        await h.mic.waitUntilStopped()
        #expect(h.transcriber.cancelledCount == 1)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.saved.withLock { $0.isEmpty })
    }

    @Test("hands-free: double tap, silence stops, clipboard fallback → copied")
    func handsFreeClipboard() async throws {
        var h = await Harness()
        h.inserter.setResult(.copiedToClipboard)
        await h.controller.fnDown(); _ = await h.next()
        await h.controller.fnUp(); _ = await h.next()
        await h.controller.fnDown()
        #expect(await h.next() == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        await h.clock.waitForSleepers(2)                 // cap + silence
        await h.clock.advance(by: 3)
        guard case .processing = await h.next() else { Issue.record("expected processing"); return }
        #expect(await h.next() == .copied)
        #expect(h.saved.withLock { $0.count } == 1)
    }

    @Test("esc while listening discards: transcriber cancelled, nothing inserted")
    func escape() async throws {
        var h = await Harness()
        await h.controller.fnDown(); _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1); await h.clock.advance(by: 0.25)
        _ = await h.next()
        await h.controller.escape()
        #expect(await h.next() == .discarded)
        await h.mic.waitUntilStopped()
        #expect(h.transcriber.cancelledCount == 1)
        #expect(h.inserter.insertedTexts.isEmpty)
    }

    @Test("preflight failure never opens the microphone")
    func gated() async throws {
        var h = await Harness(preflight: Preflight(excludedApp: "1Password", secureInput: false, microphone: .granted, model: .loaded))
        await h.controller.fnDown()
        #expect(await h.next() == .excluded(app: "1Password"))
        #expect(h.mic.startCount == 0)
        await h.controller.anyKey()
        #expect(await h.next() == .idle)
    }

    @Test("microphone failure mid-listening → FB-07 and capture torn down")
    func micFailure() async throws {
        var h = await Harness()
        await h.controller.fnDown(); _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1); await h.clock.advance(by: 0.25)
        _ = await h.next()
        h.mic.fail(.noInputDevice)
        #expect(await h.next() == .micUnavailable(.noDevice))
        #expect(h.transcriber.cancelledCount == 1)
    }

    @Test("20 s without a result → didn't catch with raw text; copy raw uses the partial")
    func timeout() async throws {
        let slow = FakeDictationTranscriber(result: .empty, events: [.partialText("so far")])
        let mic = FakeMicrophone(), clock = FakeClock(), clipboard = Mutex<[String]>([])
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: slow, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in },
                                             copyToClipboard: { t in clipboard.withLock { $0.append(t) } })
        var states = await controller.states().makeAsyncIterator()
        await controller.fnDown(); _ = await states.next()
        await mic.waitUntilCapturing()
        await clock.waitForSleepers(1); await clock.advance(by: 0.25)
        _ = await states.next()
        // Never finish the feed from the fake's side: `fnUp` finishes it, but the fake keeps the result until the stream ends —
        // so hold the stream open by making the transcriber wait: emit nothing and let the 20 s timer fire first.
        await controller.fnUp()
        _ = await states.next()                            // processing
        await clock.waitForSleepers(2)                     // takingLonger + processingTimeout
        await clock.advance(by: 20)
        var state = await states.next()
        if case .processing = state { state = await states.next() }   // takingLonger flips first at 8 s
        #expect(state == .didntCatch(rawAvailable: true))
        await controller.copyRaw()
        #expect(clipboard.withLock { $0 } == ["so far"])
    }
}
```
Implementer note for `timeout`: `FakeDictationTranscriber` returns as soon as the feed ends, which `fnUp` triggers. To keep processing open until the 20 s timer, give the fake an optional `hold: Gate` that `transcribe` awaits after the feed ends and before returning; the test never opens it. Add that field to `Fakes.swift` and use it here — the plan's contract is "the timer fires before the result".

- [ ] **Step 2: Run** `swift test --filter DictationController` — compile failure.

- [ ] **Step 3: Implementation** — `Sources/VoxFlowDictation/DictationController.swift`:
```swift
import Foundation
import VoxFlowCore

/// Drives `FlowBarMachine`: owns the mic/transcriber/timer tasks and publishes states for the HUD.
public actor DictationController {
    public typealias SaveHandler = @Sendable (DictationResult, String?) async -> Void

    private var machine: FlowBarMachine
    private let microphone: any MicrophoneCapturing
    private let transcriber: any DictationTranscribing
    private let inserter: any TextInserting
    private let clock: any MonotonicClock
    private let preflight: @Sendable () async -> Preflight
    private let loadModel: @Sendable () async throws -> Void
    private let options: @Sendable () -> TranscriptionOptions
    private let onSave: SaveHandler
    private let copyToClipboard: @Sendable (String) -> Void

    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var captureTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var timers: [FlowBarTimer: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<FlowBarState>.Continuation] = [:]
    public private(set) var lastResult: DictationResult?
    private var lastAppName: String?

    public init(config: FlowBarConfig, microphone: any MicrophoneCapturing, transcriber: any DictationTranscribing,
                inserter: any TextInserting, clock: any MonotonicClock,
                preflight: @escaping @Sendable () async -> Preflight,
                loadModel: @escaping @Sendable () async throws -> Void,
                options: @escaping @Sendable () -> TranscriptionOptions,
                onSave: @escaping SaveHandler,
                copyToClipboard: @escaping @Sendable (String) -> Void) { … machine = FlowBarMachine(config: config) … }

    public var state: FlowBarState { machine.state }

    /// Every subscriber gets each state change after subscribing (not the current state).
    public func states() -> AsyncStream<FlowBarState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FlowBarState>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    public func fnDown() async { handle(.fnDown(await preflight())) }
    public func fnUp() { handle(.fnUp) }
    public func escape() { handle(.escape) }
    public func anyKey() { handle(.anyKey) }
    public func copyRaw() { handle(.copyRawRequested) }

    private func handle(_ event: FlowBarEvent) {
        let before = machine.state
        let effects = machine.handle(event, now: clock.now())
        if machine.state != before { for c in subscribers.values { c.yield(machine.state) } }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: FlowBarEffect) {
        switch effect {
        case .startCapture: startCapture()
        case .finishCapture: captureTask?.cancel(); captureTask = nil; feed?.finish(); feed = nil
        case .abortCapture: teardown(); lastResult = nil
        case .loadModel:
            Task { [loadModel] in
                do { try await loadModel(); await self.handle(.modelLoaded) }
                catch { await self.handle(.modelLoadFailed(String(describing: error))) }
            }
        case .startTimer(let id, let seconds):
            timers[id]?.cancel()
            timers[id] = Task { [clock] in
                do { try await clock.sleep(for: seconds) } catch { return }
                await self.timerFired(id)
            }
        case .cancelTimer(let id): timers[id]?.cancel(); timers[id] = nil
        case .insert(let text):
            Task { [inserter] in await self.handle(.insertionFinished(await inserter.insert(text))) }
        case .copyToClipboard(let text): copyToClipboard(text)
        case .saveHistory:
            if let result = lastResult { Task { [onSave, lastAppName] in await onSave(result, lastAppName) } }
        }
    }

    private func timerFired(_ id: FlowBarTimer) {
        guard timers[id] != nil else { return }      // cancelled between wake-up and delivery
        timers[id] = nil
        handle(.timer(id))
    }

    private func startCapture() {
        teardown()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        feed = continuation
        captureTask = Task { [microphone] in
            do {
                for try await event in microphone.start() {
                    guard !Task.isCancelled else { break }
                    if case .chunk(let chunk) = event { await self.receive(chunk) }
                }
            } catch let error as MicrophoneError {
                await self.handle(.microphoneFailed(error))
            } catch {
                await self.handle(.microphoneFailed(.engineFailed(String(describing: error))))
            }
        }
        transcribeTask = Task { [transcriber, options] in
            do {
                let result = try await transcriber.transcribe(stream, options: options()) { event in await self.receive(event) }
                await self.finished(result)
            } catch DictationError.cancelled {
            } catch {
                await self.handle(.transcriptionFailed(String(describing: error)))
            }
        }
    }

    private func receive(_ chunk: AudioChunk) { feed?.yield(chunk); handle(.level(rms: chunk.rms)) }
    private func receive(_ event: DictationEvent) {
        switch event {
        case .language(let d): handle(.languageDetected(d))
        case .partialText(let t): handle(.partialText(t))
        }
    }
    private func finished(_ result: DictationResult) {
        lastResult = result
        handle(.transcriptReady(text: result.text, lowConfidence: result.lowConfidence))
    }

    private func teardown() {
        captureTask?.cancel(); captureTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        feed?.finish(); feed = nil
    }
}
```
Record `lastAppName` inside `.insert` handling: `case .inserted(let app) = result` → `lastAppName = app` before `handle(.insertionFinished)`. The `insertionFinished` arrives on the actor via the `Task` in `.insert`. Note `handle` is synchronous on the actor; every effect that needs to wait spawns a task that hops back with `await self.handle`.

- [ ] **Step 4: Run** `swift test --filter VoxFlowDictationTests` — PASS. Run it three times in a row (`for i in 1 2 3; do swift test --filter DictationController || break; done`) to catch ordering flakiness before review.

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit/Sources/VoxFlowDictation VoxFlowKit/Tests/VoxFlowDictationTests
git commit -m "feat(dictation): controller that runs the Flow Bar machine's effects"
```

---
### Task 5: `MicrophoneSource` in `VoxFlowAudio`

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowAudio/AudioChunker.swift`
- Create: `VoxFlowKit/Sources/VoxFlowAudio/MicrophoneSource.swift`
- Test: `VoxFlowKit/Tests/VoxFlowAudioTests/AudioChunkerTests.swift`, `VoxFlowKit/Tests/VoxFlowAudioTests/MicrophoneSourceIntegrationTests.swift`

**Interfaces:**
- Consumes: `AudioChunk`, `MicrophoneEvent`, `MicrophoneError`, `MicrophoneCapturing` (Core).
- Produces: `AudioChunker` (pure re-chunker), `MicrophoneSource: MicrophoneCapturing` with `init(chunkSeconds: Double = 0.1)`.

**Design:** `AVAudioEngine.inputNode` tap (buffer 4096 frames at the device format) → `AVAudioConverter` to 16 kHz mono Float32 inside the tap → `AudioChunker` splits the converted samples into fixed `chunkSeconds` chunks → `continuation.yield(.chunk)`. The tap block's captured state (`converter`, `chunker`) lives in a `final class TapState: @unchecked Sendable` that only the audio thread touches after `installTap` — the one allowed exception, commented like `ContextBox`. `AVAudioEngineConfigurationChange` (device switch) restarts the engine and yields `.deviceChanged(name: engine.inputNode.…)`; if the new input format has 0 channels the stream fails with `.noInputDevice`. `engine.start()` throwing → `.engineFailed(error.localizedDescription)`. `onTermination` stops the engine and removes the tap on a private serial queue. Microphone permission is *not* checked here (preflight in 3b); a denied permission produces silent buffers, which the design handles as FB-07 before capture starts.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowAudioTests/AudioChunkerTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("AudioChunker")
struct AudioChunkerTests {
    @Test("emits fixed-size chunks, carries the remainder, flushes the tail")
    func chunks() {
        var chunker = AudioChunker(chunkSamples: 4)
        #expect(chunker.append([1, 1, 1]).isEmpty)
        let out = chunker.append([1, 0, 0, 0, 0, 0.5])
        #expect(out.map(\.samples) == [[1, 1, 1, 1], [0, 0, 0, 0]])
        #expect(chunker.flush()?.samples == [0.5])
        #expect(chunker.flush() == nil)
    }

    @Test("chunk length for 100 ms at 16 kHz is 1600 samples")
    func sizing() {
        #expect(AudioChunker(seconds: 0.1).chunkSamples == 1600)
    }
}
```

`Tests/VoxFlowAudioTests/MicrophoneSourceIntegrationTests.swift` (needs a real input device and granted permission; opt-in):
```swift
import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("MicrophoneSource (RequiresMicrophone)",
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_MIC_TESTS"] == "1", "Set VOXFLOW_MIC_TESTS=1 to capture from the default input"))
struct MicrophoneSourceIntegrationTests {
    @Test("delivers 100 ms chunks at 16 kHz and stops when the consumer cancels")
    func captures() async throws {
        let source = MicrophoneSource()
        var received: [AudioChunk] = []
        let task = Task {
            var chunks: [AudioChunk] = []
            for try await event in source.start() {
                if case .chunk(let c) = event { chunks.append(c) }
                if chunks.count == 5 { break }
            }
            return chunks
        }
        received = try await task.value
        #expect(received.count == 5)
        #expect(received.allSatisfy { $0.samples.count == 1600 })
    }
}
```

- [ ] **Step 2: Run** `swift test --filter AudioChunker` — compile failure.

- [ ] **Step 3: Implementation**

`Sources/VoxFlowAudio/AudioChunker.swift`:
```swift
import Foundation
import VoxFlowCore

/// Re-slices a stream of 16 kHz samples into equal chunks (the last one via `flush`).
public struct AudioChunker: Sendable, Equatable {
    public let chunkSamples: Int
    private var pending: [Float] = []

    public init(chunkSamples: Int) { self.chunkSamples = max(1, chunkSamples) }
    public init(seconds: Double) { self.init(chunkSamples: Int(seconds * AudioSamples.sampleRate)) }

    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        var out: [AudioChunk] = []
        while pending.count >= chunkSamples {
            out.append(AudioChunk(samples: Array(pending.prefix(chunkSamples))))
            pending.removeFirst(chunkSamples)
        }
        return out
    }

    public mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return AudioChunk(samples: pending)
    }
}
```

`Sources/VoxFlowAudio/MicrophoneSource.swift`:
```swift
@preconcurrency import AVFoundation
import Foundation
import VoxFlowCore

/// `AVAudioEngine` input tap → 16 kHz mono chunks with RMS (design §4 `MicrophoneSource`, ST-04n, FB-07).
public final class MicrophoneSource: MicrophoneCapturing, Sendable {
    private let chunkSeconds: Double

    public init(chunkSeconds: Double = 0.1) { self.chunkSeconds = chunkSeconds }

    public func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = CaptureSession(chunkSeconds: chunkSeconds, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

/// Everything AVFoundation-side for one capture. All members are touched only on `queue` (setup, restart, stop)
/// or inside the tap block, which AVAudioEngine serialises on its own render thread — the same confinement
/// argument as `ContextBox` in `WhisperCppEngine`; hence the one permitted `@unchecked Sendable`.
private final class CaptureSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.microphone")
    private let engine = AVAudioEngine()
    private let chunkSeconds: Double
    private let continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(chunkSeconds: Double, continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation) { … }

    func start() {
        queue.async { [self] in
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.queue.async { self?.restart() }
            }
            do { try installTapAndRun() } catch { fail(error) }
        }
    }

    private func installTapAndRun() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw MicrophoneError.noInputDevice }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { throw MicrophoneError.engineFailed("no converter \(inputFormat) → 16 kHz mono") }
        var chunker = AudioChunker(seconds: chunkSeconds)
        let continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            for chunk in chunker.append(samples) { continuation.yield(.chunk(chunk)) }
        }
        engine.prepare()
        do { try engine.start() } catch { throw MicrophoneError.engineFailed(error.localizedDescription) }
    }

    private func restart() {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { fail(MicrophoneError.noInputDevice); return }
        continuation.yield(.deviceChanged(name: AVCaptureDevice.default(for: .audio)?.localizedName))
        do { try installTapAndRun() } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        stopInternal()
        continuation.finish(throwing: (error as? MicrophoneError) ?? MicrophoneError.engineFailed(String(describing: error)))
    }

    func stop() { queue.async { [self] in stopInternal() } }

    private func stopInternal() {
        guard !stopped else { return }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
```
`AudioChunker` is a struct mutated inside the tap: the tap block is non-escaping into a `@Sendable` context on the SDK's terms; if the compiler rejects capturing `var chunker` there, move it into `CaptureSession` as a stored property (the same confinement argument covers it). The `AVAudioConverter` input block is called once per `convert` because `capacity` covers the whole buffer — the `consumed` flag guarantees no double-feed.

- [ ] **Step 4: Run** `swift test --filter VoxFlowAudioTests` — PASS (integration suite skipped). On the owner's Mac, `VOXFLOW_MIC_TESTS=1 swift test --filter MicrophoneSource` should also pass once Terminal has microphone access; record the outcome in the task report.

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit/Sources/VoxFlowAudio VoxFlowKit/Tests/VoxFlowAudioTests
git commit -m "feat(audio): MicrophoneSource with 16 kHz chunks, RMS and device-change handling"
```

---

### Task 6: `VoxFlowStorage` — encrypted dictation history on GRDB with retention

**Files:**
- Modify: `VoxFlowKit/Package.swift` — `dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")]`; `VoxFlowStorage` target dependencies `["VoxFlowCore", .product(name: "GRDB", package: "GRDB.swift")]`. Commit `VoxFlowKit/Package.resolved`.
- Delete: `VoxFlowKit/Sources/VoxFlowStorage/StorageModule.swift`, `VoxFlowKit/Tests/VoxFlowStorageTests/StorageModuleTests.swift`
- Create: `VoxFlowKit/Sources/VoxFlowStorage/DictationRecord.swift`, `DictationCipher.swift`, `HistoryKeyProviders.swift`, `DictationStore.swift`, `RetentionPolicy.swift`, `RetentionRunner.swift`
- Test: `VoxFlowKit/Tests/VoxFlowStorageTests/DictationCipherTests.swift`, `DictationStoreTests.swift`, `RetentionTests.swift`, `HistoryKeyProvidersTests.swift`

**Interfaces:**
- Consumes: `KeyValueStore`, `MonotonicClock` (Core) — no: retention uses wall-clock `Date`, injected as `now: @Sendable () -> Date`, and `MonotonicClock.sleep` for the daily cadence.
- Produces: `DictationRecord`, `DictationDraft`, `DictationCipher`, `HistoryKeyProviding`, `KeychainKeyProvider`, `SecureEnclaveKeyProvider`, `HistoryKeyProviders.default()`, `DictationStore`, `RetentionPolicy`, `RetentionRunner`.

**Schema (migration `v1`):**
```sql
CREATE TABLE dictations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at DOUBLE NOT NULL,          -- unix seconds
  app_name TEXT,
  style TEXT,                          -- nil until phase 5
  language TEXT,
  duration DOUBLE NOT NULL,
  words INTEGER NOT NULL,
  encrypted BOOLEAN NOT NULL,
  text BLOB NOT NULL,                  -- UTF-8 or AES-GCM combined box
  raw_text BLOB NOT NULL
);
CREATE INDEX dictations_created_at ON dictations(created_at);
```
`encrypted` per row lets the Privacy toggle flip without migrating; rows keep whichever mode they were written in and are read back accordingly.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowStorageTests/DictationCipherTests.swift`:
```swift
import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

@Suite("DictationCipher")
struct DictationCipherTests {
    @Test("seal/open round-trips unicode; different nonces per call; wrong key fails")
    func roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = DictationCipher(key: key)
        let a = try cipher.seal("Привет, VoxFlow 👋")
        let b = try cipher.seal("Привет, VoxFlow 👋")
        #expect(a != b)
        #expect(try cipher.open(a) == "Привет, VoxFlow 👋")
        #expect(throws: (any Error).self) { try DictationCipher(key: SymmetricKey(size: .bits256)).open(a) }
    }
}
```

`Tests/VoxFlowStorageTests/DictationStoreTests.swift`:
```swift
import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

struct FakeKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> SymmetricKey { key }
}

@Suite("DictationStore")
struct DictationStoreTests {
    func draft(_ text: String, at date: Date, app: String? = "Mail") -> DictationDraft {
        DictationDraft(text: text, rawText: text + " raw", appName: app, style: nil, language: "en", duration: 2.5, createdAt: date)
    }

    @Test("insert then fetch newest first; word count derived from text")
    func insertFetch() throws {
        let store = try DictationStore(inMemoryWith: nil)
        let older = try store.insert(draft("first one", at: Date(timeIntervalSince1970: 100)))
        let newer = try store.insert(draft("second one here", at: Date(timeIntervalSince1970: 200)))
        let all = try store.fetch(limit: 10)
        #expect(all.map(\.id) == [newer.id, older.id])
        #expect(all.first?.words == 3)
        #expect(all.first?.rawText == "second one here raw")
        #expect(try store.count() == 2)
    }

    @Test("encrypted rows are unreadable in SQL and transparent through the store")
    func encryption() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        _ = try store.insert(draft("secret words", at: Date()))
        let raw = try store.rawTextColumnForTesting(id: 1)
        #expect(raw != Data("secret words".utf8))
        #expect(try store.fetch(limit: 1).first?.text == "secret words")
    }

    @Test("search matches text or raw transcript, case-insensitive, after decryption")
    func search() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        _ = try store.insert(draft("Quarterly numbers look fine", at: Date(timeIntervalSince1970: 1)))
        _ = try store.insert(DictationDraft(text: "clean", rawText: "um clean NUMBERS", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 2)))
        _ = try store.insert(draft("unrelated", at: Date(timeIntervalSince1970: 3)))
        #expect(try store.search("numbers").map(\.text) == ["clean", "Quarterly numbers look fine"])
        #expect(try store.search("  ").count == 3)
    }

    @Test("delete one, delete all, delete older than a cutoff")
    func deletes() throws {
        let store = try DictationStore(inMemoryWith: nil)
        let a = try store.insert(draft("a", at: Date(timeIntervalSince1970: 10)))
        _ = try store.insert(draft("b", at: Date(timeIntervalSince1970: 20)))
        _ = try store.insert(draft("c", at: Date(timeIntervalSince1970: 30)))
        try store.delete(id: a.id)
        #expect(try store.count() == 2)
        #expect(try store.deleteOlderThan(Date(timeIntervalSince1970: 25)) == 1)
        #expect(try store.fetch(limit: 10).map(\.text) == ["c"])
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test("a file-backed store persists across instances")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")
        _ = try DictationStore(databaseURL: url, keyProvider: nil).insert(draft("kept", at: Date()))
        #expect(try DictationStore(databaseURL: url, keyProvider: nil).fetch(limit: 1).first?.text == "kept")
    }
}
```

`Tests/VoxFlowStorageTests/RetentionTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowStorage

@Suite("Retention")
struct RetentionTests {
    @Test("policy cutoff is now minus days; 0 days means keep forever")
    func policy() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        #expect(RetentionPolicy(days: 30).cutoff(now: now) == Date(timeIntervalSince1970: 70 * 86_400))
        #expect(RetentionPolicy(days: 0).cutoff(now: now) == nil)
        #expect(RetentionPolicy.default.days == 30)
        #expect(RetentionPolicy.choices == [7, 30, 90, 365, 0])
    }

    @Test("runner purges at start and again every 24 h using the injected clocks")
    func runner() async throws {
        let store = try DictationStore(inMemoryWith: nil)
        let wall = Mutex(Date(timeIntervalSince1970: 40 * 86_400))
        _ = try store.insert(DictationDraft(text: "old", rawText: "old", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 5 * 86_400)))
        _ = try store.insert(DictationDraft(text: "fresh", rawText: "fresh", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 39 * 86_400)))
        let clock = FakeClock()
        let runner = RetentionRunner(store: store, policy: { RetentionPolicy(days: 30) }, now: { wall.withLock { $0 } }, clock: clock)
        await runner.start()
        await runner.waitForPass(1)
        #expect(try store.fetch(limit: 10).map(\.text) == ["fresh"])
        wall.withLock { $0 = Date(timeIntervalSince1970: 70 * 86_400) }
        await clock.waitForSleepers(1)
        await clock.advance(by: 86_400)
        await runner.waitForPass(2)
        #expect(try store.count() == 0)
        await runner.stop()
    }
}
```

`Tests/VoxFlowStorageTests/HistoryKeyProvidersTests.swift`:
```swift
import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

@Suite("HistoryKeyProviders")
struct HistoryKeyProvidersTests {
    @Test("default picks the Secure Enclave when available, else the Keychain")
    func selection() {
        #expect(HistoryKeyProviders.select(secureEnclaveAvailable: true) == .secureEnclave)
        #expect(HistoryKeyProviders.select(secureEnclaveAvailable: false) == .keychain)
    }

    @Test("Keychain provider returns a stable key across calls (RequiresKeychain)",
          .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_KEYCHAIN_TESTS"] == "1"))
    func keychain() throws {
        let provider = KeychainKeyProvider(service: "dev.artemsem.voxflow.tests", account: UUID().uuidString)
        defer { try? provider.deleteForTesting() }
        let a = try provider.historyKey(), b = try provider.historyKey()
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter VoxFlowStorageTests` — compile failure (after `swift package resolve` fetches GRDB).

- [ ] **Step 3: Implementation**

`Sources/VoxFlowStorage/DictationRecord.swift`:
```swift
import Foundation

/// What the Flow Bar hands to storage after an insertion (design MW-02 row fields; audio is never stored).
public struct DictationDraft: Sendable, Equatable {
    public var text: String
    public var rawText: String
    public var appName: String?
    public var style: String?
    public var language: String?
    public var duration: TimeInterval
    public var createdAt: Date
    public init(text: String, rawText: String, appName: String?, style: String?, language: String?, duration: TimeInterval, createdAt: Date) { … }
}

public struct DictationRecord: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var text: String
    public var rawText: String
    public var appName: String?
    public var style: String?
    public var language: String?
    public var duration: TimeInterval
    public var words: Int
    public var createdAt: Date

    public static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}
```

`Sources/VoxFlowStorage/DictationCipher.swift`:
```swift
import CryptoKit
import Foundation

/// AES-GCM per value; the combined box (nonce + ciphertext + tag) is what lands in SQLite.
public struct DictationCipher: Sendable {
    private let key: SymmetricKey
    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ text: String) throws -> Data {
        try AES.GCM.seal(Data(text.utf8), using: key).combined!
    }

    public func open(_ data: Data) throws -> String {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw StorageError.corruptRow }
        return text
    }
}

public enum StorageError: Error, Equatable, Sendable {
    case corruptRow
    case keychain(OSStatus)
    case secureEnclaveUnavailable
}
```

`Sources/VoxFlowStorage/HistoryKeyProviders.swift`:
```swift
import CryptoKit
import Foundation
import Security

/// Hands out the symmetric key that encrypts history rows (design ST-05 "Key stored in the Secure Enclave").
public protocol HistoryKeyProviding: Sendable {
    func historyKey() throws -> SymmetricKey
}

public enum HistoryKeyProviders {
    public enum Choice: Equatable { case secureEnclave, keychain }

    public static func select(secureEnclaveAvailable: Bool) -> Choice { secureEnclaveAvailable ? .secureEnclave : .keychain }

    /// Secure Enclave when the hardware and signature allow it (not on CI VMs), else a Keychain-held random key.
    public static func `default`(service: String = "dev.artemsem.voxflow", account: String = "history-key") -> any HistoryKeyProviding {
        switch select(secureEnclaveAvailable: SecureEnclave.isAvailable) {
        case .secureEnclave: SecureEnclaveKeyProvider(service: service, account: account)
        case .keychain: KeychainKeyProvider(service: service, account: account)
        }
    }
}

/// A random 256-bit key stored as a generic password (`ThisDeviceOnly`, after first unlock).
public struct KeychainKeyProvider: HistoryKeyProviding {
    let service: String, account: String
    public init(service: String, account: String) { … }

    public func historyKey() throws -> SymmetricKey {
        if let data = try KeychainItem.read(service: service, account: account) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try KeychainItem.write(key.withUnsafeBytes { Data($0) }, service: service, account: account)
        return key
    }

    func deleteForTesting() throws { try KeychainItem.delete(service: service, account: account) }
}

/// ECIES-style wrap: a P-256 key agreement key that never leaves the Secure Enclave, combined with a stored
/// public "salt" key, derives the AES key through HKDF. Both halves persist in the Keychain; the SE key is
/// only a handle (`dataRepresentation`), so the AES key cannot be reconstructed on another machine.
public struct SecureEnclaveKeyProvider: HistoryKeyProviding {
    let service: String, account: String
    public init(service: String, account: String) { … }

    public func historyKey() throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { throw StorageError.secureEnclaveUnavailable }
        let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        let saltPublic: P256.KeyAgreement.PublicKey
        if let handle = try KeychainItem.read(service: service, account: account + ".se"),
           let salt = try KeychainItem.read(service: service, account: account + ".salt") {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle)
            saltPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: salt)
        } else {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            saltPublic = P256.KeyAgreement.PrivateKey().publicKey      // private half discarded on purpose
            try KeychainItem.write(privateKey.dataRepresentation, service: service, account: account + ".se")
            try KeychainItem.write(saltPublic.rawRepresentation, service: service, account: account + ".salt")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: saltPublic)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("VoxFlow history".utf8), sharedInfo: Data(), outputByteCount: 32)
    }
}

enum KeychainItem {
    static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        return item as? Data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain(status) }
    }
}
```

`Sources/VoxFlowStorage/DictationStore.swift`:
```swift
import Foundation
import GRDB

/// History on SQLite (design §5). `keyProvider == nil` stores plaintext (Privacy toggle off).
public final class DictationStore: Sendable {
    private let queue: DatabaseQueue
    private let cipher: DictationCipher?

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxFlow/voxflow.sqlite")
    }

    public convenience init(databaseURL: URL, keyProvider: (any HistoryKeyProviding)?) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(queue: DatabaseQueue(path: databaseURL.path), keyProvider: keyProvider)
    }

    public convenience init(inMemoryWith keyProvider: (any HistoryKeyProviding)?) throws {
        try self.init(queue: DatabaseQueue(), keyProvider: keyProvider)
    }

    private init(queue: DatabaseQueue, keyProvider: (any HistoryKeyProviding)?) throws {
        self.queue = queue
        cipher = try keyProvider.map { DictationCipher(key: try $0.historyKey()) }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at DOUBLE NOT NULL, app_name TEXT, style TEXT, language TEXT,
                  duration DOUBLE NOT NULL, words INTEGER NOT NULL, encrypted BOOLEAN NOT NULL, text BLOB NOT NULL, raw_text BLOB NOT NULL);
                CREATE INDEX dictations_created_at ON dictations(created_at);
                """)
        }
        try migrator.migrate(queue)
    }

    @discardableResult
    public func insert(_ draft: DictationDraft) throws -> DictationRecord {
        let words = DictationRecord.wordCount(draft.text)
        let text = try encode(draft.text), raw = try encode(draft.rawText)
        let id: Int64 = try queue.write { db in
            try db.execute(sql: "INSERT INTO dictations (created_at, app_name, style, language, duration, words, encrypted, text, raw_text) VALUES (?,?,?,?,?,?,?,?,?)",
                           arguments: [draft.createdAt.timeIntervalSince1970, draft.appName, draft.style, draft.language, draft.duration, words, cipher != nil, text, raw])
            return db.lastInsertedRowID
        }
        return DictationRecord(id: id, text: draft.text, rawText: draft.rawText, appName: draft.appName, style: draft.style,
                               language: draft.language, duration: draft.duration, words: words, createdAt: draft.createdAt)
    }

    public func fetch(limit: Int) throws -> [DictationRecord] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM dictations ORDER BY created_at DESC, id DESC LIMIT ?", arguments: [limit]) }
            .map(record(from:))
    }

    /// Case-insensitive substring match over decrypted text and raw transcript; blank query returns everything.
    public func search(_ query: String) throws -> [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = try fetch(limit: Int.max)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.text.lowercased().contains(needle) || $0.rawText.lowercased().contains(needle) }
    }

    public func count() throws -> Int { try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictations") ?? 0 } }
    public func delete(id: Int64) throws { try queue.write { try $0.execute(sql: "DELETE FROM dictations WHERE id = ?", arguments: [id]) } }
    public func deleteAll() throws { try queue.write { try $0.execute(sql: "DELETE FROM dictations") } }

    @discardableResult
    public func deleteOlderThan(_ cutoff: Date) throws -> Int {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE created_at < ?", arguments: [cutoff.timeIntervalSince1970])
            return db.changesCount
        }
    }

    func rawTextColumnForTesting(id: Int64) throws -> Data? {
        try queue.read { try Data.fetchOne($0, sql: "SELECT text FROM dictations WHERE id = ?", arguments: [id]) }
    }

    private func encode(_ text: String) throws -> Data { try cipher?.seal(text) ?? Data(text.utf8) }

    private func record(from row: Row) throws -> DictationRecord {
        let encrypted: Bool = row["encrypted"]
        func decode(_ column: String) throws -> String {
            let data: Data = row[column]
            if encrypted { guard let cipher else { throw StorageError.corruptRow }; return try cipher.open(data) }
            guard let s = String(data: data, encoding: .utf8) else { throw StorageError.corruptRow }
            return s
        }
        return DictationRecord(id: row["id"], text: try decode("text"), rawText: try decode("raw_text"), appName: row["app_name"],
                               style: row["style"], language: row["language"], duration: row["duration"], words: row["words"],
                               createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}
```
An encrypted row read by a store without a cipher (toggle turned off later) throws `corruptRow`; the History view model (3b) shows those rows as "Encrypted — turn on 'Encrypt history at rest' to read". Note it in the PR.

`Sources/VoxFlowStorage/RetentionPolicy.swift`:
```swift
import Foundation

/// "Delete history after" (design ST-05); 0 = keep forever.
public struct RetentionPolicy: Sendable, Equatable {
    public static let choices = [7, 30, 90, 365, 0]
    public static let `default` = RetentionPolicy(days: 30)
    public var days: Int
    public init(days: Int) { self.days = max(0, days) }
    public func cutoff(now: Date) -> Date? { days == 0 ? nil : now.addingTimeInterval(-Double(days) * 86_400) }
}
```

`Sources/VoxFlowStorage/RetentionRunner.swift`:
```swift
import Foundation
import VoxFlowCore

/// Purges at `start()` and then every 24 h (design §5 "runs at launch and daily").
public actor RetentionRunner {
    public static let interval: TimeInterval = 86_400
    private let store: DictationStore
    private let policy: @Sendable () -> RetentionPolicy
    private let now: @Sendable () -> Date
    private let clock: any MonotonicClock
    private var task: Task<Void, Never>?
    private var passes = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    public init(store: DictationStore, policy: @escaping @Sendable () -> RetentionPolicy, now: @escaping @Sendable () -> Date, clock: any MonotonicClock) { … }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.purge()
                do { try await self.clock.sleep(for: Self.interval) } catch { return }
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    /// Suspends until at least `count` purge passes have run (tests).
    public func waitForPass(_ count: Int) async {
        if passes >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func purge() {
        if let cutoff = policy().cutoff(now: now()) { _ = try? store.deleteOlderThan(cutoff) }
        passes += 1
        let ready = waiters.filter { $0.0 <= passes }
        waiters.removeAll { $0.0 <= passes }
        ready.forEach { $0.1.resume() }
    }
}
```
Use `[weak self]` + `guard let self` per iteration (the pattern from `FilesViewModel`), so a released runner ends its loop.

- [ ] **Step 4: Run** `swift test --filter VoxFlowStorageTests` — PASS; then `python3 scripts/affected_tests.py --help` still works and `scripts/tests` pass (`python3 -m unittest discover -s scripts/tests` — check the exact invocation in `ci.yml`).

- [ ] **Step 5: Commit**
```bash
git add VoxFlowKit/Package.swift VoxFlowKit/Package.resolved VoxFlowKit/Sources/VoxFlowStorage VoxFlowKit/Tests/VoxFlowStorageTests
git commit -m "feat(storage): encrypted dictation history on GRDB with retention"
```

---
### Task 7: Spike — fn key monitoring and Accessibility insertion (throwaway)

**Files:**
- Create: `spikes/fn-hotkey/Package.swift`, `spikes/fn-hotkey/Sources/fn-hotkey/main.swift`, `spikes/fn-hotkey/README.md`, `spikes/fn-hotkey/RESULTS.md`

**Purpose:** phase 3b needs three facts the documentation leaves fuzzy on macOS 26: (1) does an `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` see the fn key with **Accessibility** trust alone, or is Input Monitoring needed too; (2) does `AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute, …)` insert into TextEdit / Notes / Safari / a Terminal-hosted Electron app; (3) does `IsSecureEventInputEnabled()` flip while a password field is focused. Nothing from this directory ships; `spikes/whisper-perf/` is the precedent.

- [ ] **Step 1: Write the executable** (`swift-tools-version: 6.0`, single `executableTarget`, platforms macOS 15):
```swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
print("Accessibility trusted: \(trusted); Input Monitoring preflight: \(CGPreflightListenEventAccess())")
print("Secure input enabled now: \(IsSecureEventInputEnabled())")

var downAt: Date?
let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    let fn = event.modifierFlags.contains(.function)
    if fn, downAt == nil { downAt = Date(); print("fn DOWN  secureInput=\(IsSecureEventInputEnabled())") }
    if !fn, let start = downAt { print(String(format: "fn UP    held %.0f ms", Date().timeIntervalSince(start) * 1000)); downAt = nil }
}
print(monitor == nil ? "global monitor: nil (not trusted)" : "global monitor installed — press fn a few times")

DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    print("Inserting into the focused element of the frontmost app…")
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    let got = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
    guard got == .success, let element = focused else { print("no focused element: \(got.rawValue)"); return }
    let set = AXUIElementSetAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, "Hello from the VoxFlow spike. " as CFString)
    var app: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &app)
    print("AX set result: \(set.rawValue) (0 = success) role=\(app ?? "?" as CFTypeRef) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
}
RunLoop.main.run(until: Date().addingTimeInterval(20))
```
- [ ] **Step 2: `README.md`** — how to run: `cd spikes/fn-hotkey && swift build && .build/debug/fn-hotkey`; grant Accessibility to the terminal app when prompted; within 8 s click into TextEdit, then Notes, then a browser text field, then a password field in System Settings; run once per target app. What to record: each printed line, per app.
- [ ] **Step 3: Run it** once on this machine and write `RESULTS.md` with the raw output, the macOS version (`sw_vers -productVersion`), and one of three conclusions per question: works with Accessibility only / needs Input Monitoring / not observed (permission not grantable in this session). An implementer without a GUI session records "not observed" honestly and leaves the manual run to the owner; do not fabricate results.
- [ ] **Step 4: Commit**
```bash
git add spikes/fn-hotkey
git commit -m "chore(spike): throwaway probe for fn hotkey monitoring and AX insertion"
```

---

### Task 8: Docs, ADRs, issue bookkeeping, PR

**Files:**
- Create: `docs/adr/003-dictation-state-machine.md`, `docs/adr/004-history-encryption.md`
- Modify: `docs/adr/README.md` (index, if present — check), `CHANGELOG.md` (Unreleased → "2.1.0 in progress"), `README.md` (status line: phase 3 in progress; History encryption note), `VoxFlowKit/Sources/VoxFlowCore/Speech.swift` doc comment (replace "Tracked in issue #125" with "Decided in ADR-003: consumers check `Task.isCancelled` after the loop").
- Modify: `docs/superpowers/plans/2026-09-08-phase3a-dictation-logic.md` — nothing; the plan stays as the record.

- [ ] **Step 1: ADR-003 "Dictation as a pure state machine with windowed transcription"** — context (12 HUD states, timers, three async sources), decision (reducer + effects; controller runs effects; windows ≥ 3 s / ≤ 10 s with prompt tail; capture on fn-down; single final insertion; #125 option 1), consequences (tests need no clock; live insertion later; the engine's stream contract stays weak and is documented). Include the state table from Task 2.
- [ ] **Step 2: ADR-004 "History encryption: per-row AES-GCM with a Secure Enclave-wrapped key"** — context (design says "Key stored in the Secure Enclave"; SE cannot run AES; CI VMs have no SE; ad-hoc signed builds), decision (ECIES-style HKDF over an SE key-agreement key + stored salt public key; Keychain random key fallback; `encrypted` flag per row; in-memory search), consequences (rows written encrypted are unreadable when the toggle is off; moving the database to another Mac loses encrypted rows by design; phase 7's signing must keep the bundle id so Keychain items stay reachable).
- [ ] **Step 3: CHANGELOG/README** — under Unreleased: "Dictation logic: microphone capture, Flow Bar state machine, windowed transcription, encrypted history with 30-day retention (no UI yet — phase 3b)". README status: "2.0.0 released · 2.1.0 (dictation) in progress".
- [ ] **Step 4: Full verification**
```bash
cd VoxFlowKit && swift test 2>&1 | tail -5
cd .. && xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test 2>&1 | tail -5
python3 -m unittest discover -s scripts/tests 2>&1 | tail -3
```
All green; note counts in the report.
- [ ] **Step 5: Commit**
```bash
git add docs CHANGELOG.md README.md VoxFlowKit/Sources/VoxFlowCore/Speech.swift
git commit -m "docs: ADR-003 dictation state machine, ADR-004 history encryption"
```
- [ ] **Step 6: PR into `develop`** with the repository template: Summary (what 3a delivers, what 3b adds), Testing (the three commands + counts, spike outcome), checklist ticked, footer `Part of #110. Closes #125.` No attribution footer. Then: on #125 tick the criteria that the tests cover and comment the ruling; on #110 comment "3a merged: logic half; 3b next" after merge; open follow-up issues: "Live insertion while speaking (streaming Flow Bar text)" and "Name the app holding the microphone (CoreAudio hog mode) for FB-07".

---

## Self-review

- **Spec coverage:** §4 `MicrophoneSource` (Task 5), windows (Task 3), §5 dictations table / encryption / retention (Task 6), FB-01…FB-12 timings (Task 2), FB-07 variants (Tasks 2, 5), 3e long dictation / secure input / mic busy / wrong language (Tasks 2, 3), #125 (Tasks 3, 8). Not here on purpose: FB-09 (phase 4), FB-11 popover, ONB, History UI, hotkey monitor, AX inserter, permissions (phase 3b), `unload()` (memory pressure, later).
- **Type consistency:** `FlowBarEvent.transcriptReady(text:lowConfidence:)` ↔ `DictationResult.text/.lowConfidence` (Task 4 `finished`); `FlowBarEffect.finishCapture/abortCapture` ↔ controller; `Preflight` fields identical in Tasks 2 and 4; `FakeClock.waitForSleepers/advance` used the same way in Tasks 1, 4, 6; `DictationDraft` ↔ `DictationStore.insert`; `HistoryKeyProviding.historyKey()` ↔ `FakeKeyProvider`.
- **Placeholders:** the `{ … }` bodies are member-wise initializers and stored-property assignments only.
