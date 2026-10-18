import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("FilesSettings") @MainActor
struct FilesSettingsTests {
    @Test("defaults match the design: TXT, batch on, timestamps on, auto language, ~/Transcripts")
    func defaults() {
        let settings = FilesSettings(store: InMemoryKeyValueStore())
        #expect(settings.outputFormat == .txt)
        #expect(settings.batchMode && settings.timestamps)
        #expect(settings.language == nil)
        #expect(settings.outputFolder.lastPathComponent == "Transcripts")
        #expect(settings.transcriptionOptions == TranscriptionOptions())
    }

    @Test("changes persist and reload")
    func persistence() {
        let store = InMemoryKeyValueStore()
        let settings = FilesSettings(store: store, bookmarks: FakeOutputFolderBookmarks())
        settings.outputFormat = .srt
        settings.timestamps = false
        settings.language = "de"
        settings.outputFolder = URL(fileURLWithPath: "/tmp/out")
        let reloaded = FilesSettings(store: store, bookmarks: FakeOutputFolderBookmarks())
        #expect(reloaded.outputFormat == .srt && reloaded.timestamps == false && reloaded.language == "de")
        #expect(reloaded.outputFolder.path == "/tmp/out")
        #expect(reloaded.transcriptionOptions.language == "de")
    }
}
