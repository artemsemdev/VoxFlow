# VoxFlow v2 Phase 1 — Transcription Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An on-device transcription core with no UI: decode any AVFoundation-readable audio file to 16 kHz mono, transcribe it with whisper.cpp (streaming segments, cancellation, language detection), and manage the model files (catalog, free-space check, resumable download, checksum verification, remove rules).

**Architecture:** `VoxFlowCore` gains the domain types and the `SpeechEngine` / `ModelDownloading` / `FreeSpaceProviding` / `KeyValueStore` protocols. `VoxFlowAudio` implements `AudioDecoder`. `VoxFlowSpeech` links the whisper.cpp XCFramework (`binaryTarget`, pinned) and implements `WhisperCppEngine` (an actor that runs the C calls on its own serial queue). `VoxFlowModels` implements `ModelCatalog` and the `ModelStore` actor. `VoxFlowTestSupport` holds the fakes and fixture builders shared by all test targets. The performance spike lives under `v2/spikes/` (not built in CI) and its numbers are recorded in ADR-002.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing, AVFoundation, CryptoKit, whisper.cpp v1.9.2 XCFramework.

**Spec:** `v2/docs/superpowers/specs/2026-09-07-voxflow-v2-design.md` section 4; issue #108 (scope: `MicrophoneSource` moved to phase 3).

## Global Constraints

- Swift 6 language mode, `swiftLanguageModes: [.v6]`, no `@unchecked Sendable` unless a comment explains why it is safe; no `nonisolated(unsafe)`.
- `VoxFlowCore` imports Foundation only. Modules import Core; never the app.
- Unit tests never touch the network and never require a model file. The single integration test is gated with `.enabled(if:)` and prints why it skipped.
- whisper.cpp XCFramework pinned: `https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip`, checksum `af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b`, Swift module name `whisper`.
- Model files live in `~/Library/Application Support/VoxFlow/Models`; partial downloads use the `.partial` suffix; a model is "installed" only after its SHA-256 matched.
- Commits: Conventional Commits, owner-authored, no `Co-authored-by`, no AI attribution anywhere.
- Branch `feature/108-v2-transcription-engine` (from `develop`); PR into `develop`.
- Fixture sources supplied by the orchestrator: `attention-10s.wav` (8.7 s, 16 kHz mono, 284 KB) and `tone-1s.mp3` (8.6 KB).
- Verification command for the whole package: `cd v2/VoxFlowKit && swift test`. App scheme check at the end: `cd v2 && xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`.

---

### Task 1: Core domain types, protocols, and `VoxFlowTestSupport`

**Files:**
- Modify: `v2/VoxFlowKit/Package.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/Transcript.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/AudioSamples.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/Speech.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/Models.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeSpeechEngine.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeModelDownloader.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeFreeSpace.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/InMemoryKeyValueStore.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/TemporaryDirectory.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowCoreTests/TranscriptTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowCoreTests/SpeechTypesTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowCoreTests/FakeSpeechEngineTests.swift`

**Interfaces:**
- Consumes: `VoxFlowVersion` (exists).
- Produces (all `public`, in `VoxFlowCore`): `TranscriptSegment`, `Transcript`, `AudioSamples`, `LanguageDetection`, `TranscriptionOptions`, `SegmentEvent`, `SpeechEngine`, `SpeechEngineError`, `ModelRole`, `ModelDescriptor`, `ModelDownloading`, `DownloadError`, `FreeSpaceProviding`, `KeyValueStore`. In `VoxFlowTestSupport`: `FakeSpeechEngine`, `FakeModelDownloader`, `FakeFreeSpace`, `InMemoryKeyValueStore`, `TemporaryDirectory`.

- [ ] **Step 1: Write the failing Core tests**

`v2/VoxFlowKit/Tests/VoxFlowCoreTests/TranscriptTests.swift`:

```swift
import Testing
@testable import VoxFlowCore

@Suite("Transcript")
struct TranscriptTests {
    @Test("segment duration is end minus start")
    func segmentDuration() {
        let segment = TranscriptSegment(start: 1.5, end: 4.25, text: "hello")
        #expect(segment?.duration == 2.75)
    }

    @Test("segment rejects end before start")
    func segmentOrdering() {
        #expect(TranscriptSegment(start: 2, end: 1, text: "x") == nil)
    }

    @Test("transcript duration is the end of the last segment; empty is zero")
    func transcriptDuration() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 4.12, text: "Welcome back.")!,
            TranscriptSegment(start: 4.12, end: 9.86, text: "Last week we covered attention.")!,
        ])
        #expect(transcript.duration == 9.86)
        #expect(Transcript(segments: []).duration == 0)
    }

    @Test("word count and plain text")
    func wordCountAndPlainText() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: " Welcome back. ")!,
            TranscriptSegment(start: 1, end: 2, text: "Today we're  picking up")!,
        ])
        #expect(transcript.wordCount == 6)
        #expect(transcript.plainText == "Welcome back. Today we're  picking up")
    }
}
```

`v2/VoxFlowKit/Tests/VoxFlowCoreTests/SpeechTypesTests.swift`:

```swift
import Foundation
import Testing
@testable import VoxFlowCore

@Suite("Speech types")
struct SpeechTypesTests {
    @Test("audio duration derives from the fixed 16 kHz rate")
    func audioDuration() {
        let audio = AudioSamples([Float](repeating: 0, count: 32_000))
        #expect(audio.duration == 2)
        #expect(AudioSamples.sampleRate == 16_000)
    }

    @Test("language detection below 0.6 is low confidence (chip shows EN?)")
    func lowConfidence() {
        #expect(LanguageDetection(code: "en", confidence: 0.59).isLowConfidence)
        #expect(LanguageDetection(code: "en", confidence: 0.6).isLowConfidence == false)
    }

    @Test("vocabulary becomes the initial prompt, comma separated; empty is nil")
    func initialPrompt() {
        var options = TranscriptionOptions()
        #expect(options.initialPrompt == nil)
        options.vocabulary = ["VoxFlow", "Kubernetes", "Priya Raghunathan"]
        #expect(options.initialPrompt == "VoxFlow, Kubernetes, Priya Raghunathan")
    }

    @Test("defaults: auto language, no vocabulary, engine-chosen threads, no-speech 0.6")
    func defaults() {
        let options = TranscriptionOptions()
        #expect(options.language == nil)
        #expect(options.vocabulary.isEmpty)
        #expect(options.threadCount == nil)
        #expect(options.noSpeechThreshold == 0.6)
    }

    @Test("model descriptor exposes the on-disk file name from its download URL")
    func descriptorFileName() {
        let model = ModelDescriptor(
            id: "whisper-small", displayName: "Whisper small", role: .speech,
            downloadURL: URL(string: "https://example.com/models/ggml-small.bin")!,
            sizeInBytes: 487_601_967, sha256: "1be3", languagesSummary: "99 languages", isDefault: false)
        #expect(model.fileName == "ggml-small.bin")
    }
}
```

`v2/VoxFlowKit/Tests/VoxFlowCoreTests/FakeSpeechEngineTests.swift`:

```swift
import Foundation
import Testing
import VoxFlowTestSupport
@testable import VoxFlowCore

@Suite("FakeSpeechEngine")
struct FakeSpeechEngineTests {
    @Test("streams the scripted segments then finishes")
    func streamsScript() async throws {
        let engine = FakeSpeechEngine(script: [
            .segment(TranscriptSegment(start: 0, end: 1, text: "one")!),
            .progress(0.5),
            .segment(TranscriptSegment(start: 1, end: 2, text: "two")!),
        ])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        var events: [SegmentEvent] = []
        for try await event in engine.transcribe(AudioSamples([0, 0, 0]), options: TranscriptionOptions()) {
            events.append(event)
        }
        #expect(events.count == 3)
        #expect(await engine.transcribeCalls == 1)
    }

    @Test("throws when used before load")
    func requiresLoad() async {
        let engine = FakeSpeechEngine(script: [])
        await #expect(throws: SpeechEngineError.modelNotLoaded) {
            for try await _ in engine.transcribe(AudioSamples([]), options: TranscriptionOptions()) {}
        }
    }
}
```

- [ ] **Step 2: Update `Package.swift`**

Add the `VoxFlowTestSupport` target and make every test target depend on it. Replace the `targets:` array with:

```swift
    targets: [
        .target(name: "VoxFlowCore"),
        .target(name: "VoxFlowTestSupport", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowAudio", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowSpeech", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowModels", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowFiles", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowDictation", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowStorage", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowStyling", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowMCP", dependencies: ["VoxFlowCore"]),

        .testTarget(name: "VoxFlowCoreTests", dependencies: ["VoxFlowCore", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowAudioTests", dependencies: ["VoxFlowAudio", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowSpeechTests", dependencies: ["VoxFlowSpeech", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowModelsTests", dependencies: ["VoxFlowModels", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowFilesTests", dependencies: ["VoxFlowFiles", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowDictationTests", dependencies: ["VoxFlowDictation", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowStorageTests", dependencies: ["VoxFlowStorage", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowStylingTests", dependencies: ["VoxFlowStyling", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowMCPTests", dependencies: ["VoxFlowMCP", "VoxFlowTestSupport"]),
    ],
```

- [ ] **Step 3: Run the Core tests to verify they fail**

Run: `cd v2/VoxFlowKit && swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: errors such as `cannot find 'TranscriptSegment' in scope` and `no such module 'VoxFlowTestSupport'` (RED).

- [ ] **Step 4: Write the Core types**

`v2/VoxFlowKit/Sources/VoxFlowCore/Transcript.swift`:

```swift
import Foundation

/// One timed piece of recognized speech. `start`/`end` are seconds from the beginning of the audio.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    /// Returns nil when `end` precedes `start`.
    public init?(start: TimeInterval, end: TimeInterval, text: String) {
        guard end >= start else { return nil }
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: TimeInterval { end - start }
}

/// The recognized text of one recording, as ordered segments.
public struct Transcript: Sendable, Equatable, Codable {
    public var segments: [TranscriptSegment]
    /// ISO 639-1 code of the detected or requested language, when known.
    public var language: String?

    public init(segments: [TranscriptSegment], language: String? = nil) {
        self.segments = segments
        self.language = language
    }

    public var duration: TimeInterval { segments.last?.end ?? 0 }

    public var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Segment texts trimmed and joined with single spaces.
    public var plainText: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

`v2/VoxFlowKit/Sources/VoxFlowCore/AudioSamples.swift`:

```swift
import Foundation

/// Audio in the one internal format the engine accepts: 16 kHz, mono, Float32 in -1...1.
public struct AudioSamples: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public var samples: [Float]

    public init(_ samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var isEmpty: Bool { samples.isEmpty }
}
```

`v2/VoxFlowKit/Sources/VoxFlowCore/Speech.swift`:

```swift
import Foundation

/// Result of language auto-detection. Below `lowConfidenceThreshold` the UI shows "EN?" (design 3e).
public struct LanguageDetection: Sendable, Equatable {
    public static let lowConfidenceThreshold = 0.6

    public var code: String
    public var confidence: Double

    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }

    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

/// Per-run knobs for a `SpeechEngine`.
public struct TranscriptionOptions: Sendable, Equatable {
    /// ISO 639-1 code, or nil to auto-detect.
    public var language: String?
    /// Dictionary words the engine should be biased towards (becomes the initial prompt).
    public var vocabulary: [String]
    /// nil lets the engine pick.
    public var threadCount: Int?
    /// Segments whose no-speech probability exceeds this are dropped.
    public var noSpeechThreshold: Double

    public init(language: String? = nil, vocabulary: [String] = [], threadCount: Int? = nil, noSpeechThreshold: Double = 0.6) {
        self.language = language
        self.vocabulary = vocabulary
        self.threadCount = threadCount
        self.noSpeechThreshold = noSpeechThreshold
    }

    public var initialPrompt: String? {
        vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")
    }
}

/// Events streamed while transcribing.
public enum SegmentEvent: Sendable, Equatable {
    /// A finalized segment, in order.
    case segment(TranscriptSegment)
    /// Fraction of the audio processed, 0...1.
    case progress(Double)
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(code: Int32)
    case cancelled
}

/// A speech-to-text backend. Implementations own their model in memory; one transcription at a time.
public protocol SpeechEngine: Sendable {
    func load(modelAt url: URL) async throws
    func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection
    /// Streams final segments and progress; finishes when the audio is consumed. Cancel the
    /// consuming task to abort; the stream then throws `SpeechEngineError.cancelled`.
    func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error>
}
```

`v2/VoxFlowKit/Sources/VoxFlowCore/Models.swift`:

```swift
import Foundation

public enum ModelRole: String, Sendable, Codable, CaseIterable {
    case speech
    case style
}

/// A downloadable model as listed in the catalog (design ST-03).
public struct ModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let role: ModelRole
    public let downloadURL: URL
    public let sizeInBytes: Int64
    /// Lowercase hex SHA-256 of the file; verified before the model counts as installed.
    public let sha256: String
    public let languagesSummary: String
    public let isDefault: Bool

    public init(id: String, displayName: String, role: ModelRole, downloadURL: URL, sizeInBytes: Int64,
                sha256: String, languagesSummary: String, isDefault: Bool) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.downloadURL = downloadURL
        self.sizeInBytes = sizeInBytes
        self.sha256 = sha256
        self.languagesSummary = languagesSummary
        self.isDefault = isDefault
    }

    public var fileName: String { downloadURL.lastPathComponent }
}

public enum DownloadError: Error, Equatable, Sendable {
    /// Network went away; `bytesWritten` are safely on disk and a later call resumes from there.
    case offline(bytesWritten: Int64)
    case http(status: Int)
    case cancelled
}

/// Downloads one URL to one file, appending to an existing partial file (HTTP Range).
public protocol ModelDownloading: Sendable {
    /// `progress(bytesWritten, totalBytes)` is called as data lands. Throws `DownloadError`.
    func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws
}

public protocol FreeSpaceProviding: Sendable {
    func availableBytes(at directory: URL) throws -> Int64
}

/// Minimal persisted settings surface (UserDefaults in production).
public protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}
```

- [ ] **Step 5: Write the test-support fakes**

`v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeSpeechEngine.swift`:

```swift
import Foundation
import VoxFlowCore

/// Scripted `SpeechEngine` for callers' tests. Replays `script` for every transcription.
public actor FakeSpeechEngine: SpeechEngine {
    public private(set) var isLoaded = false
    public private(set) var loadedModelURL: URL?
    public private(set) var transcribeCalls = 0
    public private(set) var lastOptions: TranscriptionOptions?
    public var script: [SegmentEvent]
    public var detection: LanguageDetection

    public init(script: [SegmentEvent], detection: LanguageDetection = LanguageDetection(code: "en", confidence: 0.99)) {
        self.script = script
        self.detection = detection
    }

    public func load(modelAt url: URL) async throws {
        isLoaded = true
        loadedModelURL = url
    }

    public func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
        guard isLoaded else { throw SpeechEngineError.modelNotLoaded }
        return detection
    }

    public nonisolated func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await self.begin(options: options)
                    for event in events {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: SpeechEngineError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func begin(options: TranscriptionOptions) throws -> [SegmentEvent] {
        guard isLoaded else { throw SpeechEngineError.modelNotLoaded }
        transcribeCalls += 1
        lastOptions = options
        return script
    }
}
```

`v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeModelDownloader.swift`:

```swift
import Foundation
import VoxFlowCore

/// Serves in-memory bytes per URL, appends to an existing partial file, and can fail once
/// mid-transfer to simulate going offline (design ONB-04a / ST-03o).
public actor FakeModelDownloader: ModelDownloading {
    public struct Call: Equatable, Sendable {
        public let url: URL
        public let resumedFrom: Int64
    }

    private var payloads: [URL: Data] = [:]
    /// Fail with `.offline` after writing this many *new* bytes on the next call, then clear.
    public var failAfterBytes: Int64?
    public private(set) var calls: [Call] = []
    public var chunkSize = 64 * 1024

    public init() {}

    public func serve(_ data: Data, at url: URL) { payloads[url] = data }
    public func setFailAfterBytes(_ bytes: Int64?) { failAfterBytes = bytes }

    public func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        guard let data = payloads[url] else { throw DownloadError.http(status: 404) }
        let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        calls.append(Call(url: url, resumedFrom: existing))
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = existing
        var newBytes: Int64 = 0
        let total = Int64(data.count)
        var offset = Int(existing)
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            try handle.write(contentsOf: chunk)
            offset = end
            written += Int64(chunk.count)
            newBytes += Int64(chunk.count)
            progress(written, total)
            if let limit = failAfterBytes, newBytes >= limit {
                failAfterBytes = nil
                throw DownloadError.offline(bytesWritten: written)
            }
        }
    }
}
```

`v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeFreeSpace.swift`:

```swift
import Foundation
import VoxFlowCore

public struct FakeFreeSpace: FreeSpaceProviding {
    public var available: Int64
    public init(available: Int64) { self.available = available }
    public func availableBytes(at directory: URL) throws -> Int64 { available }
}
```

`v2/VoxFlowKit/Sources/VoxFlowTestSupport/InMemoryKeyValueStore.swift`:

```swift
import Foundation
import VoxFlowCore

public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    // Guarded by `lock`; the class is a test double and never shares an instance across tests.
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    public func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}
```

`v2/VoxFlowKit/Sources/VoxFlowTestSupport/TemporaryDirectory.swift`:

```swift
import Foundation

/// A unique directory under the system temporary folder, removed on `deinit`.
public final class TemporaryDirectory: Sendable {
    public let url: URL

    public init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
```

- [ ] **Step 6: Run the package tests**

Run: `cd v2/VoxFlowKit && swift test 2>&1 | grep -E "Test run with|error:|warning: .*Sources/"`
Expected: `Test run with 18 tests in 12 suites passed` (9 placeholder tests + 4 Transcript + 5 SpeechTypes... adjust to the printed count if the framework groups differently; the requirement is: all pass, no `error:`, no warnings from our sources).

- [ ] **Step 7: Commit**

```bash
git add v2/VoxFlowKit/Package.swift v2/VoxFlowKit/Sources/VoxFlowCore v2/VoxFlowKit/Sources/VoxFlowTestSupport v2/VoxFlowKit/Tests/VoxFlowCoreTests
git commit -m "feat(v2): add Core speech/model types and the VoxFlowTestSupport fakes

Transcript, AudioSamples, LanguageDetection, TranscriptionOptions,
SegmentEvent, the SpeechEngine protocol and the model/download/free-space/
settings protocols; fakes and a temp-directory helper shared by all test
targets. Refs #108."
```

---

### Task 2: `AudioDecoder` (VoxFlowAudio)

**Files:**
- Create: `v2/VoxFlowKit/Sources/VoxFlowAudio/AudioDecoder.swift`
- Delete: `v2/VoxFlowKit/Sources/VoxFlowAudio/AudioModule.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/FixtureAudio.swift`
- Create: `v2/VoxFlowKit/Tests/VoxFlowAudioTests/Fixtures/tone-1s.mp3` (copied from the orchestrator's path)
- Modify: `v2/VoxFlowKit/Package.swift` (resources for the Audio test target)
- Test: `v2/VoxFlowKit/Tests/VoxFlowAudioTests/AudioDecoderTests.swift` (replaces `AudioModuleTests.swift`, which is deleted)

**Interfaces:**
- Consumes: `AudioSamples`.
- Produces: `public struct AudioDecoder { init(); static let supportedExtensions: Set<String>; func decode(_ url: URL) throws -> AudioSamples }`, `public enum AudioDecodingError: Error, Equatable { case fileNotFound(URL), unsupportedType(String), decodeFailed(String) }`; `FixtureAudio.writeSine(to:seconds:sampleRate:channels:)` and `FixtureAudio.writeAAC(to:seconds:)` in TestSupport.

- [ ] **Step 1: Write the failing tests**

`v2/VoxFlowKit/Tests/VoxFlowAudioTests/AudioDecoderTests.swift`:

```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowAudio

@Suite("AudioDecoder")
struct AudioDecoderTests {
    let decoder = AudioDecoder()

    @Test("44.1 kHz stereo WAV decodes to 16 kHz mono of the same duration", arguments: ["wav", "aiff", "caf"])
    func pcmContainers(ext: String) throws {
        let dir = TemporaryDirectory()
        let url = dir.file("tone.\(ext)")
        try FixtureAudio.writeSine(to: url, seconds: 2, sampleRate: 44_100, channels: 2)
        let audio = try decoder.decode(url)
        #expect(abs(audio.duration - 2) < 0.05)
        #expect(audio.samples.max()! > 0.2)   // signal survived the conversion
        #expect(audio.samples.min()! < -0.2)
    }

    @Test("AAC in m4a and mp4 containers decodes", arguments: ["m4a", "mp4"])
    func aacContainers(ext: String) throws {
        let dir = TemporaryDirectory()
        let url = dir.file("tone.\(ext)")
        try FixtureAudio.writeAAC(to: url, seconds: 2)
        let audio = try decoder.decode(url)
        #expect(abs(audio.duration - 2) < 0.15)   // AAC adds encoder delay/padding
        #expect(audio.samples.max()! > 0.2)
    }

    @Test("MP3 decodes (committed fixture)")
    func mp3() throws {
        let url = Bundle.module.url(forResource: "tone-1s", withExtension: "mp3", subdirectory: "Fixtures")!
        let audio = try decoder.decode(url)
        #expect(abs(audio.duration - 1) < 0.15)
        #expect(audio.samples.max()! > 0.2)
    }

    @Test("unsupported extension is rejected before touching the file")
    func unsupportedType() {
        let dir = TemporaryDirectory()
        let url = dir.file("notes.pages")
        FileManager.default.createFile(atPath: url.path, contents: Data("hello".utf8))
        #expect(throws: AudioDecodingError.unsupportedType("pages")) { try decoder.decode(url) }
    }

    @Test("corrupt file with an audio extension fails with decodeFailed")
    func corruptFile() {
        let dir = TemporaryDirectory()
        let url = dir.file("broken.mp3")
        FileManager.default.createFile(atPath: url.path, contents: Data((0..<4096).map { UInt8($0 % 251) }))
        #expect { try decoder.decode(url) } throws: { error in
            if case AudioDecodingError.decodeFailed = error { return true }
            return false
        }
    }

    @Test("missing file is reported as such")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/voxflow/clip.wav")
        #expect(throws: AudioDecodingError.fileNotFound(url)) { try decoder.decode(url) }
    }

    @Test("extension check is case-insensitive")
    func caseInsensitive() throws {
        let dir = TemporaryDirectory()
        let url = dir.file("TONE.WAV")
        try FixtureAudio.writeSine(to: url, seconds: 0.5, sampleRate: 16_000, channels: 1)
        #expect(try decoder.decode(url).samples.count == 8_000)
    }
}
```

- [ ] **Step 2: Add the fixture and the test resource declaration**

Copy the MP3: `mkdir -p v2/VoxFlowKit/Tests/VoxFlowAudioTests/Fixtures && cp "<orchestrator path>/tone-1s.mp3" v2/VoxFlowKit/Tests/VoxFlowAudioTests/Fixtures/`.
In `Package.swift` change the Audio test target to:

```swift
        .testTarget(name: "VoxFlowAudioTests", dependencies: ["VoxFlowAudio", "VoxFlowTestSupport"],
                    resources: [.copy("Fixtures")]),
```

Delete `Sources/VoxFlowAudio/AudioModule.swift` and `Tests/VoxFlowAudioTests/AudioModuleTests.swift`.

- [ ] **Step 3: Run to verify RED**

Run: `cd v2/VoxFlowKit && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'AudioDecoder' in scope` / `cannot find 'FixtureAudio' in scope`.

- [ ] **Step 4: Write the fixture builder**

`v2/VoxFlowKit/Sources/VoxFlowTestSupport/FixtureAudio.swift`:

```swift
@preconcurrency import AVFoundation
import Foundation

/// Writes small synthetic audio files for decoder tests (no binaries in the repo except MP3,
/// which AVFoundation cannot encode).
public enum FixtureAudio {
    /// A 440 Hz sine at amplitude 0.5, PCM 16-bit; container chosen by the URL's extension
    /// (wav, aiff, caf).
    public static func writeSine(to url: URL, seconds: Double, sampleRate: Double, channels: UInt32) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased() == "aiff",
        ]
        try write(url: url, settings: settings, seconds: seconds, sampleRate: sampleRate, channels: channels)
    }

    /// A 440 Hz sine encoded as AAC (m4a or mp4 container).
    public static func writeAAC(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        try write(url: url, settings: settings, seconds: seconds, sampleRate: 44_100, channels: 1)
    }

    private static func write(url: URL, settings: [String: Any], seconds: Double, sampleRate: Double, channels: UInt32) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
            }
        }
        try file.write(from: buffer)
    }
}
```

- [ ] **Step 5: Write the decoder**

`v2/VoxFlowKit/Sources/VoxFlowAudio/AudioDecoder.swift`:

```swift
@preconcurrency import AVFoundation
import Foundation
import VoxFlowCore

public enum AudioDecodingError: Error, Equatable, Sendable {
    case fileNotFound(URL)
    /// The extension is not one VoxFlow accepts (design MW-06x: "Not an audio or video file").
    case unsupportedType(String)
    /// AVFoundation could not open or read the file ("Couldn't decode this file").
    case decodeFailed(String)
}

/// Decodes any AVFoundation-readable audio/video file to `AudioSamples` (16 kHz mono Float32).
public struct AudioDecoder: Sendable {
    /// Extensions accepted on drop (design MW-06 / MW-06x), lowercase.
    public static let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "caf", "mp4", "mov", "m4v",
    ]

    /// Input frames converted per iteration; bounds memory for multi-hour files.
    private static let chunkFrames: AVAudioFrameCount = 65_536

    public init() {}

    public func decode(_ url: URL) throws -> AudioSamples {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw AudioDecodingError.unsupportedType(ext) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioDecodingError.fileNotFound(url) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecodingError.decodeFailed(error.localizedDescription)
        }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioDecodingError.decodeFailed("no converter from \(file.processingFormat) to 16 kHz mono")
        }

        let ratio = AudioSamples.sampleRate / file.processingFormat.sampleRate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.chunkFrames)!
        let outputCapacity = AVAudioFrameCount(Double(Self.chunkFrames) * ratio) + 1024
        var reachedEnd = false

        while !reachedEnd {
            do {
                try file.read(into: inputBuffer, frameCount: Self.chunkFrames)
            } catch {
                throw AudioDecodingError.decodeFailed(error.localizedDescription)
            }
            if inputBuffer.frameLength == 0 { break }
            reachedEnd = file.framePosition >= file.length

            let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity)!
            var provided = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if let conversionError { throw AudioDecodingError.decodeFailed(conversionError.localizedDescription) }
            if status == .error { throw AudioDecodingError.decodeFailed("conversion failed") }
            output.append(contentsOf: UnsafeBufferPointer(start: outputBuffer.floatChannelData![0],
                                                         count: Int(outputBuffer.frameLength)))
        }

        // Flush the converter's internal state (resampler tail).
        let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)!
        var flushError: NSError?
        _ = converter.convert(to: tail, error: &flushError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        output.append(contentsOf: UnsafeBufferPointer(start: tail.floatChannelData![0], count: Int(tail.frameLength)))

        return AudioSamples(output)
    }
}
```

- [ ] **Step 6: Run the Audio tests**

Run: `cd v2/VoxFlowKit && swift test --filter '^VoxFlowAudioTests\.' 2>&1 | grep -E "✔|✘|error:|Test run"`
Expected: all 9 parameterized cases pass. If the `aiff` case fails on big-endian settings, drop `AVLinearPCMIsBigEndianKey` (AVAudioFile picks a valid layout). If `mp4` writing is refused, change the argument list to `["m4a"]` and note it in the report.

- [ ] **Step 7: Commit**

```bash
git add v2/VoxFlowKit
git commit -m "feat(v2): add AudioDecoder converting any AVFoundation file to 16 kHz mono

Chunked AVAudioConverter pipeline with typed errors for unsupported
types, missing files and decode failures (design MW-06x). Tests build
WAV/AIFF/CAF/AAC fixtures at run time; a 1 s MP3 fixture is committed.
Refs #108."
```

---

### Task 3: `WhisperCppEngine` (VoxFlowSpeech) with the pinned XCFramework

**Files:**
- Modify: `v2/VoxFlowKit/Package.swift` (binary target + Speech dependency + Speech test resources)
- Create: `v2/VoxFlowKit/Sources/VoxFlowSpeech/WhisperCppEngine.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowSpeech/WhisperParameters.swift`
- Delete: `v2/VoxFlowKit/Sources/VoxFlowSpeech/SpeechModule.swift`, `Tests/VoxFlowSpeechTests/SpeechModuleTests.swift`
- Create: `v2/VoxFlowKit/Tests/VoxFlowSpeechTests/Fixtures/attention-10s.wav` (copied from the orchestrator's path)
- Test: `v2/VoxFlowKit/Tests/VoxFlowSpeechTests/WhisperParametersTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowSpeechTests/WhisperCppEngineIntegrationTests.swift`

**Interfaces:**
- Consumes: `SpeechEngine`, `AudioSamples`, `TranscriptionOptions`, `SegmentEvent`, `AudioDecoder` (test only).
- Produces: `public actor WhisperCppEngine: SpeechEngine { init() }`; `struct WhisperParameters` (internal, testable mapping of `TranscriptionOptions`).

- [ ] **Step 1: Package wiring**

In `Package.swift` add to `targets`:

```swift
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
```

change the Speech target to `.target(name: "VoxFlowSpeech", dependencies: ["VoxFlowCore", "whisper"])` and the Speech test target to:

```swift
        .testTarget(name: "VoxFlowSpeechTests", dependencies: ["VoxFlowSpeech", "VoxFlowAudio", "VoxFlowTestSupport"],
                    resources: [.copy("Fixtures")]),
```

Copy the WAV: `mkdir -p v2/VoxFlowKit/Tests/VoxFlowSpeechTests/Fixtures && cp "<orchestrator path>/attention-10s.wav" v2/VoxFlowKit/Tests/VoxFlowSpeechTests/Fixtures/`.

- [ ] **Step 2: Write the failing tests**

`v2/VoxFlowKit/Tests/VoxFlowSpeechTests/WhisperParametersTests.swift`:

```swift
import Testing
import VoxFlowCore
@testable import VoxFlowSpeech

@Suite("WhisperParameters")
struct WhisperParametersTests {
    @Test("auto language maps to nil language and no forced detection")
    func autoLanguage() {
        let params = WhisperParameters(options: TranscriptionOptions(), availableCores: 10)
        #expect(params.language == nil)
        #expect(params.threadCount == 8)     // min(cores, 8): Metal does the heavy lifting
    }

    @Test("explicit language and thread count are passed through; threads clamp to 1...16")
    func explicit() {
        let params = WhisperParameters(options: TranscriptionOptions(language: "de", threadCount: 99), availableCores: 4)
        #expect(params.language == "de")
        #expect(params.threadCount == 16)
        #expect(WhisperParameters(options: TranscriptionOptions(threadCount: 0), availableCores: 4).threadCount == 1)
    }

    @Test("vocabulary becomes the initial prompt and the no-speech threshold is forwarded")
    func promptAndThreshold() {
        let options = TranscriptionOptions(vocabulary: ["VoxFlow", "Kubernetes"], noSpeechThreshold: 0.4)
        let params = WhisperParameters(options: options, availableCores: 8)
        #expect(params.initialPrompt == "VoxFlow, Kubernetes")
        #expect(params.noSpeechThreshold == 0.4)
    }
}
```

`v2/VoxFlowKit/Tests/VoxFlowSpeechTests/WhisperCppEngineIntegrationTests.swift`:

```swift
import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
@testable import VoxFlowSpeech

/// Runs the real engine when a Whisper model is installed on this machine; skipped otherwise.
enum InstalledModel {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoxFlow/Models")
    /// Smallest available first: tests care about the plumbing, not accuracy.
    static let url: URL? = ["ggml-small.bin", "ggml-large-v3-turbo.bin", "ggml-base.bin"]
        .map { directory.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

@Suite("WhisperCppEngine (RequiresModel)", .enabled(if: InstalledModel.url != nil,
       "No Whisper model in ~/Library/Application Support/VoxFlow/Models; download one via the app or the spike"))
struct WhisperCppEngineIntegrationTests {
    @Test("transcribes the fixture, streams ordered segments and detects English")
    func transcribesFixture() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)

        let language = try await engine.detectLanguage(in: audio)
        #expect(language.code == "en")
        #expect(language.confidence > 0.8)

        var segments: [TranscriptSegment] = []
        var lastProgress = 0.0
        for try await event in engine.transcribe(audio, options: TranscriptionOptions(language: "en")) {
            switch event {
            case .segment(let segment): segments.append(segment)
            case .progress(let value):
                #expect(value >= lastProgress)
                lastProgress = value
            }
        }
        let text = Transcript(segments: segments).plainText.lowercased()
        #expect(text.contains("attention"))
        #expect(segments.map(\.start) == segments.map(\.start).sorted())
        #expect(segments.last!.end <= audio.duration + 0.5)
    }

    @Test("cancelling the consumer aborts the run")
    func cancellation() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        let task = Task {
            var count = 0
            for try await _ in engine.transcribe(audio, options: TranscriptionOptions(language: "en")) {
                count += 1
                if count == 1 { Task { task.cancel() } }   // see note below
            }
        }
        // Cancel almost immediately; the engine must stop and throw `cancelled`.
        task.cancel()
        await #expect(throws: SpeechEngineError.cancelled) { try await task.value }
    }

    @Test("using the engine before load fails")
    func requiresLoad() async {
        let engine = WhisperCppEngine()
        await #expect(throws: SpeechEngineError.modelNotLoaded) {
            _ = try await engine.detectLanguage(in: AudioSamples([Float](repeating: 0, count: 16_000)))
        }
    }
}
```

(Simplify the cancellation test body to: create `task`, `task.cancel()` right away, then expect `SpeechEngineError.cancelled` from `task.value`; remove the inner self-cancel line — it is shown only to make the intent explicit.)

- [ ] **Step 3: Run to verify RED**

Run: `cd v2/VoxFlowKit && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'WhisperParameters' in scope`, `cannot find 'WhisperCppEngine' in scope`. (The first build also downloads the 51 MB XCFramework.)

- [ ] **Step 4: Write the parameter mapping**

`v2/VoxFlowKit/Sources/VoxFlowSpeech/WhisperParameters.swift`:

```swift
import Foundation
import VoxFlowCore

/// Pure mapping from `TranscriptionOptions` to the values handed to whisper.cpp; testable without a model.
struct WhisperParameters: Equatable {
    static let maxThreads = 16
    /// Metal does the heavy lifting; more CPU threads than this only burn power (spike, 2026-09-08).
    static let defaultThreadCap = 8

    let language: String?
    let threadCount: Int
    let initialPrompt: String?
    let noSpeechThreshold: Float

    init(options: TranscriptionOptions, availableCores: Int) {
        language = options.language
        let requested = options.threadCount ?? min(availableCores, Self.defaultThreadCap)
        threadCount = min(max(requested, 1), Self.maxThreads)
        initialPrompt = options.initialPrompt
        noSpeechThreshold = Float(options.noSpeechThreshold)
    }
}
```

- [ ] **Step 5: Write the engine**

`v2/VoxFlowKit/Sources/VoxFlowSpeech/WhisperCppEngine.swift`:

```swift
import Foundation
import VoxFlowCore
import whisper

/// `SpeechEngine` over whisper.cpp. The C context is touched only on `queue`; the actor
/// serializes calls and awaits the queue, so long transcriptions never block a cooperative thread.
public actor WhisperCppEngine: SpeechEngine {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.whisper", qos: .userInitiated)
    private var context: ContextBox?

    public init() {}

    /// Owns the `whisper_context` pointer and frees it when the engine goes away.
    final class ContextBox: @unchecked Sendable {
        // Safe: the pointer is only dereferenced on `WhisperCppEngine.queue`.
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { whisper_free(pointer) }
    }

    /// State shared with the C callbacks during one `whisper_full` call.
    final class RunState: @unchecked Sendable {
        // Safe: written only from whisper.cpp's callbacks, which run on `queue` inside whisper_full.
        let continuation: AsyncThrowingStream<SegmentEvent, Error>.Continuation
        let isCancelled: @Sendable () -> Bool
        var emitted: Int32 = 0
        init(continuation: AsyncThrowingStream<SegmentEvent, Error>.Continuation, isCancelled: @escaping @Sendable () -> Bool) {
            self.continuation = continuation
            self.isCancelled = isCancelled
        }
    }

    public func load(modelAt url: URL) async throws {
        let path = url.path
        let box: ContextBox = try await onQueue {
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let pointer = whisper_init_from_file_with_params(path, params) else {
                throw SpeechEngineError.modelLoadFailed(path)
            }
            return ContextBox(pointer)
        }
        context = box
    }

    public func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
        guard let context else { throw SpeechEngineError.modelNotLoaded }
        let samples = audio.samples
        let threads = Int32(WhisperParameters(options: TranscriptionOptions(), availableCores: ProcessInfo.processInfo.activeProcessorCount).threadCount)
        return try await onQueue {
            var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
            let languageID: Int32 = samples.withUnsafeBufferPointer { buffer in
                guard whisper_pcm_to_mel(context.pointer, buffer.baseAddress, Int32(buffer.count), threads) == 0 else { return -1 }
                return whisper_lang_auto_detect(context.pointer, 0, threads, &probabilities)
            }
            guard languageID >= 0 else { throw SpeechEngineError.transcriptionFailed(code: languageID) }
            let code = String(cString: whisper_lang_str(languageID))
            return LanguageDetection(code: code, confidence: Double(probabilities[Int(languageID)]))
        }
    }

    public nonisolated func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(audio, options: options, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ audio: AudioSamples, options: TranscriptionOptions,
                     continuation: AsyncThrowingStream<SegmentEvent, Error>.Continuation) async throws {
        guard let context else { throw SpeechEngineError.modelNotLoaded }
        let mapped = WhisperParameters(options: options, availableCores: ProcessInfo.processInfo.activeProcessorCount)
        let samples = audio.samples
        let state = RunState(continuation: continuation, isCancelled: { Task.isCancelled })
        // `isCancelled` must observe the *consumer's* task; capture it here where we are on that task.
        let cancelFlag = CancelFlag()
        let watcher = Task { // mirrors cancellation of the consuming task into a flag the C callback can read
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            cancelFlag.set()
        }
        defer { watcher.cancel() }
        let runState = RunState(continuation: continuation, isCancelled: { cancelFlag.isSet })
        _ = state

        try await onQueue {
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(mapped.threadCount)
            params.print_progress = false
            params.print_realtime = false
            params.print_special = false
            params.print_timestamps = false
            params.no_speech_thold = mapped.noSpeechThreshold
            params.single_segment = false

            let languageC = mapped.language.map { strdup($0) }
            let promptC = mapped.initialPrompt.map { strdup($0) }
            defer { free(languageC); free(promptC) }
            params.language = languageC.map { UnsafePointer($0) }
            params.detect_language = false
            params.initial_prompt = promptC.map { UnsafePointer($0) }

            let unmanaged = Unmanaged.passRetained(runState)
            defer { unmanaged.release() }
            let userData = unmanaged.toOpaque()

            params.new_segment_callback_user_data = userData
            params.new_segment_callback = { ctx, _, _, userData in
                guard let ctx, let userData else { return }
                let state = Unmanaged<RunState>.fromOpaque(userData).takeUnretainedValue()
                let total = whisper_full_n_segments(ctx)
                while state.emitted < total {
                    let i = state.emitted
                    let start = Double(whisper_full_get_segment_t0(ctx, i)) / 100
                    let end = Double(whisper_full_get_segment_t1(ctx, i)) / 100
                    let text = String(cString: whisper_full_get_segment_text(ctx, i))
                    if let segment = TranscriptSegment(start: start, end: end, text: text) {
                        state.continuation.yield(.segment(segment))
                    }
                    state.emitted += 1
                }
            }
            params.progress_callback_user_data = userData
            params.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                let state = Unmanaged<RunState>.fromOpaque(userData).takeUnretainedValue()
                state.continuation.yield(.progress(min(max(Double(progress) / 100, 0), 1)))
            }
            params.abort_callback_user_data = userData
            params.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<RunState>.fromOpaque(userData).takeUnretainedValue().isCancelled()
            }

            let code = samples.withUnsafeBufferPointer { buffer in
                whisper_full(context.pointer, params, buffer.baseAddress, Int32(buffer.count))
            }
            if runState.isCancelled() { throw SpeechEngineError.cancelled }
            guard code == 0 else { throw SpeechEngineError.transcriptionFailed(code: code) }
            runState.continuation.yield(.progress(1))
        }
    }

    /// Thread-safe cancellation flag readable from a C callback.
    final class CancelFlag: @unchecked Sendable {
        // Safe: a single Bool guarded by a lock.
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    /// Runs `body` on the engine's serial queue and resumes when it finishes.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
```

Clean-up required when transcribing this block into the file: remove the dead `state`/`_ = state` lines (the `watcher` + `cancelFlag` + `runState` triple is the real mechanism; the first `RunState(... { Task.isCancelled })` is not needed). `free(nil)` is legal, so the `defer { free(...) }` is fine for nil prompts.

- [ ] **Step 6: Run the Speech tests**

Run: `cd v2/VoxFlowKit && swift test --filter '^VoxFlowSpeechTests\.' 2>&1 | grep -E "✔|✘|error:|skipped|Test run"`
Expected: 3 `WhisperParameters` tests pass; the integration suite runs (a model is installed on the owner's Mac) and its 3 tests pass; the first transcription may take ~10 s (Metal shader compile). On a machine without a model the suite reports as skipped with the reason.

- [ ] **Step 7: Commit**

```bash
git add v2/VoxFlowKit
git commit -m "feat(v2): add WhisperCppEngine over the pinned whisper.cpp XCFramework

Actor that runs whisper.cpp on a serial queue, streams final segments and
progress through AsyncThrowingStream, honours cancellation via the abort
callback, and maps TranscriptionOptions (language, vocabulary prompt,
threads, no-speech threshold). Integration test gated on an installed
model. Refs #108."
```

---

### Task 4: `ModelCatalog` and `ModelStore` (VoxFlowModels)

**Files:**
- Create: `v2/VoxFlowKit/Sources/VoxFlowModels/ModelCatalog.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowModels/ModelStore.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowModels/SHA256File.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowModels/RangeResumingDownloader.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowModels/VolumeFreeSpace.swift`
- Delete: `v2/VoxFlowKit/Sources/VoxFlowModels/ModelsModule.swift`, `Tests/VoxFlowModelsTests/ModelsModuleTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowModelsTests/ModelCatalogTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowModelsTests/ModelStoreTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowModelsTests/SHA256FileTests.swift`

**Interfaces:**
- Consumes: `ModelDescriptor`, `ModelDownloading`, `FreeSpaceProviding`, `KeyValueStore`, `DownloadError`, fakes.
- Produces: `public enum ModelCatalog { static let all: [ModelDescriptor]; static func model(id:) -> ModelDescriptor? }`, `public enum ModelState`, `public enum ModelStoreError`, `public actor ModelStore`, `public enum SHA256File { static func hexDigest(of: URL) throws -> String }`, `public struct RangeResumingDownloader: ModelDownloading`, `public struct VolumeFreeSpace: FreeSpaceProviding`.

- [ ] **Step 1: Write the failing tests**

`v2/VoxFlowKit/Tests/VoxFlowModelsTests/ModelCatalogTests.swift`:

```swift
import Testing
import VoxFlowCore
@testable import VoxFlowModels

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test("lists the design's three models with turbo as the speech default")
    func contents() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(ids == ["whisper-large-v3-turbo", "whisper-small", "qwen2.5-3b-instruct-q4"])
        let defaults = ModelCatalog.all.filter(\.isDefault).map(\.id)
        #expect(defaults == ["whisper-large-v3-turbo", "qwen2.5-3b-instruct-q4"])
    }

    @Test("sizes and checksums match the published files")
    func sizesAndChecksums() {
        let turbo = ModelCatalog.model(id: "whisper-large-v3-turbo")!
        #expect(turbo.sizeInBytes == 1_624_555_275)
        #expect(turbo.sha256 == "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
        #expect(turbo.fileName == "ggml-large-v3-turbo.bin")
        let small = ModelCatalog.model(id: "whisper-small")!
        #expect(small.sizeInBytes == 487_601_967)
        #expect(small.sha256 == "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")
        #expect(ModelCatalog.model(id: "nope") == nil)
    }
}
```

`v2/VoxFlowKit/Tests/VoxFlowModelsTests/SHA256FileTests.swift`:

```swift
import Foundation
import Testing
import VoxFlowTestSupport
@testable import VoxFlowModels

@Suite("SHA256File")
struct SHA256FileTests {
    @Test("hashes a file streamed in chunks")
    func hashes() throws {
        let dir = TemporaryDirectory()
        let url = dir.file("abc.txt")
        try Data("abc".utf8).write(to: url)
        #expect(try SHA256File.hexDigest(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
```

`v2/VoxFlowKit/Tests/VoxFlowModelsTests/ModelStoreTests.swift`:

```swift
import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowModels

@Suite("ModelStore")
struct ModelStoreTests {
    // Two tiny "models" standing in for turbo/small; payload bytes are deterministic.
    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    static let bigPayload = payload(1, count: 300_000)
    static let smallPayload = payload(2, count: 100_000)

    static func descriptor(id: String, payload: Data, isDefault: Bool) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, role: .speech,
                        downloadURL: URL(string: "https://example.com/\(id).bin")!,
                        sizeInBytes: Int64(payload.count),
                        sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                        languagesSummary: "test", isDefault: isDefault)
    }
    static let big = descriptor(id: "big", payload: bigPayload, isDefault: true)
    static let small = descriptor(id: "small", payload: smallPayload, isDefault: false)

    struct Harness {
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        let settings = InMemoryKeyValueStore()
        var freeSpace = FakeFreeSpace(available: 10_000_000_000)
        func store() -> ModelStore {
            ModelStore(directory: dir.url, catalog: [ModelStoreTests.big, ModelStoreTests.small],
                       downloader: downloader, freeSpace: freeSpace, settings: settings)
        }
        func serveAll() async {
            await downloader.serve(ModelStoreTests.bigPayload, at: ModelStoreTests.big.downloadURL)
            await downloader.serve(ModelStoreTests.smallPayload, at: ModelStoreTests.small.downloadURL)
        }
    }

    static func drain(_ stream: AsyncThrowingStream<ModelState, Error>) async throws -> [ModelState] {
        var states: [ModelState] = []
        for try await state in stream { states.append(state) }
        return states
    }

    @Test("fresh directory: nothing installed, catalog default is not usable yet")
    func freshDirectory() async {
        let h = Harness()
        let store = h.store()
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(await store.installedModels(role: .speech).isEmpty)
        #expect(await store.defaultModel(role: .speech) == nil)
    }

    @Test("install downloads, verifies and marks installed; default follows the catalog")
    func install() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        let states = try await Self.drain(await store.install(id: "big"))
        #expect(states.first == .downloading(bytesWritten: 65_536, total: 300_000))
        #expect(states.contains(.verifying))
        #expect(states.last == .installed)
        #expect(await store.state(of: "big") == .installed)
        #expect(await store.defaultModel(role: .speech)?.id == "big")
        #expect(FileManager.default.fileExists(atPath: h.dir.file("big.bin").path))
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin.partial").path))
    }

    @Test("refuses to start when free space is below size + 500 MB reserve (SYS-DISK)")
    func insufficientSpace() async throws {
        var h = Harness()
        await h.serveAll()
        h.freeSpace = FakeFreeSpace(available: 300_000 + ModelStore.reserveBytes - 1)
        let store = h.store()
        await #expect(throws: ModelStoreError.insufficientDiskSpace(required: 300_000 + ModelStore.reserveBytes,
                                                                  available: 300_000 + ModelStore.reserveBytes - 1)) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await h.downloader.calls.isEmpty)
    }

    @Test("going offline leaves a partial file; the next install resumes from it (ONB-04a)")
    func resume() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setFailAfterBytes(131_072)
        let store = h.store()
        await #expect(throws: ModelStoreError.downloadInterrupted(bytesWritten: 131_072)) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await store.state(of: "big") == .paused(bytesWritten: 131_072, total: 300_000))
        let states = try await Self.drain(await store.install(id: "big"))
        #expect(states.last == .installed)
        let calls = await h.downloader.calls
        #expect(calls.map(\.resumedFrom) == [0, 131_072])
    }

    @Test("checksum mismatch deletes the file and reports failure (ST-03v)")
    func checksumMismatch() async throws {
        let h = Harness()
        await h.downloader.serve(Self.smallPayload, at: Self.big.downloadURL)   // wrong bytes for "big"
        let store = h.store()
        await #expect(throws: ModelStoreError.checksumMismatch) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin").path))
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin.partial").path))
    }

    @Test("the only installed speech model cannot be removed (ST-03d)")
    func cannotRemoveOnly() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        await #expect(throws: ModelStoreError.cannotRemoveOnlyModel("big")) { try await store.remove(id: "big") }
    }

    @Test("removing the default switches the default to another installed model")
    func removeSwitchesDefault() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        _ = try await Self.drain(await store.install(id: "small"))
        #expect(await store.defaultModel(role: .speech)?.id == "big")
        try await store.remove(id: "big")
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(await store.defaultModel(role: .speech)?.id == "small")
        #expect(h.settings.string(forKey: "models.default.speech") == "small")
    }

    @Test("a file deleted behind the store's back reads as not installed, with no re-download")
    func manualDeletion() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        try FileManager.default.removeItem(at: h.dir.file("big.bin"))
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(await store.installedModels(role: .speech).isEmpty)
        #expect(await h.downloader.calls.count == 1)
    }

    @Test("setDefault persists and rejects models that are not installed")
    func setDefault() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        await #expect(throws: ModelStoreError.notInstalled("small")) { try await store.setDefault(id: "small") }
        _ = try await Self.drain(await store.install(id: "small"))
        try await store.setDefault(id: "small")
        #expect(h.settings.string(forKey: "models.default.speech") == "small")
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `cd v2/VoxFlowKit && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ModelCatalog' in scope` etc.

- [ ] **Step 3: Write the catalog, hashing, downloader, free space**

`v2/VoxFlowKit/Sources/VoxFlowModels/ModelCatalog.swift`:

```swift
import Foundation
import VoxFlowCore

/// The models VoxFlow can download (design ST-03). Checksums verified 2026-09-07.
public enum ModelCatalog {
    private static let whisperBase = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

    public static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", role: .speech,
            downloadURL: whisperBase.appendingPathComponent("ggml-large-v3-turbo.bin"),
            sizeInBytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            languagesSummary: "99 languages · best accuracy on M-series", isDefault: true),
        ModelDescriptor(
            id: "whisper-small", displayName: "Whisper small", role: .speech,
            downloadURL: whisperBase.appendingPathComponent("ggml-small.bin"),
            sizeInBytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            languagesSummary: "99 languages · for 8 GB Macs", isDefault: false),
        ModelDescriptor(
            id: "qwen2.5-3b-instruct-q4", displayName: "Qwen2.5 3B Instruct (4-bit)", role: .style,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
            sizeInBytes: 2_100_000_000,   // TODO(phase 5): pin the exact size and checksum when the style engine lands
            sha256: "",
            languagesSummary: "powers Formal / Casual / Very casual rewriting", isDefault: true),
    ]

    public static func model(id: String) -> ModelDescriptor? { all.first { $0.id == id } }
}
```

(The Qwen row is data for the Models screen in phase 2; an empty `sha256` makes `ModelStore.install` refuse it with `ModelStoreError.checksumUnknown` — see the store.)

`v2/VoxFlowKit/Sources/VoxFlowModels/SHA256File.swift`:

```swift
import CryptoKit
import Foundation

public enum SHA256File {
    /// Streams the file in 1 MiB chunks so multi-GB models never sit in memory.
    public static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

`v2/VoxFlowKit/Sources/VoxFlowModels/RangeResumingDownloader.swift`:

```swift
import Foundation
import VoxFlowCore

/// Production downloader: HTTP with a `Range` header so an interrupted transfer resumes from
/// the bytes already on disk. Not unit-tested (network); exercised by the app in phase 2.
public struct RangeResumingDownloader: ModelDownloading {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw DownloadError.offline(bytesWritten: existing)
        }
        guard let http = response as? HTTPURLResponse else { throw DownloadError.http(status: -1) }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw DownloadError.http(status: http.statusCode) }
        let resumed = http.statusCode == 206
        let total = (resumed ? existing : 0) + max(http.expectedContentLength, 0)

        if !resumed || !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if resumed { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }

        var written = resumed ? existing : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written, total)
                }
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            try handle.write(contentsOf: buffer)
            throw DownloadError.cancelled
        } catch {
            try handle.write(contentsOf: buffer)
            throw DownloadError.offline(bytesWritten: written + Int64(buffer.count))
        }
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        progress(written, total)
    }
}
```

`v2/VoxFlowKit/Sources/VoxFlowModels/VolumeFreeSpace.swift`:

```swift
import Foundation
import VoxFlowCore

public struct VolumeFreeSpace: FreeSpaceProviding {
    public init() {}
    public func availableBytes(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
```

- [ ] **Step 4: Write the store**

`v2/VoxFlowKit/Sources/VoxFlowModels/ModelStore.swift`:

```swift
import Foundation
import VoxFlowCore

public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(bytesWritten: Int64, total: Int64)
    /// A partial file is on disk; `install` resumes from it.
    case paused(bytesWritten: Int64, total: Int64)
    case verifying
    case installed
}

public enum ModelStoreError: Error, Equatable, Sendable {
    case unknownModel(String)
    case checksumUnknown(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case downloadInterrupted(bytesWritten: Int64)
    case downloadFailed(String)
    case checksumMismatch
    case notInstalled(String)
    case cannotRemoveOnlyModel(String)
}

/// Owns the model files on disk (design ST-03, ST-03v, ST-03d, SYS-DISK, ONB-04a).
/// Installed = the file exists with its expected size and, at install time, its SHA-256 matched.
public actor ModelStore {
    /// Kept free beyond the model size before a download starts (design SYS-DISK: "plus 500 MB").
    public static let reserveBytes: Int64 = 500 * 1024 * 1024

    public let directory: URL
    private let catalog: [ModelDescriptor]
    private let downloader: any ModelDownloading
    private let freeSpace: any FreeSpaceProviding
    private let settings: any KeyValueStore
    private let fileManager = FileManager.default
    private var inProgress: [String: ModelState] = [:]

    public init(directory: URL, catalog: [ModelDescriptor] = ModelCatalog.all, downloader: any ModelDownloading,
                freeSpace: any FreeSpaceProviding, settings: any KeyValueStore) {
        self.directory = directory
        self.catalog = catalog
        self.downloader = downloader
        self.freeSpace = freeSpace
        self.settings = settings
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Production location: ~/Library/Application Support/VoxFlow/Models.
    public static var defaultDirectory: URL {
        fileManager_applicationSupport.appendingPathComponent("VoxFlow/Models", isDirectory: true)
    }
    private static var fileManager_applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    // MARK: Queries

    public func state(of id: String) -> ModelState {
        if let active = inProgress[id] { return active }
        guard let model = descriptor(id) else { return .notInstalled }
        if fileSize(installedURL(model)) == model.sizeInBytes { return .installed }
        if let partial = fileSize(partialURL(model)), partial > 0 {
            return .paused(bytesWritten: partial, total: model.sizeInBytes)
        }
        return .notInstalled
    }

    public func installedModels(role: ModelRole) -> [ModelDescriptor] {
        catalog.filter { $0.role == role && state(of: $0.id) == .installed }
    }

    /// The persisted default if it is installed, else the catalog default if installed, else the
    /// first installed model of that role, else nil.
    public func defaultModel(role: ModelRole) -> ModelDescriptor? {
        let installed = installedModels(role: role)
        if let saved = settings.string(forKey: Self.defaultKey(role)), let model = installed.first(where: { $0.id == saved }) {
            return model
        }
        return installed.first(where: \.isDefault) ?? installed.first
    }

    public func setDefault(id: String) throws {
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard state(of: id) == .installed else { throw ModelStoreError.notInstalled(id) }
        settings.set(id, forKey: Self.defaultKey(model.role))
    }

    // MARK: Install

    /// Streams states until `.installed`, or throws a `ModelStoreError`.
    public func install(id: String) -> AsyncThrowingStream<ModelState, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performInstall(id: id, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performInstall(id: String, emit: @Sendable (ModelState) -> Void) async throws {
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard !model.sha256.isEmpty else { throw ModelStoreError.checksumUnknown(id) }
        if state(of: id) == .installed { emit(.installed); return }

        let partial = partialURL(model)
        let alreadyHave = fileSize(partial) ?? 0
        let required = model.sizeInBytes - alreadyHave + Self.reserveBytes
        let available = try freeSpace.availableBytes(at: directory)
        guard available >= required else {
            throw ModelStoreError.insufficientDiskSpace(required: required, available: available)
        }

        inProgress[id] = .downloading(bytesWritten: alreadyHave, total: model.sizeInBytes)
        defer { inProgress[id] = nil }
        do {
            try await downloader.download(model.downloadURL, to: partial) { written, _ in
                emit(.downloading(bytesWritten: written, total: model.sizeInBytes))
            }
        } catch DownloadError.offline(let written) {
            throw ModelStoreError.downloadInterrupted(bytesWritten: written)
        } catch DownloadError.cancelled {
            throw CancellationError()
        } catch {
            throw ModelStoreError.downloadFailed(String(describing: error))
        }

        inProgress[id] = .verifying
        emit(.verifying)
        let digest = try SHA256File.hexDigest(of: partial)
        guard digest == model.sha256.lowercased() else {
            try? fileManager.removeItem(at: partial)
            throw ModelStoreError.checksumMismatch
        }
        let destination = installedURL(model)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        inProgress[id] = nil
        emit(.installed)
    }

    // MARK: Remove

    public func remove(id: String) throws {
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard state(of: id) == .installed else { throw ModelStoreError.notInstalled(id) }
        let others = installedModels(role: model.role).filter { $0.id != id }
        if model.role == .speech, others.isEmpty { throw ModelStoreError.cannotRemoveOnlyModel(id) }
        try fileManager.removeItem(at: installedURL(model))
        if settings.string(forKey: Self.defaultKey(model.role)) == id || defaultModel(role: model.role) == nil {
            settings.set(others.first(where: \.isDefault)?.id ?? others.first?.id, forKey: Self.defaultKey(model.role))
        }
    }

    // MARK: Helpers

    private static func defaultKey(_ role: ModelRole) -> String { "models.default.\(role.rawValue)" }
    private func descriptor(_ id: String) -> ModelDescriptor? { catalog.first { $0.id == id } }
    private func installedURL(_ model: ModelDescriptor) -> URL { directory.appendingPathComponent(model.fileName) }
    private func partialURL(_ model: ModelDescriptor) -> URL { directory.appendingPathComponent(model.fileName + ".partial") }
    private func fileSize(_ url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }
}
```

Note for the test expectations: `remove(id: "big")` in `removeSwitchesDefault` must persist `"small"`; the branch above does so because the saved default was nil and `defaultModel` after deletion would fall back to `small`, so write it explicitly: simplify the condition to always call `settings.set(others.first(where: \.isDefault)?.id ?? others.first?.id, forKey:)` when the removed model was the effective default (`defaultModel(role:)` evaluated *before* deletion equals `model`). Implement it that way: compute `let wasDefault = defaultModel(role: model.role)?.id == id` before `removeItem`.

- [ ] **Step 5: Run the Models tests**

Run: `cd v2/VoxFlowKit && swift test --filter '^VoxFlowModelsTests\.' 2>&1 | grep -E "✔|✘|error:|Test run"`
Expected: 12 tests pass (2 catalog + 1 hash + 9 store).

- [ ] **Step 6: Commit**

```bash
git add v2/VoxFlowKit
git commit -m "feat(v2): add ModelCatalog and ModelStore with resumable verified downloads

Catalog pins turbo/small sizes and SHA-256; the store checks free space
(size + 500 MB), resumes partial downloads, verifies the checksum before
marking a model installed, enforces the remove rules and detects manual
deletion. Production downloader uses HTTP Range. Refs #108."
```

---

### Task 5: Spike under `v2/spikes/`, ADR-002, README

**Files:**
- Create: `v2/spikes/whisper-perf/Package.swift`, `v2/spikes/whisper-perf/Sources/spike/main.swift` (copied from the orchestrator's spike, with the binary target by URL + checksum instead of a local path), `v2/spikes/whisper-perf/README.md`
- Create: `v2/docs/adr/002-whisper-cpp-speech-engine.md`; modify `v2/docs/adr/README.md`
- Modify: `v2/README.md` (Layout table: `spikes/`; note that models live in Application Support)
- Modify: `v2/.gitignore` — add `spikes/**/.build/`

- [ ] **Step 1: Copy the spike and make it self-contained**

`Package.swift` uses `.binaryTarget(name: "whisper", url: "...v1.9.2...", checksum: "af74fed1…")` (same values as the package). `README.md`:

```markdown
# whisper-perf spike

Throwaway benchmark used in phase 1 (#108) to decide streaming vs batch dictation. Not built
in CI, not shipped. Run: `swift run -c release spike <model.bin> <audio-16k.wav> [threads]`.

Results 2026-09-08, M1 Max 64 GB, whisper.cpp v1.9.2, Metal, 31.7 s synthetic speech:

| Model | Load | Transcribe | RTF | Peak RSS |
|---|---|---|---|---|
| large-v3-turbo | 0.72 s | 1.98 s | 0.063 (16×) | 1.8 GB |
| small | 0.20 s | 0.75 s | 0.024 (42×) | 716 MB |
| base | 0.12 s | 0.34 s | 0.011 (94×) | 307 MB |

First run after install: ~12 s one-time Metal shader compilation. Thread count is irrelevant (GPU-bound).
```

- [ ] **Step 2: ADR-002**

`v2/docs/adr/002-whisper-cpp-speech-engine.md`:

```markdown
# ADR-002: whisper.cpp via XCFramework as the speech engine; streaming dictation is viable

Status: Accepted · Date: 2026-09-08

## Context
The design promises Whisper large-v3-turbo / small on Apple Silicon, text that appears while
speaking, and no network use except model downloads. Candidates: whisper.cpp, WhisperKit
(CoreML), Apple SpeechAnalyzer (macOS 26 only).

## Decision
- whisper.cpp, consumed as the prebuilt XCFramework from the upstream release (`binaryTarget`,
  version and checksum pinned in `Package.swift`; updates are deliberate `chore:` PRs).
- `WhisperCppEngine` is an actor that runs the C API on a private serial queue and streams
  final segments via `new_segment_callback`; cancellation goes through `abort_callback`.
- Models are ggml files downloaded on user action only, checksum-verified, stored in
  `~/Library/Application Support/VoxFlow/Models`.
- Dictation (phase 3) streams: turbo transcribes 16× faster than real time on an M1 Max, so a
  3 s window costs ~0.2 s. Batch is the fallback on slower Macs; small is the 8 GB option.

## Measurements
See `v2/spikes/whisper-perf/README.md`. Turbo: load 0.72 s, RTF 0.063, 1.8 GB RSS; small: 0.20 s,
0.024, 716 MB. First run compiles Metal shaders (~12 s once).

## Alternatives considered
- WhisperKit: faster on ANE for some models, but a second model ecosystem (CoreML bundles) and
  the owner chose ggml for both speech and the style LLM.
- Apple SpeechAnalyzer: no model choice, macOS 26 only; the Models screen would be meaningless.

## Consequences
- The XCFramework ships `parakeet.h`; Parakeet may be reachable later without a new engine.
- Language detection costs ~0.75 s with turbo; the UI must not call it per keystroke.
- The engine holds ~1.8 GB while loaded; unloading on memory pressure is a phase-3 concern.
```

Add the row `| [002](002-whisper-cpp-speech-engine.md) | whisper.cpp via XCFramework; streaming dictation viable | Accepted |` to `v2/docs/adr/README.md`.

- [ ] **Step 3: README and .gitignore**

`v2/README.md`: add `| \`spikes/\` | Throwaway benchmarks (not built in CI) |` to the Layout table and, under "Build and test", the sentence: "Integration tests that need a Whisper model look in `~/Library/Application Support/VoxFlow/Models` and skip with a reason when none is installed."
`v2/.gitignore`: add `spikes/**/.build/` under the SPM section.

- [ ] **Step 4: Full verification**

```bash
cd v2/VoxFlowKit && swift test 2>&1 | grep -E "Test run with|error:|✘"
cd .. && xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test 2>&1 | grep -E "error:|Test run with|BUILD|TEST"
```
Expected: all package suites pass (Core, Audio, Speech incl. integration, Models, plus the five remaining placeholder suites); the scheme builds and passes (the app still links only Core).

- [ ] **Step 5: Commit**

```bash
git add v2/spikes v2/docs v2/README.md v2/.gitignore
git commit -m "docs(v2): record the whisper.cpp spike and ADR-002

Benchmark numbers from the owner's M1 Max, the streaming-vs-batch decision
for phase 3, and the spike source under v2/spikes (not built in CI).
Refs #108."
```

---

### Task 6: Pull request

- [ ] Push `feature/108-v2-transcription-engine`; open the PR into `develop` per the template; map each #108 acceptance criterion; include the spike table; `Refs #108`. CI: the change touches `VoxFlowCore` → full run.
- [ ] After merge: tick #108's criteria, comment with test counts, close as completed (manual: merges into `develop` do not auto-close).

## Self-review

- **Spec coverage (section 4 + #108):** decode → T2; engine protocol + whisper.cpp + options → T1/T3; catalog/store rules (free space, resume, verify, remove, manual deletion) → T4; spike + numbers → T5; `MicrophoneSource` deliberately moved to phase 3 (#110). Qwen catalog row is data only with an unknown checksum guarded by `checksumUnknown`.
- **Placeholders:** the Qwen size/checksum is explicitly marked as pinned in phase 5 and is unreachable for install; no other TBDs. Orchestrator supplies the two fixture paths.
- **Type consistency:** `TranscriptSegment` failable init used with `!` in tests; `SegmentEvent.segment/.progress` used identically in Core, fakes, engine and tests; `ModelState` cases and `ModelStoreError` cases match between store and tests (`downloadInterrupted(bytesWritten:)`, `cannotRemoveOnlyModel`, `notInstalled(String)`, `insufficientDiskSpace(required:available:)`); settings key `models.default.speech` shared by store and tests; `FakeModelDownloader.calls[].resumedFrom` used in the resume test; `ModelStore.reserveBytes` public static.
