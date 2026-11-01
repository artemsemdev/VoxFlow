import Foundation
import Testing
@testable import VoxFlow

@Suite @MainActor
struct StoreDraftTests {
    @Test func capturedTextAppendsAndSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "draft.txt")
        let draft = StoreDraft(url: url)
        #expect(draft.saveError == nil)
        _ = await draft.insert("First thought.", cursorOffset: nil)
        _ = await draft.insert("Second thought.", cursorOffset: nil)
        #expect(StoreDraft(url: url).text == "First thought.\n\nSecond thought.")
    }

    @Test func failedPersistenceKeepsTextAvailableToCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appending(path: "file")
        try Data().write(to: blocker)
        let draft = StoreDraft(url: blocker.appending(path: "draft.txt"))
        _ = await draft.insert("Do not lose this.", cursorOffset: nil)
        #expect(draft.text == "Do not lose this.")
        #expect(draft.saveError != nil)
    }
}
