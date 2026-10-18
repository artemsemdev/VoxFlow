import Foundation
import Observation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Result segmentation")
@MainActor
struct ResultSegmentationTests {
    @Test("warm cleanup cache still invalidates observed rows when length changes")
    func observedRows() {
        let vm = ResultViewModelTests.makeVM()
        vm.applyCleanup = true
        _ = vm.visibleIndexedSegments
        let changed = Mutex(false)
        withObservationTracking {
            _ = vm.visibleIndexedSegments
        } onChange: {
            changed.withLock { $0 = true }
        }
        vm.segmentLength = .short
        #expect(changed.withLock { $0 })
    }

    @Test("length choice drives preview, search, Copy and every export without changing the source")
    func changesPreviewAndExport() throws {
        var source = ResultViewModelTests.smallDoc()
        source.transcript.segments = [try #require(TranscriptSegment(start: 0, end: 12,
            text: "One two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen."))]
        let clipboard = FakePasteboard()
        let directory = TemporaryDirectory()
        let vm = ResultViewModelTests.makeVM(document: source, format: .srt, exportDirectory: directory.url, pasteboard: clipboard)
        let sentences = vm.rendered
        vm.segmentLength = .short
        #expect(vm.visibleSegments.count > 1)
        #expect(vm.rendered != sentences)
        let short = vm.activeDocument
        vm.searchText = "eighteen"
        #expect(vm.visibleSegments.count == 1)
        #expect(vm.visibleIndexedSegments.first?.index == short.transcript.segments.count)
        vm.copy()
        #expect(clipboard.strings == [vm.rendered])
        for format in OutputFormat.allCases {
            let contents = try String(contentsOf: vm.exportAlso(format), encoding: .utf8)
            #expect(contents == TranscriptRenderer.render(short, format: format, timestamps: vm.timestamps))
        }
        vm.segmentLength = .long
        #expect(vm.activeDocument.transcript.segments.count < short.transcript.segments.count)
        vm.segmentLength = .sentences
        #expect(vm.rendered == sentences)
        #expect(vm.document == source)
    }

    @Test("cleanup uses the selected segmentation and is recalculated after a length change")
    func cleanup() throws {
        var source = ResultViewModelTests.smallDoc()
        source.transcript.segments = [try #require(TranscriptSegment(start: 0, end: 12,
            text: "um one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen."))]
        let vm = ResultViewModelTests.makeVM(document: source,
            cleanupOptions: StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true))
        vm.applyCleanup = true
        vm.segmentLength = .short
        #expect(vm.activeDocument.transcript.segments.count > 1)
        #expect(!vm.activeDocument.transcript.plainText.hasPrefix("um "))
        #expect(vm.activeDocument.transcript.segments.allSatisfy { $0.text.hasSuffix(".") })
        let shortCount = vm.activeDocument.transcript.segments.count
        vm.segmentLength = .long
        #expect(vm.activeDocument.transcript.segments.count < shortCount)
        vm.applyCleanup = false
        #expect(vm.activeDocument.transcript.plainText.hasPrefix("um "))
        #expect(vm.document == source)
    }
}
