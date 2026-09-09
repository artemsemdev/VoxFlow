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
/// `VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/FilesRenderTests`, then compare the
/// PNGs in `.superpowers/design/renders/` against `canvas.pdf` page 7 (2f) — the
/// "✓ Apply Casual cleanup" checkbox is what this task adds; "Segment length" is a follow-up and
/// stays unbuilt.
///
/// Known `ImageRenderer` limitation (see `DictionaryRenderTests`'s doc comment for the first
/// writeup): a live `Toggle` rasterizes as a plain yellow "unavailable cursor" glyph instead of a
/// real checkbox. So in these PNGs the "Apply Casual cleanup" checkbox shows that glyph, not its
/// real on-screen appearance — verify the actual checkbox by running the live app.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct FilesRenderTests {
    private func makeVM(applyCleanup: Bool) -> ResultViewModel {
        let vm = ResultViewModel.makeForRender(document: ResultViewModelTests.smallDoc())
        vm.applyCleanup = applyCleanup
        return vm
    }

    @Test("renders the Files result view for design-fidelity comparison against canvas page 7 (2f)")
    func render() throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. 2f default — "Apply Casual cleanup" unchecked (controller ruling 6: off by default).
        // The live `ScrollView` segment list rasterizes blank under `ImageRenderer` (same known
        // limitation `StylesRenderTests` documents for `Toggle`/`Picker`/live `ScrollView`s), so
        // this render is the header/search/footer chrome only — see case 3 below for the rows.
        try Self.render(TranscriptResultView(resultModel: makeVM(applyCleanup: false), onBack: {}), name: "1-cleanup-off", directory: directory)

        // 2. 2f as the canvas sample shows it — checked.
        try Self.render(TranscriptResultView(resultModel: makeVM(applyCleanup: true), onBack: {}), name: "2-cleanup-on", directory: directory)

        // 3. Segment rows outside the live `ScrollView` (the actual `TranscriptSegmentRow` type
        // `segmentList` uses, not a hand-retyped copy) — the only way to see the raw-vs-cleaned
        // text difference under `ImageRenderer`. Off on top, on (rewritten, periods added) below.
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
    }

    @MainActor
    private static func render(_ view: some View, name: String, directory: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 600).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render \(name)")
            return
        }
        try writePNG(image, to: directory.appendingPathComponent("Files-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
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
