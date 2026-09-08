import Foundation
import Testing
import VoxFlowCore
import VoxFlowFiles
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
                       pasteboard: any Pasteboard = FakePasteboard(), revealer: any FileRevealing = FakeRevealer()) -> ResultViewModel {
        ResultViewModel(document: document, format: format, timestamps: timestamps, autoDetectedLanguage: autoDetectedLanguage,
                        modelDisplayName: modelDisplayName, savedURL: savedURL,
                        exporter: { TranscriptExporter(directory: exportDirectory) }, pasteboard: pasteboard, revealer: revealer)
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
}
