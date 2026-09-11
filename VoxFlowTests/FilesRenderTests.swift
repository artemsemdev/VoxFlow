import AppKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 5) for the Files result view (design 2f), gated behind
/// `VOXFLOW_RENDER` so normal test runs never touch disk — same convention as
/// `HistoryRenderTests`/`StylesRenderTests`. Run with
/// `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/FilesRenderTests`, then compare
/// against `canvas.pdf` pages 9–10 (2f). Native hosting captures the actual picker and checkbox.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct FilesRenderTests {
    private func makeVM(applyCleanup: Bool) -> ResultViewModel {
        let vm = ResultViewModel.makeForRender(document: ResultViewModelTests.smallDoc())
        vm.applyCleanup = applyCleanup
        return vm
    }

    @Test("renders the Files result view for design-fidelity comparison against canvas 2f")
    func render() throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. 2f default — "Apply Casual cleanup" unchecked (controller ruling 6: off by default).
        try Self.render(TranscriptResultView(resultModel: makeVM(applyCleanup: false), onBack: {}), name: "1-cleanup-off", directory: directory)

        // 2. 2f as the canvas sample shows it — checked.
        try Self.render(TranscriptResultView(resultModel: makeVM(applyCleanup: true), onBack: {}), name: "2-cleanup-on", directory: directory)

        // 3. Shared production rows isolate the raw-vs-cleaned text comparison.
        let offVM = makeVM(applyCleanup: false)
        let onVM = makeVM(applyCleanup: true)
        let rowsPreview = VStack(alignment: .leading, spacing: 16) {
            Text("Apply Casual cleanup — off").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(offVM.visibleIndexedSegments), id: \.index) { TranscriptSegmentRow(index: $0.index, segment: $0.segment) }
            Divider()
            Text("Apply Casual cleanup — on").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(onVM.visibleIndexedSegments), id: \.index) { TranscriptSegmentRow(index: $0.index, segment: $0.segment) }
        }
        .padding(16)
        try Self.render(rowsPreview, name: "3-segment-rows-off-vs-on", directory: directory)
        var source = ResultViewModelTests.smallDoc()
        source.transcript.segments = [try #require(TranscriptSegment(start: 0, end: 12,
            text: "Welcome back. Today we are picking up where we left off with attention mechanisms and the encoder states from last week."))]
        for length in SegmentLength.allCases {
            let vm = ResultViewModel.makeForRender(document: source)
            vm.segmentLength = length
            try Self.render(TranscriptResultView(resultModel: vm, onBack: {}), name: "segments-\(length.rawValue)", directory: directory)
        }
    }

    @MainActor
    private static func render(_ view: some View, name: String, directory: URL) throws {
        let content = view.frame(width: 900, height: 600).background(Color.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.close() }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("Files-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
    }

}

private extension ResultViewModel {
    /// A `ResultViewModel` built the same way `FilesPage` builds one, minus any live services —
    /// fillers removed and auto-punctuate on, Casual, so "um so we start"-style segments visibly
    /// change when the checkbox renders checked.
    static func makeForRender(document: TranscriptDocument) -> ResultViewModel {
        ResultViewModel(document: document, format: .txt, timestamps: false, autoDetectedLanguage: false, modelDisplayName: "Whisper large-v3-turbo",
                        savedURL: URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Transcripts/lecture-04.srt"),
                        exporter: { TranscriptExporter(directory: TemporaryDirectory().url) },
                        cleanupStyle: .casual, cleanupOptions: StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true),
                        pasteboard: FakePasteboard(), revealer: FakeRevealer())
    }
}
