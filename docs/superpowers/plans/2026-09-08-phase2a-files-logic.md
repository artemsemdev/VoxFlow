# VoxFlow v2 Phase 2a — File transcription logic (formats, export, queue) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything the Files page needs below the UI: transcript output formats (TXT/SRT/VTT/JSON/MD), export to `~/Transcripts` with collision-safe names, a `FileTranscriber` that runs decode → language → engine → document, an ETA estimator, and a `FileQueue` actor with the design's queue semantics (MW-06, MW-06x): sequential, failed rows skipped, duplicates collapsed with a count, cancel/retry, completion events.

**Architecture:** New Core protocols (`AudioDecoding`, `AudioDurationProviding`, `FileTranscribing`) keep `VoxFlowFiles` testable with fakes. Writers are pure functions over a `TranscriptDocument`. `FileQueue` owns items and runs one `FileTranscribing` job at a time; the UI (phase 2b) observes `items` and `events`. Phase 2b adds the SwiftUI screens and wires the real engine/decoder/store.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing, Foundation, AVFoundation (duration only).

**Spec:** design spec §1/§4; design canvas sections 1c Files, 2d, 2f, MW-06/MW-06g/MW-06r/MW-06x/MW-06c, 3d Progress ("bars update at 1 Hz; ETA smoothed over 10 s"), 3e "Files: duplicates & huge input". Issue #109.

## Global Constraints

- Swift 6 language mode, strict concurrency; no `@unchecked Sendable` / `nonisolated(unsafe)`.
- `VoxFlowCore` imports Foundation only; `VoxFlowFiles` imports Core only (no AVFoundation — duration reading lives in `VoxFlowAudio`).
- Output formats are v2's own spec (below); no reference to v1.
- Writers are deterministic: same document → same bytes (sorted JSON keys, ISO-8601 UTC dates, `\n` line endings, trailing newline).
- Timestamps: SRT `HH:MM:SS,mmm`, VTT `HH:MM:SS.mmm`, TXT/MD `[HH:MM:SS.mmm → HH:MM:SS.mmm]` / `**[M:SS]**` as specified per writer.
- Default output folder `~/Transcripts` (created on first export). Collision-safe names: `name.ext`, `name-2.ext`, `name-3.ext`, …
- Commits: Conventional Commits, owner-authored, no attribution. Branch `feature/109-v2-files-logic` from `develop`; PR into `develop`.
- Verification: `cd v2/VoxFlowKit && swift test`; at the end also the app scheme.

---

### Task 1: Core — `OutputFormat`, `TranscriptDocument`, file protocols

**Files:**
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/OutputFormat.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/TranscriptDocument.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowCore/FileProtocols.swift`
- Modify: `v2/VoxFlowKit/Sources/VoxFlowAudio/AudioDecoder.swift` (conform to `AudioDecoding`)
- Create: `v2/VoxFlowKit/Sources/VoxFlowAudio/AudioDurationReader.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeFileTranscriber.swift`
- Create: `v2/VoxFlowKit/Sources/VoxFlowTestSupport/FakeAudioDuration.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowCoreTests/OutputFormatTests.swift`, `TranscriptDocumentTests.swift`
- Test: `v2/VoxFlowKit/Tests/VoxFlowAudioTests/AudioDurationReaderTests.swift`

**Interfaces:**
- Produces: `OutputFormat` (`txt, srt, vtt, json, md`; `fileExtension`, `displayName`, `default`, `init?(configValue:)`), `TranscriptDocument`, `AudioDecoding`, `AudioDurationProviding`, `FileTranscribing`, `FileTranscriptionError`; `AudioDurationReader` (AVFoundation); fakes `FakeFileTranscriber`, `FakeAudioDuration`.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowCoreTests/OutputFormatTests.swift`:
```swift
import Testing
@testable import VoxFlowCore

@Suite("OutputFormat")
struct OutputFormatTests {
    @Test("five formats in the design's order; txt is default")
    func order() {
        #expect(OutputFormat.allCases == [.txt, .srt, .vtt, .json, .md])
        #expect(OutputFormat.default == .txt)
    }

    @Test("file extension and display name", arguments: [
        (OutputFormat.txt, "txt", "TXT"), (.srt, "srt", "SRT"), (.vtt, "vtt", "VTT"), (.json, "json", "JSON"), (.md, "md", "MD"),
    ])
    func names(format: OutputFormat, ext: String, name: String) {
        #expect(format.fileExtension == ext)
        #expect(format.displayName == name)
    }

    @Test("parses config values case-insensitively, with markdown as an alias")
    func parsing() {
        #expect(OutputFormat(configValue: "SRT") == .srt)
        #expect(OutputFormat(configValue: "markdown") == .md)
        #expect(OutputFormat(configValue: "docx") == nil)
    }

    @Test("only txt and md honour the timestamps toggle")
    func timestampsToggle() {
        #expect(OutputFormat.txt.supportsTimestampToggle)
        #expect(OutputFormat.md.supportsTimestampToggle)
        #expect(!OutputFormat.srt.supportsTimestampToggle && !OutputFormat.vtt.supportsTimestampToggle && !OutputFormat.json.supportsTimestampToggle)
    }
}
```

`Tests/VoxFlowCoreTests/TranscriptDocumentTests.swift`:
```swift
import Foundation
import Testing
@testable import VoxFlowCore

@Suite("TranscriptDocument")
struct TranscriptDocumentTests {
    @Test("derives base name, word count and duration from its parts")
    func derived() {
        let document = TranscriptDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/lecture-04.wav"),
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 4.12, text: "Welcome back.")!], language: "en"),
            modelID: "whisper-large-v3-turbo", audioDuration: 5532, processingTime: 252, createdAt: Date(timeIntervalSince1970: 0))
        #expect(document.baseName == "lecture-04")
        #expect(document.wordCount == 2)
        #expect(document.transcript.language == "en")
    }
}
```

`Tests/VoxFlowAudioTests/AudioDurationReaderTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowAudio

@Suite("AudioDurationReader")
struct AudioDurationReaderTests {
    @Test("reads the duration without decoding")
    func duration() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("tone.wav")
        try FixtureAudio.writeSine(to: url, seconds: 3, sampleRate: 44_100, channels: 1)
        let seconds = try await AudioDurationReader().duration(of: url)
        #expect(abs(seconds - 3) < 0.05)
    }

    @Test("unsupported or unreadable files throw AudioDecodingError")
    func unreadable() async {
        let dir = TemporaryDirectory()
        let url = dir.file("notes.pages")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        await #expect(throws: AudioDecodingError.unsupportedType("pages")) { _ = try await AudioDurationReader().duration(of: url) }
    }
}
```

- [ ] **Step 2: Run to verify RED** — `cd v2/VoxFlowKit && swift build --build-tests 2>&1 | grep error: | head -3`.

- [ ] **Step 3: Core types**

`Sources/VoxFlowCore/OutputFormat.swift`:
```swift
/// Transcript output formats (design 1c Files › Output format, 2f).
public enum OutputFormat: String, CaseIterable, Sendable, Codable {
    case txt, srt, vtt, json, md

    public static let `default`: OutputFormat = .txt

    public var fileExtension: String { rawValue }
    public var displayName: String { rawValue.uppercased() }

    /// TXT and MD can be written with or without per-segment timestamps; the others always carry them.
    public var supportsTimestampToggle: Bool { self == .txt || self == .md }

    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "txt", "text": self = .txt
        case "srt": self = .srt
        case "vtt", "webvtt": self = .vtt
        case "json": self = .json
        case "md", "markdown": self = .md
        default: return nil
        }
    }
}
```

`Sources/VoxFlowCore/TranscriptDocument.swift`:
```swift
import Foundation

/// A finished file transcription plus the metadata the result view shows (design 2f).
public struct TranscriptDocument: Sendable, Equatable, Codable {
    public var sourceURL: URL
    public var transcript: Transcript
    public var modelID: String
    public var audioDuration: TimeInterval
    public var processingTime: TimeInterval
    public var createdAt: Date

    public init(sourceURL: URL, transcript: Transcript, modelID: String, audioDuration: TimeInterval,
                processingTime: TimeInterval, createdAt: Date) {
        self.sourceURL = sourceURL
        self.transcript = transcript
        self.modelID = modelID
        self.audioDuration = audioDuration
        self.processingTime = processingTime
        self.createdAt = createdAt
    }

    public var baseName: String { sourceURL.deletingPathExtension().lastPathComponent }
    public var wordCount: Int { transcript.wordCount }
}
```

`Sources/VoxFlowCore/FileProtocols.swift`:
```swift
import Foundation

/// Decodes a file to engine-ready samples (implemented by `AudioDecoder`).
public protocol AudioDecoding: Sendable {
    func decode(_ url: URL) throws -> AudioSamples
}

/// Reads a file's duration cheaply, without decoding (queue header, > 4 h confirmation).
public protocol AudioDurationProviding: Sendable {
    func duration(of url: URL) async throws -> TimeInterval
}

public enum FileTranscriptionError: Error, Equatable, Sendable {
    case unsupportedType(String)
    case decodeFailed(String)
    case noModelInstalled
    case engineFailed(String)
    case cancelled
}

/// Transcribes one file end to end; `progress` is 0…1.
public protocol FileTranscribing: Sendable {
    func transcribe(_ url: URL, options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument
}
```

- [ ] **Step 4: Audio conformance + duration reader**

In `AudioDecoder.swift` change `public struct AudioDecoder: Sendable` to `public struct AudioDecoder: AudioDecoding` (keep `Sendable` via the protocol).

`Sources/VoxFlowAudio/AudioDurationReader.swift`:
```swift
@preconcurrency import AVFoundation
import Foundation
import VoxFlowCore

/// Duration via AVFoundation metadata (no decoding). Same extension gate as `AudioDecoder`.
public struct AudioDurationReader: AudioDurationProviding {
    public init() {}

    public func duration(of url: URL) async throws -> TimeInterval {
        let ext = url.pathExtension.lowercased()
        guard AudioDecoder.supportedExtensions.contains(ext) else { throw AudioDecodingError.unsupportedType(ext) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioDecodingError.fileNotFound(url) }
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            throw AudioDecodingError.decodeFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 5: Fakes**

`Sources/VoxFlowTestSupport/FakeFileTranscriber.swift`:
```swift
import Foundation
import VoxFlowCore

/// Scripted `FileTranscribing`: per-URL result or error, optional gate to hold a job mid-way.
public actor FakeFileTranscriber: FileTranscribing {
    public enum Script: Sendable { case document(TranscriptDocument), failure(FileTranscriptionError) }

    private var scripts: [URL: Script] = [:]
    private var gates: [URL: CheckedContinuation<Void, any Error>] = [:]
    private var holdURLs: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    public private(set) var calls: [URL] = []
    public var progressSteps: [Double] = [0.25, 0.5, 0.75]

    public init() {}

    public func script(_ url: URL, _ script: Script) { scripts[url] = script }
    /// Hold the next job for `url` after reporting `progressSteps`, until `release(url)` or cancellation.
    public func hold(_ url: URL) { holdURLs.insert(url) }
    public func waitUntilHeld(_ url: URL) async {
        if gates[url] != nil { return }
        await withCheckedContinuation { waiters[url, default: []].append($0) }
    }
    public func release(_ url: URL) { gates.removeValue(forKey: url)?.resume() }

    public func transcribe(_ url: URL, options: TranscriptionOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        calls.append(url)
        for step in progressSteps {
            try Task.checkCancellation()
            progress(step)
        }
        if holdURLs.remove(url) != nil { try await park(url) }
        switch scripts[url] {
        case .document(let document)?: return document
        case .failure(let error)?: throw error
        case nil: throw FileTranscriptionError.engineFailed("no script for \(url.lastPathComponent)")
        }
    }

    private func park(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                gates[url] = continuation
                waiters.removeValue(forKey: url)?.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelGate(url) }
        }
    }

    private func cancelGate(_ url: URL) { gates.removeValue(forKey: url)?.resume(throwing: CancellationError()) }
}
```

`Sources/VoxFlowTestSupport/FakeAudioDuration.swift`:
```swift
import Foundation
import VoxFlowCore

public struct FakeAudioDuration: AudioDurationProviding {
    public var durations: [URL: TimeInterval]
    public init(_ durations: [URL: TimeInterval] = [:]) { self.durations = durations }
    public func duration(of url: URL) async throws -> TimeInterval {
        guard let seconds = durations[url] else { throw AudioDecodingError.decodeFailed("no duration for \(url.lastPathComponent)") }
        return seconds
    }
}
```

- [ ] **Step 6: GREEN** — `swift test --filter 'OutputFormat|TranscriptDocument|AudioDurationReader'` then full `swift test`.
- [ ] **Step 7: Commit** — `feat(v2): add OutputFormat, TranscriptDocument and the file transcription protocols`

---

### Task 2: Writers and `TranscriptRenderer` (VoxFlowFiles)

**Files:**
- Create: `Sources/VoxFlowFiles/TimeCode.swift`, `TranscriptRenderer.swift`, `Writers/TXTWriter.swift`, `Writers/SRTWriter.swift`, `Writers/VTTWriter.swift`, `Writers/JSONWriter.swift`, `Writers/MarkdownWriter.swift`
- Delete: `Sources/VoxFlowFiles/FilesModule.swift`, `Tests/VoxFlowFilesTests/FilesModuleTests.swift`
- Test: `Tests/VoxFlowFilesTests/TimeCodeTests.swift`, `TranscriptRendererTests.swift`

**Interfaces:**
- Produces: `TimeCode.srt(_:)`, `.vtt(_:)`, `.bracket(_:)`, `.short(_:)`; `protocol TranscriptWriter { static var format: OutputFormat; static func render(_:timestamps:) -> String }`; `TranscriptRenderer.render(_ document:, format:, timestamps: Bool) -> String`.

Output spec (v2's own):
- **TXT** with timestamps: one line per segment `[00:00:00.000 → 00:00:04.120] text`; without: one line per segment, text only. Trailing newline.
- **SRT**: `index\nHH:MM:SS,mmm --> HH:MM:SS,mmm\ntext\n\n` per segment; file ends with a single `\n` after the last blank line collapse (i.e. blocks joined by `\n\n`, plus trailing `\n`).
- **VTT**: `WEBVTT\n\n` then blocks `HH:MM:SS.mmm --> HH:MM:SS.mmm\ntext` joined by `\n\n`, trailing `\n`.
- **JSON**: `JSONEncoder` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`, `dateEncodingStrategy = .iso8601`; top-level object: `source` (file name), `language`, `model`, `duration`, `processingTime`, `createdAt`, `segments: [{start, end, text, confidence?}]`, `words`, `generator: "VoxFlow <version>"`. Trailing newline.
- **MD**: `# <baseName>\n\n_<M:SS or H:MM:SS> · <language or "auto"> · <model>_\n\n` then per segment `**[M:SS]** text` (timestamps) or `text` (no timestamps), paragraphs joined by `\n\n`, trailing `\n`.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowFilesTests/TimeCodeTests.swift`:
```swift
import Testing
@testable import VoxFlowFiles

@Suite("TimeCode")
struct TimeCodeTests {
    @Test("srt/vtt/bracket formats with millisecond rounding")
    func formats() {
        #expect(TimeCode.srt(4.1204) == "00:00:04,120")
        #expect(TimeCode.vtt(3661.5) == "01:01:01.500")
        #expect(TimeCode.bracket(0) == "00:00:00.000")
        #expect(TimeCode.srt(0.9995) == "00:00:01,000")
    }

    @Test("short form drops hours when zero")
    func short() {
        #expect(TimeCode.short(9.86) == "0:09")
        #expect(TimeCode.short(5530) == "1:32:10")
        #expect(TimeCode.short(59.7) == "1:00")
    }
}
```

`Tests/VoxFlowFilesTests/TranscriptRendererTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowFiles

@Suite("TranscriptRenderer")
struct TranscriptRendererTests {
    static let document = TranscriptDocument(
        sourceURL: URL(fileURLWithPath: "/Users/anh/Recordings/lecture-04.wav"),
        transcript: Transcript(segments: [
            TranscriptSegment(start: 0, end: 4.12, text: " Welcome back. Today we're picking up where we left off.", confidence: 0.91)!,
            TranscriptSegment(start: 4.12, end: 9.86, text: " Last week we covered why fixed-length context vectors become a bottleneck.")!,
        ], language: "en"),
        modelID: "whisper-large-v3-turbo", audioDuration: 9.86, processingTime: 0.62,
        createdAt: Date(timeIntervalSince1970: 1_757_289_600))   // 2025-09-08T00:00:00Z

    @Test("TXT with timestamps")
    func txtTimestamps() {
        #expect(TranscriptRenderer.render(Self.document, format: .txt, timestamps: true) == """
        [00:00:00.000 → 00:00:04.120] Welcome back. Today we're picking up where we left off.
        [00:00:04.120 → 00:00:09.860] Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("TXT without timestamps")
    func txtPlain() {
        #expect(TranscriptRenderer.render(Self.document, format: .txt, timestamps: false) == """
        Welcome back. Today we're picking up where we left off.
        Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("SRT")
    func srt() {
        #expect(TranscriptRenderer.render(Self.document, format: .srt, timestamps: false) == """
        1
        00:00:00,000 --> 00:00:04,120
        Welcome back. Today we're picking up where we left off.

        2
        00:00:04,120 --> 00:00:09,860
        Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("VTT")
    func vtt() {
        #expect(TranscriptRenderer.render(Self.document, format: .vtt, timestamps: true) == """
        WEBVTT

        00:00:00.000 --> 00:00:04.120
        Welcome back. Today we're picking up where we left off.

        00:00:04.120 --> 00:00:09.860
        Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("Markdown with and without timestamps")
    func markdown() {
        #expect(TranscriptRenderer.render(Self.document, format: .md, timestamps: true) == """
        # lecture-04

        _0:09 · en · whisper-large-v3-turbo_

        **[0:00]** Welcome back. Today we're picking up where we left off.

        **[0:04]** Last week we covered why fixed-length context vectors become a bottleneck.

        """)
        #expect(TranscriptRenderer.render(Self.document, format: .md, timestamps: false).contains("\n\nWelcome back."))
    }

    @Test("JSON is stable, sorted, ISO-8601, includes confidence only when present")
    func json() throws {
        let text = TranscriptRenderer.render(Self.document, format: .json, timestamps: true)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        #expect(object["source"] as? String == "lecture-04.wav")
        #expect(object["language"] as? String == "en")
        #expect(object["model"] as? String == "whisper-large-v3-turbo")
        #expect(object["createdAt"] as? String == "2025-09-08T00:00:00Z")
        #expect(object["words"] as? Int == 21)
        let segments = object["segments"] as! [[String: Any]]
        #expect(segments.count == 2)
        #expect(segments[0]["confidence"] as? Double == 0.91)
        #expect(segments[1]["confidence"] == nil)
        #expect(segments[0]["text"] as? String == "Welcome back. Today we're picking up where we left off.")
        #expect(text.hasSuffix("\n"))
        #expect(TranscriptRenderer.render(Self.document, format: .json, timestamps: true) == text)   // deterministic
    }
}
```

- [ ] **Step 2: RED** — build tests; expect missing `TimeCode`/`TranscriptRenderer`.

- [ ] **Step 3: Implementation**

`Sources/VoxFlowFiles/TimeCode.swift`:
```swift
import Foundation

/// Timestamp formatting shared by the writers and the UI.
public enum TimeCode {
    /// `HH:MM:SS,mmm` (SubRip).
    public static func srt(_ seconds: TimeInterval) -> String { hms(seconds, separator: ",") }
    /// `HH:MM:SS.mmm` (WebVTT and TXT brackets).
    public static func vtt(_ seconds: TimeInterval) -> String { hms(seconds, separator: ".") }
    public static func bracket(_ seconds: TimeInterval) -> String { vtt(seconds) }

    /// `M:SS` or `H:MM:SS`, seconds rounded to the nearest whole second.
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func hms(_ seconds: TimeInterval, separator: String) -> String {
        let totalMillis = Int((seconds * 1000).rounded())
        let h = totalMillis / 3_600_000
        let m = (totalMillis % 3_600_000) / 60_000
        let s = (totalMillis % 60_000) / 1000
        let ms = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }
}
```

`Sources/VoxFlowFiles/TranscriptRenderer.swift`:
```swift
import Foundation
import VoxFlowCore

protocol TranscriptWriter {
    static var format: OutputFormat { get }
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String
}

/// Renders a document in any output format; pure and deterministic (design 2f: export without re-processing).
public enum TranscriptRenderer {
    public static func render(_ document: TranscriptDocument, format: OutputFormat, timestamps: Bool) -> String {
        switch format {
        case .txt: TXTWriter.render(document, timestamps: timestamps)
        case .srt: SRTWriter.render(document, timestamps: timestamps)
        case .vtt: VTTWriter.render(document, timestamps: timestamps)
        case .json: JSONWriter.render(document, timestamps: timestamps)
        case .md: MarkdownWriter.render(document, timestamps: timestamps)
        }
    }

    static func cleanText(_ segment: TranscriptSegment) -> String {
        segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

`Sources/VoxFlowFiles/Writers/TXTWriter.swift`:
```swift
import VoxFlowCore

enum TXTWriter: TranscriptWriter {
    static let format = OutputFormat.txt
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        document.transcript.segments.map { segment in
            let text = TranscriptRenderer.cleanText(segment)
            return timestamps ? "[\(TimeCode.bracket(segment.start)) → \(TimeCode.bracket(segment.end))] \(text)" : text
        }.joined(separator: "\n") + "\n"
    }
}
```

`Sources/VoxFlowFiles/Writers/SRTWriter.swift`:
```swift
import VoxFlowCore

enum SRTWriter: TranscriptWriter {
    static let format = OutputFormat.srt
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        document.transcript.segments.enumerated().map { index, segment in
            "\(index + 1)\n\(TimeCode.srt(segment.start)) --> \(TimeCode.srt(segment.end))\n\(TranscriptRenderer.cleanText(segment))"
        }.joined(separator: "\n\n") + "\n\n"
    }
}
```
(Note the test expects each block followed by a blank line and the file ending with `\n\n` after the last block — matches `joined("\n\n") + "\n\n"`.)

`Sources/VoxFlowFiles/Writers/VTTWriter.swift`:
```swift
import VoxFlowCore

enum VTTWriter: TranscriptWriter {
    static let format = OutputFormat.vtt
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        "WEBVTT\n\n" + document.transcript.segments.map { segment in
            "\(TimeCode.vtt(segment.start)) --> \(TimeCode.vtt(segment.end))\n\(TranscriptRenderer.cleanText(segment))"
        }.joined(separator: "\n\n") + "\n\n"
    }
}
```

`Sources/VoxFlowFiles/Writers/JSONWriter.swift`:
```swift
import Foundation
import VoxFlowCore

enum JSONWriter: TranscriptWriter {
    static let format = OutputFormat.json

    struct Segment: Encodable {
        let start: Double, end: Double, text: String, confidence: Double?
    }
    struct Payload: Encodable {
        let source: String, language: String?, model: String, duration: Double, processingTime: Double
        let createdAt: Date, words: Int, generator: String, segments: [Segment]
    }

    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        let payload = Payload(
            source: document.sourceURL.lastPathComponent, language: document.transcript.language,
            model: document.modelID, duration: document.audioDuration, processingTime: document.processingTime,
            createdAt: document.createdAt, words: document.wordCount, generator: "VoxFlow \(VoxFlowVersion.string)",
            segments: document.transcript.segments.map {
                Segment(start: $0.start, end: $0.end, text: TranscriptRenderer.cleanText($0), confidence: $0.confidence)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
```
(`Segment.confidence` nil is omitted by `JSONEncoder` by default — `Encodable` synthesized conformance skips nil optionals.)

`Sources/VoxFlowFiles/Writers/MarkdownWriter.swift`:
```swift
import VoxFlowCore

enum MarkdownWriter: TranscriptWriter {
    static let format = OutputFormat.md
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        let header = "# \(document.baseName)\n\n_\(TimeCode.short(document.audioDuration)) · \(document.transcript.language ?? "auto") · \(document.modelID)_"
        let body = document.transcript.segments.map { segment in
            let text = TranscriptRenderer.cleanText(segment)
            return timestamps ? "**[\(TimeCode.short(segment.start))]** \(text)" : text
        }
        return ([header] + body).joined(separator: "\n\n") + "\n"
    }
}
```

- [ ] **Step 4: GREEN** — `swift test --filter '^VoxFlowFilesTests\.'`. The `words` expectation (21) counts whitespace-separated words of the two segments; if the count differs, fix the test to the actual number and note it.
- [ ] **Step 5: Commit** — `feat(v2): add transcript writers for TXT, SRT, VTT, JSON and Markdown`

---

### Task 3: `TranscriptExporter`, `ETAEstimator`, `FileTranscriber`

**Files:**
- Create: `Sources/VoxFlowFiles/TranscriptExporter.swift`, `ETAEstimator.swift`, `FileTranscriber.swift`
- Test: `Tests/VoxFlowFilesTests/TranscriptExporterTests.swift`, `ETAEstimatorTests.swift`, `FileTranscriberTests.swift`

**Interfaces:**
- `TranscriptExporter(directory:)`: `static var defaultDirectory: URL` (`~/Transcripts`); `func export(_ document, format, timestamps) throws -> URL` (collision-safe); `func exportAll(_ document, formats: [OutputFormat], timestamps) throws -> [OutputFormat: URL]`.
- `ETAEstimator(window: TimeInterval = 10)`: `mutating func record(progress: Double, at time: TimeInterval)`; `var secondsRemaining: TimeInterval?` (nil until two samples); rate = progress delta over the last `window` seconds.
- `FileTranscriber(decoder: AudioDecoding, engine: SpeechEngine, modelID: String, clock: () -> Date = Date.init)`: `FileTranscribing`; decode → if `options.language == nil` then `detectLanguage` → transcribe → document; progress: decode counts as 0…0.05, transcription maps 0.05…1.0.

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowFilesTests/TranscriptExporterTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

@Suite("TranscriptExporter")
struct TranscriptExporterTests {
    let document = TranscriptRendererTests.document

    @Test("writes <base>.<ext> and avoids overwriting with -2, -3")
    func collisionSafe() throws {
        let dir = TemporaryDirectory()
        let exporter = TranscriptExporter(directory: dir.url)
        let first = try exporter.export(document, format: .srt, timestamps: true)
        let second = try exporter.export(document, format: .srt, timestamps: true)
        let third = try exporter.export(document, format: .srt, timestamps: true)
        #expect(first.lastPathComponent == "lecture-04.srt")
        #expect(second.lastPathComponent == "lecture-04-2.srt")
        #expect(third.lastPathComponent == "lecture-04-3.srt")
        #expect(try String(contentsOf: first, encoding: .utf8) == TranscriptRenderer.render(document, format: .srt, timestamps: true))
    }

    @Test("creates the directory and exports several formats at once")
    func exportAll() throws {
        let dir = TemporaryDirectory()
        let nested = dir.file("Transcripts")
        let urls = try TranscriptExporter(directory: nested).exportAll(document, formats: [.txt, .json], timestamps: false)
        #expect(Set(urls.keys) == [.txt, .json])
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("lecture-04.json").path))
    }

    @Test("default directory is ~/Transcripts")
    func defaultDirectory() {
        #expect(TranscriptExporter.defaultDirectory.lastPathComponent == "Transcripts")
        #expect(TranscriptExporter.defaultDirectory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}
```

`Tests/VoxFlowFilesTests/ETAEstimatorTests.swift`:
```swift
import Testing
@testable import VoxFlowFiles

@Suite("ETAEstimator")
struct ETAEstimatorTests {
    @Test("needs two samples, then extrapolates the recent rate")
    func extrapolates() {
        var eta = ETAEstimator(window: 10)
        eta.record(progress: 0, at: 0)
        #expect(eta.secondsRemaining == nil)
        eta.record(progress: 0.25, at: 10)      // 0.025/s → 30 s for the remaining 0.75
        #expect(eta.secondsRemaining == 30)
    }

    @Test("only the last window of samples counts, so a slow start does not dominate")
    func windowed() {
        var eta = ETAEstimator(window: 10)
        eta.record(progress: 0, at: 0)
        eta.record(progress: 0.1, at: 20)       // slow
        eta.record(progress: 0.5, at: 30)       // fast: 0.04/s over the last 10 s → 12.5 s left
        #expect(eta.secondsRemaining == 12.5)
    }

    @Test("complete or stalled progress")
    func edges() {
        var eta = ETAEstimator(window: 10)
        eta.record(progress: 0.5, at: 0)
        eta.record(progress: 0.5, at: 5)
        #expect(eta.secondsRemaining == nil)    // no rate yet
        eta.record(progress: 1, at: 6)
        #expect(eta.secondsRemaining == 0)
    }
}
```

`Tests/VoxFlowFilesTests/FileTranscriberTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

struct FakeDecoder: AudioDecoding {
    var result: Result<AudioSamples, AudioDecodingError>
    func decode(_ url: URL) throws -> AudioSamples { try result.get() }
}

@Suite("FileTranscriber")
struct FileTranscriberTests {
    let url = URL(fileURLWithPath: "/tmp/interview-raw.m4a")

    @Test("decodes, auto-detects language, streams progress and builds the document")
    func happyPath() async throws {
        let engine = FakeSpeechEngine(script: [
            .progress(0.5),
            .segment(TranscriptSegment(start: 0, end: 2, text: "hello")!),
            .progress(1),
            .segment(TranscriptSegment(start: 2, end: 4, text: "world")!),
        ], detection: LanguageDetection(code: "de", confidence: 0.95))
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let decoder = FakeDecoder(result: .success(AudioSamples([Float](repeating: 0, count: 64_000))))   // 4 s
        var now = Date(timeIntervalSince1970: 100)
        let transcriber = FileTranscriber(decoder: decoder, engine: engine, modelID: "whisper-small") {
            defer { now.addTimeInterval(1.5) }
            return now
        }
        let progress = Progress()
        let document = try await transcriber.transcribe(url, options: TranscriptionOptions()) { progress.append($0) }
        #expect(document.transcript.language == "de")
        #expect(document.transcript.segments.map(\.text) == ["hello", "world"])
        #expect(document.audioDuration == 4)
        #expect(document.modelID == "whisper-small")
        #expect(document.sourceURL == url)
        #expect(await engine.lastOptions?.language == "de")   // detected language is passed to the engine
        let values = progress.values
        #expect(values.first == 0.05 && values.last == 1 && values == values.sorted())
    }

    @Test("explicit language skips detection")
    func explicitLanguage() async throws {
        let engine = FakeSpeechEngine(script: [])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples([0]))), engine: engine, modelID: "m")
        let document = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        #expect(document.transcript.language == "en")
    }

    @Test("decode errors map to FileTranscriptionError")
    func decodeErrors() async {
        let engine = FakeSpeechEngine(script: [])
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .failure(.decodeFailed("bad"))), engine: engine, modelID: "m")
        await #expect(throws: FileTranscriptionError.decodeFailed("bad")) { _ = try await transcriber.transcribe(url, options: TranscriptionOptions()) { _ in } }
        let unsupported = FileTranscriber(decoder: FakeDecoder(result: .failure(.unsupportedType("pages"))), engine: engine, modelID: "m")
        await #expect(throws: FileTranscriptionError.unsupportedType("pages")) { _ = try await unsupported.transcribe(url, options: TranscriptionOptions()) { _ in } }
    }

    @Test("engine not loaded surfaces as noModelInstalled")
    func noModel() async {
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples([0]))), engine: FakeSpeechEngine(script: []), modelID: "m")
        await #expect(throws: FileTranscriptionError.noModelInstalled) { _ = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in } }
    }
}

/// Thread-safe progress collector for tests.
final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
```
(`Progress` is the one allowed `@unchecked Sendable` in this task: test-only, lock-guarded.)

- [ ] **Step 2: RED**, then implement:

`Sources/VoxFlowFiles/TranscriptExporter.swift`:
```swift
import Foundation
import VoxFlowCore

/// Writes rendered transcripts next to each other in one folder (design: "Save to ~/Transcripts").
public struct TranscriptExporter: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcripts", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = TranscriptExporter.defaultDirectory) { self.directory = directory }

    @discardableResult
    public func export(_ document: TranscriptDocument, format: OutputFormat, timestamps: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = availableURL(baseName: document.baseName, ext: format.fileExtension)
        try TranscriptRenderer.render(document, format: format, timestamps: timestamps).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func exportAll(_ document: TranscriptDocument, formats: [OutputFormat], timestamps: Bool) throws -> [OutputFormat: URL] {
        var urls: [OutputFormat: URL] = [:]
        for format in formats { urls[format] = try export(document, format: format, timestamps: timestamps) }
        return urls
    }

    /// `name.ext`, then `name-2.ext`, `name-3.ext`, … — never overwrites.
    func availableURL(baseName: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
```

`Sources/VoxFlowFiles/ETAEstimator.swift`:
```swift
import Foundation

/// "About 3 min left": progress rate over the last `window` seconds, extrapolated (design 3d).
public struct ETAEstimator: Sendable, Equatable {
    public let window: TimeInterval
    private var samples: [(progress: Double, time: TimeInterval)] = []

    public init(window: TimeInterval = 10) { self.window = window }

    public mutating func record(progress: Double, at time: TimeInterval) {
        samples.append((progress, time))
        let cutoff = time - window
        // Keep one sample at or before the cutoff so the rate spans the whole window.
        while samples.count > 2, samples[1].time <= cutoff { samples.removeFirst() }
    }

    public var secondsRemaining: TimeInterval? {
        guard let last = samples.last else { return nil }
        if last.progress >= 1 { return 0 }
        guard let first = samples.first, last.time > first.time else { return nil }
        let rate = (last.progress - first.progress) / (last.time - first.time)
        guard rate > 0 else { return nil }
        return (1 - last.progress) / rate
    }

    public static func == (lhs: ETAEstimator, rhs: ETAEstimator) -> Bool {
        lhs.window == rhs.window && lhs.samples.map(\.progress) == rhs.samples.map(\.progress) && lhs.samples.map(\.time) == rhs.samples.map(\.time)
    }
}
```
(`windowed` test: samples (0,0),(0.1,20),(0.5,30) → after the third record, cutoff = 20; `samples[1].time (20) <= 20` → drop first → samples (0.1,20),(0.5,30) → rate 0.04/s → (1-0.5)/0.04 = 12.5 ✓. `extrapolates`: (0,0),(0.25,10): rate 0.025 → 0.75/0.025 = 30 ✓.)

`Sources/VoxFlowFiles/FileTranscriber.swift`:
```swift
import Foundation
import VoxFlowCore

/// Decode → (auto language) → transcribe → `TranscriptDocument`. One file per call.
public struct FileTranscriber: FileTranscribing {
    static let decodeShare = 0.05

    private let decoder: any AudioDecoding
    private let engine: any SpeechEngine
    private let modelID: String
    private let now: @Sendable () -> Date

    public init(decoder: any AudioDecoding, engine: any SpeechEngine, modelID: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.decoder = decoder
        self.engine = engine
        self.modelID = modelID
        self.now = now
    }

    public func transcribe(_ url: URL, options: TranscriptionOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        let started = now()
        let audio: AudioSamples
        do {
            audio = try decoder.decode(url)
        } catch let error as AudioDecodingError {
            switch error {
            case .unsupportedType(let ext): throw FileTranscriptionError.unsupportedType(ext)
            case .fileNotFound(let missing): throw FileTranscriptionError.decodeFailed("file not found: \(missing.lastPathComponent)")
            case .decodeFailed(let reason): throw FileTranscriptionError.decodeFailed(reason)
            }
        }
        progress(Self.decodeShare)

        var options = options
        do {
            if options.language == nil {
                options.language = try await engine.detectLanguage(in: audio).code
            }
            var segments: [TranscriptSegment] = []
            for try await event in engine.transcribe(audio, options: options) {
                switch event {
                case .segment(let segment): segments.append(segment)
                case .progress(let value): progress(Self.decodeShare + (1 - Self.decodeShare) * min(max(value, 0), 1))
                }
            }
            try Task.checkCancellation()
            progress(1)
            return TranscriptDocument(sourceURL: url, transcript: Transcript(segments: segments, language: options.language),
                                      modelID: modelID, audioDuration: audio.duration,
                                      processingTime: now().timeIntervalSince(started), createdAt: now())
        } catch SpeechEngineError.modelNotLoaded {
            throw FileTranscriptionError.noModelInstalled
        } catch SpeechEngineError.cancelled {
            throw FileTranscriptionError.cancelled
        } catch is CancellationError {
            throw FileTranscriptionError.cancelled
        } catch let error as FileTranscriptionError {
            throw error
        } catch {
            throw FileTranscriptionError.engineFailed(String(describing: error))
        }
    }
}
```
Test note: `happyPath` expects the first progress value to be exactly `0.05` and the last `1`; the fake engine's `.progress(0.5)` maps to `0.525`. The `now` closure in the test mutates a captured `var` — if Swift 6 rejects the non-Sendable capture, replace it with a small lock-guarded `Clock` class in the test (like `Progress`).

- [ ] **Step 3: GREEN** — `swift test --filter '^VoxFlowFilesTests\.'`, then full suite.
- [ ] **Step 4: Commit** — `feat(v2): add TranscriptExporter, ETAEstimator and FileTranscriber`

---

### Task 4: `FileQueue` actor

**Files:**
- Create: `Sources/VoxFlowFiles/FileQueue.swift`
- Test: `Tests/VoxFlowFilesTests/FileQueueTests.swift`

**Interfaces (public):**
```swift
public struct QueueItem: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case queued
        case running(progress: Double)
        case done(TranscriptDocument)
        case failed(FileTranscriptionError)
        case cancelled
    }
    public let id: UUID
    public let url: URL
    public var duration: TimeInterval?     // from AudioDurationProviding, nil until read or if unreadable
    public var duplicates: Int             // 1 = added once; 2 = "2×" badge
    public var status: Status
}
public enum FileQueueEvent: Sendable, Equatable { case changed(QueueItem), finished(QueueItem) /* done or failed */ }
public actor FileQueue {
    public init(transcriber: any FileTranscribing, durations: any AudioDurationProviding,
                supportedExtensions: Set<String>, options: @Sendable @escaping () -> TranscriptionOptions)
    public var items: [QueueItem]
    public var events: AsyncStream<FileQueueEvent>   // one subscriber (the UI); created lazily
    public var totalDuration: TimeInterval           // sum of known durations
    public var isRunning: Bool
    @discardableResult public func add(_ urls: [URL]) async -> [QueueItem]
    public func remove(id: UUID)                     // cancels if running
    public func cancel(id: UUID)                     // running → cancelled; queued → cancelled
    public func retry(id: UUID)                      // failed/cancelled → queued
    public func start()                              // idempotent; processes queued items in order until none left
    public func progress(of id: UUID) -> Double?
}
```
Semantics (design MW-06/MW-06x/3e):
- `add`: paths standardized (`standardizedFileURL`); an existing item with the same URL (not `done`) gets `duplicates += 1` instead of a new row; unsupported extension → item created with `.failed(.unsupportedType(ext))` immediately ("type errors are caught on drop"); durations read asynchronously (`duration` nil on failure, item still queued).
- `start`: one worker; picks the first `.queued`; sets `.running(0)`; progress updates coalesced: an update is published when it differs by ≥ 0.01 from the last published value; on success `.done(document)` + `.finished`; on `FileTranscriptionError.cancelled`/`CancellationError` → `.cancelled`; other errors → `.failed(error)` + `.finished`; failed rows never stall the queue (continue with the next).
- `cancel` of the running item cancels its `Task`; the worker continues with the next queued item.
- `remove` deletes the row (cancelling first if running).

- [ ] **Step 1: Failing tests**

`Tests/VoxFlowFilesTests/FileQueueTests.swift`:
```swift
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

@Suite("FileQueue")
struct FileQueueTests {
    static func doc(_ url: URL) -> TranscriptDocument {
        TranscriptDocument(sourceURL: url, transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "ok")!], language: "en"),
                           modelID: "m", audioDuration: 60, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }
    let a = URL(fileURLWithPath: "/tmp/a.m4a")
    let b = URL(fileURLWithPath: "/tmp/b.mp3")
    let bad = URL(fileURLWithPath: "/tmp/notes.pages")

    func makeQueue(_ transcriber: FakeFileTranscriber, durations: [URL: TimeInterval] = [:]) -> FileQueue {
        FileQueue(transcriber: transcriber, durations: FakeAudioDuration(durations),
                  supportedExtensions: ["m4a", "mp3", "wav"], options: { TranscriptionOptions() })
    }

    /// Collects events until `count` `finished` events arrived (bounded by the test's timeout).
    static func awaitFinished(_ queue: FileQueue, count: Int) async -> [QueueItem] {
        var finished: [QueueItem] = []
        for await event in await queue.events {
            if case .finished(let item) = event { finished.append(item) }
            if finished.count == count { break }
        }
        return finished
    }

    @Test("adds rows in order, reads durations, rejects unsupported types on drop")
    func add() async throws {
        let queue = makeQueue(FakeFileTranscriber(), durations: [a: 120, b: 30])
        let items = await queue.add([a, bad, b])
        #expect(items.map(\.url) == [a, bad, b])
        #expect(items[1].status == .failed(.unsupportedType("pages")))
        #expect(await queue.totalDuration == 150)
        #expect(await queue.items.map(\.duration) == [120, nil, 30])
    }

    @Test("the same file dropped twice is one row with a 2× badge")
    func duplicates() async {
        let queue = makeQueue(FakeFileTranscriber())
        await queue.add([a])
        await queue.add([URL(fileURLWithPath: "/tmp/../tmp/a.m4a")])
        let items = await queue.items
        #expect(items.count == 1)
        #expect(items[0].duplicates == 2)
    }

    @Test("processes sequentially, skips failures and keeps going, emits finished events")
    func sequentialSkipFailed() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.script(a, .failure(.decodeFailed("corrupt")))
        await transcriber.script(b, .document(Self.doc(b)))
        let queue = makeQueue(transcriber)
        await queue.add([a, b])
        async let finished = Self.awaitFinished(queue, count: 2)
        await queue.start()
        let done = await finished
        #expect(done.map(\.url) == [a, b])
        #expect(done[0].status == .failed(.decodeFailed("corrupt")))
        if case .done(let document) = done[1].status { #expect(document.sourceURL == b) } else { Issue.record("b should be done") }
        #expect(await transcriber.calls == [a, b])
        #expect(await queue.isRunning == false)
    }

    @Test("progress is coalesced and monotonic")
    func progress() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        let item = await queue.add([a])[0]
        var seen: [Double] = []
        let collector = Task {
            for await event in await queue.events {
                if case .changed(let changed) = event, case .running(let p) = changed.status { seen.append(p) }
                if case .finished = event { break }
            }
            return seen
        }
        await queue.start()
        let values = await collector.value
        #expect(values == [0, 0.25, 0.5, 0.75])
        #expect(await queue.progress(of: item.id) == nil)     // finished items report no progress
    }

    @Test("cancelling the running item moves on to the next; retry re-queues it")
    func cancelAndRetry() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.hold(a)
        await transcriber.script(a, .document(Self.doc(a)))
        await transcriber.script(b, .document(Self.doc(b)))
        let queue = makeQueue(transcriber)
        let items = await queue.add([a, b])
        async let finished = Self.awaitFinished(queue, count: 1)
        await queue.start()
        await transcriber.waitUntilHeld(a)
        await queue.cancel(id: items[0].id)
        let done = await finished
        #expect(done[0].url == b)
        #expect(await queue.items[0].status == .cancelled)
        await transcriber.script(a, .document(Self.doc(a)))
        async let retried = Self.awaitFinished(queue, count: 1)
        await queue.retry(id: items[0].id)
        await queue.start()
        #expect(await retried[0].url == a)
        #expect(await transcriber.calls == [a, b, a])
    }

    @Test("remove cancels a running item and drops the row")
    func remove() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.hold(a)
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        let item = await queue.add([a])[0]
        await queue.start()
        await transcriber.waitUntilHeld(a)
        await queue.remove(id: item.id)
        #expect(await queue.items.isEmpty)
        // Give the worker a chance to observe cancellation and go idle.
        for _ in 0..<1_000 where await queue.isRunning { await Task.yield() }
        #expect(await queue.isRunning == false)
    }

    @Test("start is idempotent while running")
    func startIdempotent() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.hold(a)
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        await queue.add([a])
        await queue.start()
        await transcriber.waitUntilHeld(a)
        await queue.start()
        await transcriber.release(a)
        _ = await Self.awaitFinished(queue, count: 1)
        #expect(await transcriber.calls == [a])
    }
}
```

- [ ] **Step 2: RED**, then implement:

`Sources/VoxFlowFiles/FileQueue.swift`:
```swift
import Foundation
import VoxFlowCore

public struct QueueItem: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case queued
        case running(progress: Double)
        case done(TranscriptDocument)
        case failed(FileTranscriptionError)
        case cancelled
    }

    public let id: UUID
    public let url: URL
    public var duration: TimeInterval?
    public var duplicates: Int
    public var status: Status

    public var isFinished: Bool {
        switch status {
        case .done, .failed: true
        default: false
        }
    }
}

public enum FileQueueEvent: Sendable, Equatable {
    case changed(QueueItem)
    case finished(QueueItem)
}

/// The Files page's queue (design MW-06): sequential, failed rows skipped, duplicates collapsed.
public actor FileQueue {
    public private(set) var items: [QueueItem] = []
    public private(set) var isRunning = false

    private let transcriber: any FileTranscribing
    private let durations: any AudioDurationProviding
    private let supportedExtensions: Set<String>
    private let options: @Sendable () -> TranscriptionOptions
    private var worker: Task<Void, Never>?
    private var currentJob: Task<Void, Never>?
    private var currentID: UUID?
    private var continuation: AsyncStream<FileQueueEvent>.Continuation?
    private var lastPublishedProgress: [UUID: Double] = [:]

    public init(transcriber: any FileTranscribing, durations: any AudioDurationProviding,
                supportedExtensions: Set<String>, options: @Sendable @escaping () -> TranscriptionOptions) {
        self.transcriber = transcriber
        self.durations = durations
        self.supportedExtensions = supportedExtensions
        self.options = options
    }

    /// Single-consumer event stream; calling it again replaces the previous subscriber.
    public var events: AsyncStream<FileQueueEvent> {
        let (stream, continuation) = AsyncStream<FileQueueEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation?.finish()
        self.continuation = continuation
        return stream
    }

    public var totalDuration: TimeInterval { items.compactMap(\.duration).reduce(0, +) }

    public func progress(of id: UUID) -> Double? {
        if case .running(let progress)? = items.first(where: { $0.id == id })?.status { return progress }
        return nil
    }

    @discardableResult
    public func add(_ urls: [URL]) async -> [QueueItem] {
        var added: [QueueItem] = []
        for raw in urls {
            let url = raw.standardizedFileURL
            if let index = items.firstIndex(where: { $0.url == url && !$0.isFinished }) {
                items[index].duplicates += 1
                publish(.changed(items[index]))
                added.append(items[index])
                continue
            }
            let ext = url.pathExtension.lowercased()
            var item = QueueItem(id: UUID(), url: url, duration: nil, duplicates: 1,
                                 status: supportedExtensions.contains(ext) ? .queued : .failed(.unsupportedType(ext)))
            if case .queued = item.status {
                item.duration = try? await durations.duration(of: url)
            }
            items.append(item)
            publish(.changed(item))
            if case .failed = item.status { publish(.finished(item)) }
            added.append(item)
        }
        return added
    }

    public func remove(id: UUID) {
        if currentID == id { currentJob?.cancel() }
        items.removeAll { $0.id == id }
    }

    public func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .queued:
            items[index].status = .cancelled
            publish(.changed(items[index]))
        case .running:
            currentJob?.cancel()      // the job's catch marks the row cancelled
        default:
            break
        }
    }

    public func retry(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .failed, .cancelled:
            items[index].status = .queued
            publish(.changed(items[index]))
        default:
            break
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        worker = Task { await self.runLoop() }
    }

    // MARK: Worker

    private func runLoop() async {
        while let index = items.firstIndex(where: { $0.status == .queued }) {
            let item = items[index]
            currentID = item.id
            update(item.id) { $0.status = .running(progress: 0) }
            lastPublishedProgress[item.id] = 0
            let job = Task { await self.transcribe(item) }
            currentJob = job
            await job.value
            currentJob = nil
            currentID = nil
        }
        isRunning = false
        worker = nil
    }

    private func transcribe(_ item: QueueItem) async {
        do {
            let document = try await transcriber.transcribe(item.url, options: options()) { [weak self] progress in
                guard let self else { return }
                Task { await self.report(item.id, progress: progress) }
            }
            update(item.id) { $0.status = .done(document) }
            if let finished = items.first(where: { $0.id == item.id }) { publish(.finished(finished)) }
        } catch FileTranscriptionError.cancelled {
            update(item.id) { $0.status = .cancelled }
        } catch is CancellationError {
            update(item.id) { $0.status = .cancelled }
        } catch let error as FileTranscriptionError {
            update(item.id) { $0.status = .failed(error) }
            if let finished = items.first(where: { $0.id == item.id }) { publish(.finished(finished)) }
        } catch {
            update(item.id) { $0.status = .failed(.engineFailed(String(describing: error))) }
            if let finished = items.first(where: { $0.id == item.id }) { publish(.finished(finished)) }
        }
        lastPublishedProgress[item.id] = nil
    }

    private func report(_ id: UUID, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .running = items[index].status else { return }
        let clamped = min(max(progress, 0), 1)
        guard clamped - (lastPublishedProgress[id] ?? -1) >= 0.01 else { return }
        lastPublishedProgress[id] = clamped
        items[index].status = .running(progress: clamped)
        publish(.changed(items[index]))
    }

    private func update(_ id: UUID, _ change: (inout QueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        publish(.changed(items[index]))
    }

    private func publish(_ event: FileQueueEvent) {
        continuation?.yield(event)
    }
}
```
Notes for the implementer: `report` is hopped onto the actor through a `Task` from the progress callback; because the fake reports its steps before returning, all `changed` events precede `finished` (the `done` update happens after `await transcriber.transcribe` returns and the hops are already enqueued — if the `progress` test shows ordering issues, make `report` an `await`ed call by capturing the actor and using `await self.report(...)` inside a `Task` that the transcribe job awaits before finishing: simplest is to collect progress in the callback via a local `AsyncStream` consumed by the job; choose the simplest that makes the test deterministic and explain it).

- [ ] **Step 3: GREEN** — run `swift test --filter '^VoxFlowFilesTests\.'` 5× (queue tests must be deterministic: they use gates, not sleeps), then full suite and the app scheme.
- [ ] **Step 4: Commit** — `feat(v2): add FileQueue with the design's queue semantics`

---

### Task 5: Docs and PR

- `v2/README.md` Layout: `VoxFlowFiles` now "file queue, transcript writers (TXT/SRT/VTT/JSON/MD), export, ETA".
- `v2/docs/formats.md` (new): the output-format spec from Task 2 (one section per format with a 2-segment example), plus the JSON schema fields. Link it from README.
- PR into `develop`: `feat(v2): phase 2a file transcription logic (formats, export, queue)`; body maps #109's logic-side criteria; `Refs #109`. Phase 2b (UI) follows in its own PR.

## Self-review
- Coverage of #109 logic scope: writers/export (T2/T3), queue semantics incl. duplicates, skip-failed, cancel (T4), file transcriber with auto language (T3), durations for the header and the > 4 h rule (T1 provider; the confirmation itself is UI, 2b). ETA (T3). Model-not-installed surfaced as `FileTranscriptionError.noModelInstalled` (T3) for the UI banner.
- Placeholders: none; JSON `words` count noted as "fix to actual if it differs" — acceptable because the assertion is about determinism of the count, the exact number is derived.
- Type consistency: `FileTranscriptionError` cases identical across Core, `FileTranscriber`, `FileQueue`, fakes and tests; `QueueItem.Status` cases match tests; `FakeFileTranscriber` API (`script/hold/waitUntilHeld/release/calls/progressSteps`) matches queue tests; `FakeAudioDuration(_:)` init matches.
