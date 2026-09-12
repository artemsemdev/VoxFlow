import Foundation
import Observation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

final class FakePasteboard: Pasteboard {
    private(set) var strings: [String] = []
    func setString(_ string: String) { strings.append(string) }
}

final class FakeRevealer: FileRevealing {
    private(set) var revealed: [URL] = []
    func reveal(_ url: URL) { revealed.append(url) }
}

@Suite("ResultViewModel") @MainActor
struct ResultViewModelTests {
    static func smallDoc() -> TranscriptDocument {
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello there")!,
            TranscriptSegment(start: 2, end: 5, text: "This needs your attention")!,
            TranscriptSegment(start: 5, end: 8, text: "Goodbye now")!,
        ]
        return TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/lecture-04.m4a"), transcript: Transcript(segments: segments, language: "en"),
                                  modelID: "m", audioDuration: 8, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }

    static func makeVM(document: TranscriptDocument = smallDoc(), format: OutputFormat = .txt, timestamps: Bool = false,
                       autoDetectedLanguage: Bool = false, modelDisplayName: String = "m", savedURL: URL? = nil,
                       exportDirectory: URL = TemporaryDirectory().url,
                       cleanupStyle: TextStyle = .casual,
                       cleanupOptions: StylingOptions = StylingOptions(style: .casual, removeFillers: false, autoPunctuate: false),
                       cleanupStyler: (any TextStyler)? = nil, cleanupClock: any MonotonicClock = SystemMonotonicClock(),
                       pasteboard: any Pasteboard = FakePasteboard(), revealer: any FileRevealing = FakeRevealer()) -> ResultViewModel {
        ResultViewModel(document: document, format: format, timestamps: timestamps, autoDetectedLanguage: autoDetectedLanguage,
                        modelDisplayName: modelDisplayName, savedURL: savedURL,
                        exporter: { TranscriptExporter(directory: exportDirectory) }, cleanupStyle: cleanupStyle, cleanupOptions: cleanupOptions,
                        pasteboard: pasteboard, revealer: revealer, cleanupStyler: cleanupStyler, cleanupClock: cleanupClock)
    }

    @Test("rendered text changes with the selected format")
    func renderedChangesWithFormat() {
        let vm = Self.makeVM()
        let txt = vm.rendered
        #expect(!txt.contains("-->"))
        vm.format = .srt
        let srt = vm.rendered
        #expect(srt.contains("-->"))
        #expect(txt != srt)
    }

    @Test("the selected-format preview matches exports until search filters its segments", arguments: OutputFormat.allCases)
    func previewFollowsFormat(format: OutputFormat) {
        let vm = Self.makeVM(format: format)
        #expect(vm.previewText == vm.rendered)
        vm.searchText = "attention"
        #expect(vm.previewText.contains("This needs your attention"))
        #expect(!vm.previewText.contains("Hello there"))
        #expect(vm.rendered.contains("Hello there"))
        #expect(vm.usesTimedPreview == (format == .srt || format == .vtt))
        if format == .json { #expect(vm.previewText.contains("\"segments\"")) }
        if format == .md { #expect(vm.previewText.contains("# lecture-04")) }
    }

    @Test("copy writes the currently rendered text to the pasteboard")
    func copyWritesRenderedText() {
        let pasteboard = FakePasteboard()
        let vm = Self.makeVM(pasteboard: pasteboard)
        let txtRendered = vm.rendered
        vm.copy()
        #expect(pasteboard.strings == [txtRendered])

        vm.format = .md
        let mdRendered = vm.rendered
        #expect(mdRendered != txtRendered)
        vm.copy()
        #expect(pasteboard.strings == [txtRendered, mdRendered])   // second copy reflects the new format's rendering
    }

    @Test("searchText filters visibleSegments case-insensitively; blank search shows everything")
    func searchFiltersSegments() {
        let vm = Self.makeVM()
        #expect(vm.visibleSegments.count == 3)
        vm.searchText = "ATTENTION"
        #expect(vm.visibleSegments.map(\.text) == ["This needs your attention"])
        vm.searchText = "   "
        #expect(vm.visibleSegments.count == 3)
        vm.searchText = "nowhere to be found"
        #expect(vm.visibleSegments.isEmpty)
    }

    @Test("visibleIndexedSegments numbers by real transcript position, even for a duplicated segment (M2)")
    func indexedSegmentsNumberByRealPosition() {
        // Two segments share identical text — a `firstIndex(of:)` lookup would report "1" for both;
        // enumerating once must still say "3" for the later one.
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hello there")!,
            TranscriptSegment(start: 1, end: 2, text: "This needs your attention")!,
            TranscriptSegment(start: 2, end: 3, text: "Hello there")!,
        ]
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/dup.m4a"), transcript: Transcript(segments: segments, language: "en"),
                                          modelID: "m", audioDuration: 3, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
        let vm = Self.makeVM(document: document)
        #expect(vm.visibleIndexedSegments.map(\.index) == [1, 2, 3])

        vm.searchText = "hello"
        #expect(vm.visibleIndexedSegments.map(\.index) == [1, 3])   // the filtered-out middle segment doesn't shift the numbering
    }

    @Test("metaLine matches the design example")
    func metaLineDesignExample() {
        let words = Array(repeating: "word", count: 13_842).joined(separator: " ")
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/lecture-04.m4a"),
                                          transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 5530, text: words)!], language: "en"),
                                          modelID: "whisper-large-v3-turbo", audioDuration: 5530, processingTime: 252, createdAt: Date(timeIntervalSince1970: 0))
        #expect(document.wordCount == 13_842)
        // The catalog's display name ("Whisper large-v3-turbo"), not the raw `document.modelID`
        // ("whisper-large-v3-turbo") — `FilesPage` is what resolves one from the other (M1).
        let vm = Self.makeVM(document: document, autoDetectedLanguage: true, modelDisplayName: "Whisper large-v3-turbo")
        #expect(vm.metaLine == "1:32:10 · 13,842 words · EN (auto) · Whisper large-v3-turbo · took 4 min 12 s on this Mac")
    }

    @Test("metaLine omits '(auto)' and shows seconds-only processing time when the language was explicit")
    func metaLineExplicitLanguageShortProcessing() {
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/a.m4a"),
                                          transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 10, text: "hi")!], language: "de"),
                                          modelID: "m", audioDuration: 10, processingTime: 12, createdAt: Date(timeIntervalSince1970: 0))
        let vm = Self.makeVM(document: document, autoDetectedLanguage: false)
        #expect(vm.metaLine == "0:10 · 1 words · DE · m · took 12 s on this Mac")
    }

    @Test("metaLine shows AUTO (not 'AUTO (auto)') when the language itself is unknown under auto-detect")
    func metaLineUnknownLanguageAutoDetect() {
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/a.m4a"),
                                          transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 10, text: "hi")!], language: nil),
                                          modelID: "m", audioDuration: 10, processingTime: 12, createdAt: Date(timeIntervalSince1970: 0))
        let vm = Self.makeVM(document: document, autoDetectedLanguage: true)
        #expect(vm.metaLine == "0:10 · 1 words · AUTO · m · took 12 s on this Mac")
    }

    @Test("abbreviate replaces the home directory itself with ~, and only an actual subdirectory of it — not a sibling that merely shares the prefix")
    func abbreviateHomePrefix() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ResultViewModel.abbreviate(URL(fileURLWithPath: home)) == "~")
        #expect(ResultViewModel.abbreviate(URL(fileURLWithPath: home + "/Transcripts/lecture-04.srt")) == "~/Transcripts/lecture-04.srt")
        let siblingPath = home + "2/Transcripts/lecture-04.srt"   // shares `home` as a string prefix, but isn't under it
        #expect(ResultViewModel.abbreviate(URL(fileURLWithPath: siblingPath)) == siblingPath)
    }

    @Test("exportAlso writes a file into the exporter's directory and sets exportMessage")
    func exportAlsoWritesFile() throws {
        let dir = TemporaryDirectory()
        let vm = Self.makeVM(exportDirectory: dir.url)
        let url = try vm.exportAlso(.vtt)
        #expect(url.pathExtension == "vtt")
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.url.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(vm.exportMessage?.hasPrefix("Saved to") == true)
    }

    @Test("a failing export's error is not swallowed: report(error:) surfaces it as \"Couldn't save: …\"")
    func failingExportSurfacesViaReport() throws {
        let outerDir = TemporaryDirectory()
        let blockedPath = outerDir.file("Transcripts")
        try Data("not a directory".utf8).write(to: blockedPath)   // a plain file where the exporter needs a directory
        let vm = Self.makeVM(exportDirectory: blockedPath)
        do {
            try vm.exportAlso(.vtt)
            Issue.record("expected exportAlso to throw")
        } catch {
            vm.report(error: error)
        }
        #expect(vm.exportMessage?.hasPrefix("Couldn\u{2019}t save:") == true)
    }

    @Test("reveal forwards the saved URL to the revealer; a fresh result with no saved URL has no message and reveal is a no-op")
    func revealForwardsSavedURL() {
        let revealer = FakeRevealer()
        let saved = URL(fileURLWithPath: "/tmp/out/lecture-04.srt")
        let vm = Self.makeVM(format: .srt, savedURL: saved, revealer: revealer)
        #expect(vm.exportMessage?.hasPrefix("Saved to") == true)   // set from init's savedURL
        vm.reveal()
        #expect(revealer.revealed == [saved])

        let freshRevealer = FakeRevealer()
        let noSaved = Self.makeVM(format: .srt, savedURL: nil, revealer: freshRevealer)
        #expect(noSaved.exportMessage == nil)
        noSaved.reveal()
        #expect(freshRevealer.revealed.isEmpty)
    }

    // MARK: - "Apply {Style} cleanup" (design 2f, plan ruling 6)

    @Test("cleanupLabel uses the default style's display name")
    func cleanupLabelUsesDefaultStyle() {
        let vm = Self.makeVM(cleanupStyle: .veryCasual)
        #expect(vm.cleanupLabel == "Apply Very casual cleanup")
    }

    @Test("applyCleanup defaults to off; visibleSegments show the raw, unstyled text")
    func cleanupOffKeepsRawSegments() {
        let vm = Self.makeVM()
        #expect(vm.applyCleanup == false)
        #expect(vm.visibleSegments.map(\.text) == ["Hello there", "This needs your attention", "Goodbye now"])
        #expect(vm.rendered.contains("Hello there"))
    }

    @Test("applyCleanup on rewrites every segment through RuleStyler and feeds rendered/exportAlso; turning it back off restores the raw document")
    func cleanupOnRewritesEverySegmentAndExports() throws {
        let segments = [TranscriptSegment(start: 0, end: 2, text: "um so we start")!]
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/a.m4a"), transcript: Transcript(segments: segments, language: "en"),
                                          modelID: "m", audioDuration: 2, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
        let dir = TemporaryDirectory()
        let vm = Self.makeVM(document: document, exportDirectory: dir.url,
                             cleanupOptions: StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true))
        #expect(vm.visibleSegments.map(\.text) == ["um so we start"])

        vm.applyCleanup = true
        #expect(vm.visibleSegments.map(\.text) == ["So we start."])
        // start/end are unchanged by cleanup — only the text is rewritten.
        #expect(vm.visibleIndexedSegments.map { $0.segment.start } == [0])
        #expect(vm.visibleIndexedSegments.map { $0.segment.end } == [2])
        #expect(vm.rendered.contains("So we start."))
        let exported = try vm.exportAlso(.srt)
        let contents = try String(contentsOf: exported, encoding: .utf8)
        #expect(contents.contains("So we start."))

        vm.applyCleanup = false
        #expect(vm.visibleSegments.map(\.text) == ["um so we start"])
        #expect(vm.rendered.contains("um so we start"))
    }

    @Test("cleanedDocument stays fast even for 5,000 segments (< 1 s, ContinuousClock — the only timing assertion allowed)")
    func cleanupIsFast() {
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(5_000)
        for i in 0..<5_000 {
            let start = TimeInterval(i)
            segments.append(TranscriptSegment(start: start, end: start + 1, text: "um so we start")!)
        }
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/big.m4a"), transcript: Transcript(segments: segments, language: "en"),
                                          modelID: "m", audioDuration: 5_000, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
        let vm = Self.makeVM(document: document, cleanupOptions: StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            vm.applyCleanup = true
            _ = vm.visibleSegments.count
        }
        #expect(elapsed < .seconds(1))
    }
}

@Suite("Short file LLM cleanup") @MainActor
struct ShortFileCleanupTests {
    @Test("Short cleanup uses the LLM and preserves segment timing, confidence and displayed word count")
    func shortCleanup() async throws {
        let backend = FakeLLMBackend(reply: "A polished result.")
        let clock = SystemMonotonicClock()
        let vm = ResultViewModelTests.makeVM(cleanupStyler: LlamaStyler(backend: backend, clock: clock), cleanupClock: clock)
        let original = vm.activeDocument
        vm.applyCleanup = true
        #expect(vm.isCleaning)
        let refreshed = Mutex(false)
        withObservationTracking { _ = vm.metaLine } onChange: { refreshed.withLock { $0 = true } }
        await vm.waitForCleanup()
        #expect(refreshed.withLock { $0 })
        #expect(!vm.isCleaning)
        #expect(vm.visibleSegments.map(\.text) == Array(repeating: "A polished result.", count: 3))
        #expect(vm.visibleSegments.map(\.start) == original.transcript.segments.map(\.start))
        #expect(vm.visibleSegments.map(\.end) == original.transcript.segments.map(\.end))
        #expect(vm.visibleSegments.map(\.confidence) == original.transcript.segments.map(\.confidence))
        #expect(vm.metaLine.contains("9 words"))
        let exported = try vm.exportAlso(.srt)
        #expect(try String(contentsOf: exported, encoding: .utf8).contains("A polished result."))
        vm.applyCleanup = false
        #expect(vm.activeDocument == original)
        #expect(vm.metaLine.contains("8 words"))
    }

    @Test("The total transcript limit applies across segments, including the 150-word boundary", arguments: [150, 151])
    func totalWordLimit(words: Int) async {
        var document = ResultViewModelTests.smallDoc()
        document.transcript.segments = (0..<words).map { TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "word")! }
        let backend = FakeLLMBackend(reply: "Rewritten.")
        let clock = SystemMonotonicClock()
        let vm = ResultViewModelTests.makeVM(document: document, cleanupStyler: LlamaStyler(backend: backend, clock: clock), cleanupClock: clock)
        vm.applyCleanup = true
        await vm.waitForCleanup()
        #expect(await backend.prompts.count == (words == 150 ? 150 : 0))
    }

    @Test("Missing model and generation errors keep deterministic rule cleanup", arguments: [false, true])
    func fallback(fails: Bool) async {
        let backend = FakeLLMBackend(ready: fails)
        if fails { await backend.set(error: .cancelled) }
        let clock = SystemMonotonicClock()
        let options = StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true)
        let vm = ResultViewModelTests.makeVM(cleanupOptions: options, cleanupStyler: LlamaStyler(backend: backend, clock: clock), cleanupClock: clock)
        vm.applyCleanup = true
        let rules = vm.activeDocument
        await vm.waitForCleanup()
        #expect(vm.activeDocument == rules)
        #expect(!vm.isCleaning)
    }

    @Test("Re-enabling cleanup after model removal restores deterministic rules")
    func retryWithoutModel() async {
        let backend = FakeLLMBackend(reply: "A polished result.")
        let clock = SystemMonotonicClock()
        let vm = ResultViewModelTests.makeVM(cleanupStyler: LlamaStyler(backend: backend, clock: clock), cleanupClock: clock)
        vm.applyCleanup = true
        let rules = vm.activeDocument
        await vm.waitForCleanup()
        #expect(vm.activeDocument != rules)
        vm.applyCleanup = false
        await backend.set(ready: false)
        vm.applyCleanup = true
        await vm.waitForCleanup()
        #expect(vm.activeDocument == rules)
    }

    @Test("One file deadline rejects late segment replies and skips remaining segments")
    func sharedDeadline() async {
        let clock = FakeClock()
        let styler = GatedFileStyler()
        let vm = ResultViewModelTests.makeVM(cleanupStyler: styler, cleanupClock: clock)
        vm.applyCleanup = true
        let rules = vm.activeDocument
        await styler.waitUntilStarted()
        await clock.advance(by: 9)
        await styler.release()
        await vm.waitForCleanup()
        #expect(vm.activeDocument == rules)
        #expect(await styler.calls == 1)
        #expect(await styler.deadlines == [8])
        #expect(!vm.isCleaning)
    }

    @Test("Cancelled work cannot replace a newer segmentation or a disabled cleanup", arguments: [false, true])
    func staleReply(changesSegmentation: Bool) async {
        let styler = GatedFileStyler()
        let vm = ResultViewModelTests.makeVM(cleanupStyler: styler)
        vm.applyCleanup = true
        await styler.waitUntilStarted()
        if changesSegmentation { vm.segmentLength = .short } else { vm.applyCleanup = false }
        let expected = vm.activeDocument
        vm.cancelCleanup()
        await styler.release()
        await vm.waitForCleanup()
        #expect(vm.activeDocument == expected)
        #expect(!vm.isCleaning)
    }
}

private actor GatedFileStyler: TextStyler {
    private(set) var calls = 0
    private(set) var deadlines: [Double?] = []
    private var started = false
    private var released = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { starters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
    func style(_ raw: String, options: StylingOptions) async throws -> StyledText {
        calls += 1
        deadlines.append(options.generationDeadline)
        started = true
        starters.forEach { $0.resume() }; starters.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return StyledText(text: "Late replacement", fillersRemoved: 0)
    }
}
