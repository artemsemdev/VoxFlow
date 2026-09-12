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

    @Test("renders production Files empty, queued, transcribing, completed and error states")
    func renderQueueStates() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Self.render(DropZoneView(isFileImporterPresented: .constant(false)),
                        name: "141-drop-zone", directory: directory, size: NSSize(width: 700, height: 250))
        try Self.render(FilesDragOverOverlay(dragCount: 2),
                        name: "141-drag-over", directory: directory, size: NSSize(width: 700, height: 250))

        let queued = try await FilesViewModelTests.Harness(preSeed: [FilesViewModelTests.a])
        await queued.settle()
        try Self.render(QueueListView(model: queued.viewModel),
                        name: "141-queued", directory: directory, size: NSSize(width: 700, height: 180))

        let transcribing = try await FilesViewModelTests.Harness()
        await transcribing.transcriber.hold(FilesViewModelTests.a)
        await transcribing.transcriber.script(FilesViewModelTests.a, .document(FilesViewModelTests.doc(FilesViewModelTests.a)))
        await transcribing.viewModel.addFiles([FilesViewModelTests.a])
        await transcribing.viewModel.transcribeAll()
        await transcribing.drainHeld(FilesViewModelTests.a)
        try Self.render(QueueListView(model: transcribing.viewModel),
                        name: "141-transcribing", directory: directory, size: NSSize(width: 700, height: 180))

        let completed = try await FilesViewModelTests.Harness()
        await completed.transcriber.script(FilesViewModelTests.a, .document(FilesViewModelTests.doc(FilesViewModelTests.a)))
        await completed.viewModel.addFiles([FilesViewModelTests.a])
        await completed.viewModel.transcribeAll()
        await completed.settle()
        try Self.render(QueueListView(model: completed.viewModel),
                        name: "141-completed", directory: directory, size: NSSize(width: 700, height: 180))

        let failed = try await FilesViewModelTests.Harness()
        await failed.viewModel.addFiles([FilesViewModelTests.bad])
        await failed.settle()
        try Self.render(QueueListView(model: failed.viewModel),
                        name: "141-error", directory: directory, size: NSSize(width: 700, height: 200))

        await transcribing.transcriber.release(FilesViewModelTests.a)
        await transcribing.settle()
        withExtendedLifetime([queued.dir, transcribing.dir, completed.dir, failed.dir]) {}

        let queuedRailPixels = try Self.pixelCount(
            at: directory.appendingPathComponent("Files-141-queued.png"),
            in: CGRect(x: 0.05, y: 0.62, width: 0.9, height: 0.09),
            matching: { r, g, b in abs(r - g) < 0.025 && abs(g - b) < 0.025 && r > 0.82 && r < 0.96 })
        #expect(queuedRailPixels > 8_000, "Queued row must contain a full-width neutral rail")

        let doneRailPixels = try Self.pixelCount(
            at: directory.appendingPathComponent("Files-141-completed.png"),
            in: CGRect(x: 0.05, y: 0.62, width: 0.9, height: 0.09),
            matching: { r, g, b in g > 0.55 && g > r * 1.25 && g > b * 1.15 })
        #expect(doneRailPixels > 8_000, "Completed row must contain a full-width green rail")

        let dragURL = directory.appendingPathComponent("Files-141-drag-over.png")
        let tilePixels = try Self.pixelCount(
            at: dragURL, in: CGRect(x: 0.45, y: 0.32, width: 0.1, height: 0.22),
            matching: { r, g, b in b > 0.55 && b > r * 1.35 && b > g * 1.05 })
        let glyphPixels = try Self.pixelCount(
            at: dragURL, in: CGRect(x: 0.47, y: 0.34, width: 0.06, height: 0.18),
            matching: { r, g, b in r > 0.92 && g > 0.92 && b > 0.92 })
        #expect(tilePixels > 4_000, "Drag overlay must contain a solid blue icon tile")
        #expect(glyphPixels > 50 && glyphPixels < 3_500, "Drag overlay tile must contain a light arrow glyph")
    }

    @MainActor
    private static func render(_ view: some View, name: String, directory: URL,
                               size: NSSize = NSSize(width: 900, height: 600)) throws {
        let host = NativeRenderHost(view, size: size)
        defer { host.close() }
        try host.capture(to: directory.appendingPathComponent("Files-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
    }

    private static func pixelCount(
        at url: URL, in normalizedRect: CGRect,
        matching predicate: (CGFloat, CGFloat, CGFloat) -> Bool
    ) throws -> Int {
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let xRange = Int(CGFloat(bitmap.pixelsWide) * normalizedRect.minX)..<Int(CGFloat(bitmap.pixelsWide) * normalizedRect.maxX)
        let yRange = Int(CGFloat(bitmap.pixelsHigh) * normalizedRect.minY)..<Int(CGFloat(bitmap.pixelsHigh) * normalizedRect.maxY)
        var count = 0
        for y in yRange {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if predicate(color.redComponent, color.greenComponent, color.blueComponent) { count += 1 }
            }
        }
        return count
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
