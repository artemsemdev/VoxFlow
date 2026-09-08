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
                       autoDetectedLanguage: Bool = false, savedURL: URL? = nil, exportDirectory: URL = TemporaryDirectory().url,
                       pasteboard: any Pasteboard = FakePasteboard(), revealer: any FileRevealing = FakeRevealer()) -> ResultViewModel {
        ResultViewModel(document: document, format: format, timestamps: timestamps, autoDetectedLanguage: autoDetectedLanguage, savedURL: savedURL,
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

    @Test("metaLine matches the design example")
    func metaLineDesignExample() {
        let words = Array(repeating: "word", count: 13_842).joined(separator: " ")
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/lecture-04.m4a"),
                                          transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 5530, text: words)!], language: "en"),
                                          modelID: "whisper-large-v3-turbo", audioDuration: 5530, processingTime: 252, createdAt: Date(timeIntervalSince1970: 0))
        #expect(document.wordCount == 13_842)
        let vm = Self.makeVM(document: document, autoDetectedLanguage: true)
        #expect(vm.metaLine == "1:32:10 · 13,842 words · EN (auto) · whisper-large-v3-turbo · took 4 min 12 s on this Mac")
    }

    @Test("metaLine omits '(auto)' and shows seconds-only processing time when the language was explicit")
    func metaLineExplicitLanguageShortProcessing() {
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/a.m4a"),
                                          transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 10, text: "hi")!], language: "de"),
                                          modelID: "m", audioDuration: 10, processingTime: 12, createdAt: Date(timeIntervalSince1970: 0))
        let vm = Self.makeVM(document: document, autoDetectedLanguage: false)
        #expect(vm.metaLine == "0:10 · 1 words · DE · m · took 12 s on this Mac")
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
