import AppKit
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Only synthetic text and temporary stores: no live services, microphone, history or Keychain.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct StoreRenderTests {
    @Test func renderStoreScreens() async throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/app-store/screenshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = TemporaryDirectory()
        let draft = StoreDraft(url: temporary.file("draft.txt"))
        #expect(draft.text.isEmpty)
        try await capture(StoreDictationContent(draft: draft, status: "Ready when you are", start: {}, stop: {}, showModels: {}),
                          page: "Dictation", name: "00-clean-first-launch", output: output)
        draft.text = """
        A little room for a new idea.

        Let's make a short guide to growing herbs on a sunny windowsill. Start with basil, mint and parsley. Choose pots with drainage, give each plant enough light, and water when the top layer of soil feels dry.

        For the next episode, we can turn these notes into a simple checklist: choose a spot, prepare the pots, plant the seeds, and keep a weekly journal.

        Small steps, fresh leaves, and something new to learn every day.
        """
        try await capture(StoreDictationContent(draft: draft, status: "Text added to your draft", start: {}, stop: {}, showModels: {}),
                          page: "Dictation", name: "01-dictation", output: output)
        let sentences = ["Welcome to our guide to growing herbs at home.",
                         "Choose a sunny windowsill and a few pots with drainage holes.",
                         "Basil, mint and parsley are a good place to start.",
                         "Water when the top layer of soil feels dry.",
                         "Keep a weekly journal and enjoy watching your garden grow."]
        let segments = sentences.enumerated().map { index, text in
            TranscriptSegment(start: Double(index * 5), end: Double((index + 1) * 5), text: text)!
        }
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/Sample/herb-garden.m4a"),
            transcript: Transcript(segments: segments, language: "en"), modelID: "whisper-small",
            audioDuration: 25, processingTime: 10, createdAt: Date(timeIntervalSince1970: 0))
        let result = ResultViewModel(document: document, format: .srt, timestamps: true,
            autoDetectedLanguage: true, modelDisplayName: "Whisper small", savedURL: nil,
            exporter: { TranscriptExporter(directory: temporary.url) }, cleanupStyle: .formal,
            cleanupOptions: StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true),
            pasteboard: RenderPasteboard(), revealer: RenderRevealer())
        try await capture(TranscriptResultView(resultModel: result, onBack: {}), page: "Files", name: "02-subtitles", output: output)
        let catalog = ModelCatalog.all.filter { $0.role == .speech }
        let store = ModelStore(directory: temporary.file("Models"), catalog: catalog,
            downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: InMemoryKeyValueStore())
        let models = ModelsViewModel(store: store, catalog: catalog)
        await models.refresh()
        try await capture(ModelsSettingsView(model: models, footerText: StoreServices.modelsFooter), page: "Models", name: "03-models", output: output)
    }

    private func capture(_ content: some View, page: String, name: String, output: URL) async throws {
        let root = NavigationSplitView {
            StoreSidebar(page: .constant(page)).navigationSplitViewColumnWidth(220)
        } detail: {
            content.navigationTitle(page)
        }
        let host = NativeRenderHost(root, size: NSSize(width: 1280, height: 800))
        let url = output.appending(path: name + ".jpg")
        try await host.captureSettled(to: url)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        #expect([(1280, 800), (2560, 1600)].contains { bitmap.pixelsWide == $0.0 && bitmap.pixelsHigh == $0.1 })
        #expect(!bitmap.hasAlpha)
    }
}

private struct RenderPasteboard: VoxFlow.Pasteboard { func setString(_ string: String) {} }
private struct RenderRevealer: FileRevealing { func reveal(_ url: URL) {} }
