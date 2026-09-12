import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowTestSupport
@testable import VoxFlow

final class FakeOutputFolderBookmarks: OutputFolderBookmarking, Sendable {
    let starts = Mutex<[URL]>([]), stops = Mutex<[URL]>([])
    let stale: Bool, accessible: Bool, writable: Bool, creationFails: Bool, container: Bool
    init(stale: Bool = false, accessible: Bool = true, writable: Bool = true, creationFails: Bool = false, container: Bool = false) {
        self.stale = stale; self.accessible = accessible; self.writable = writable; self.creationFails = creationFails; self.container = container
    }
    func create(_ url: URL) throws -> Data {
        if creationFails { throw CocoaError(.fileWriteNoPermission) }
        return Data(url.path.utf8)
    }
    func resolve(_ data: Data) throws -> ResolvedOutputFolder {
        guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { throw CocoaError(.fileReadCorruptFile) }
        return ResolvedOutputFolder(url: URL(fileURLWithPath: path), isStale: stale)
    }
    func startAccessing(_ url: URL) -> Bool { starts.withLock { $0.append(url) }; return accessible }
    func stopAccessing(_ url: URL) { stops.withLock { $0.append(url) } }
    func isWritableDirectory(_ url: URL) -> Bool { writable }
    func isInAppContainer(_ url: URL) -> Bool { container }
}

@Suite("Output-folder bookmarks") @MainActor
struct OutputFolderBookmarkTests {
    let folder = URL(fileURLWithPath: "/tmp/chosen-folder")
    @Test("selection persists a scoped bookmark and resolves it on relaunch")
    func restore() {
        let store = InMemoryKeyValueStore(), bookmarks = FakeOutputFolderBookmarks()
        let selection = OutputFolderSelection(store: store, bookmarks: bookmarks)
        selection.select(folder)
        #expect(store.string(forKey: "files.outputFolderBookmark") != nil)
        #expect(selection.url == folder && selection.message == nil)
        let reloaded = OutputFolderSelection(store: store, bookmarks: bookmarks)
        #expect(reloaded.url == folder && reloaded.message == nil)
        #expect(bookmarks.starts.withLock { $0 } == [folder, folder])
    }
    @Test("invalid, stale and inaccessible bookmarks fall back visibly instead of using the old path",
          arguments: ["invalid", "stale", "denied", "missing"])
    func fallback(reason: String) {
        let store = InMemoryKeyValueStore()
        store.set(reason == "invalid" ? "not base64!" : Data(folder.path.utf8).base64EncodedString(), forKey: "files.outputFolderBookmark")
        store.set(folder.path, forKey: "files.outputFolder")
        let bookmarks = FakeOutputFolderBookmarks(stale: reason == "stale", accessible: reason != "denied", writable: reason != "missing")
        let selection = OutputFolderSelection(store: store, bookmarks: bookmarks)
        #expect(selection.url == TranscriptExporter.defaultDirectory && selection.message != nil)
        #expect(store.string(forKey: "files.outputFolderBookmark") == nil)
        #expect(store.string(forKey: "files.outputFolder") == nil)
        #expect(OutputFolderSelection(store: store, bookmarks: bookmarks).message != nil)
    }
    @Test("an already-authorized container folder needs no scoped lease, external folders still do", arguments: [false, true])
    func containerAccess(isContainer: Bool) {
        let bookmarks = FakeOutputFolderBookmarks(accessible: false, container: isContainer)
        let selection = OutputFolderSelection(store: InMemoryKeyValueStore(), bookmarks: bookmarks)
        selection.select(folder)
        #expect((selection.message == nil) == isContainer)
        #expect(bookmarks.stops.withLock { $0 }.isEmpty)
    }

    @Test("container fallback rejects external paths, sibling prefixes, symlink escapes and ordinary homes")
    func containerBoundary() throws {
        let directory = TemporaryDirectory()
        let home = directory.url.appendingPathComponent("Library/Containers/test.bundle/Data")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let inside = home.appendingPathComponent("output")
        #expect(SystemOutputFolderBookmarks.isInAppContainer(inside, home: home, bundleID: "test.bundle"))
        for outside in [directory.url, home.appendingPathComponent("../Data-other"),
                        home.appendingPathComponent("../../other.bundle/Data")] {
            #expect(!SystemOutputFolderBookmarks.isInAppContainer(outside, home: home, bundleID: "test.bundle"))
        }
        let link = home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.url)
        #expect(!SystemOutputFolderBookmarks.isInAppContainer(link, home: home, bundleID: "test.bundle"))
        #expect(!SystemOutputFolderBookmarks.isInAppContainer(inside, home: directory.url, bundleID: "test.bundle"))
    }

    @Test("a legacy path is migrated only after access and bookmark creation succeed", arguments: [false, true])
    func migration(fails: Bool) {
        let store = InMemoryKeyValueStore(), bookmarks = FakeOutputFolderBookmarks(creationFails: fails)
        store.set(folder.path, forKey: "files.outputFolder")
        let selection = OutputFolderSelection(store: store, bookmarks: bookmarks)
        #expect(selection.url.path == (fails ? TranscriptExporter.defaultDirectory : folder).path)
        #expect((store.string(forKey: "files.outputFolderBookmark") != nil) == !fails)
        if fails { #expect(selection.message != nil && bookmarks.stops.withLock { $0.map(\.path) } == [folder.path]) }
    }
    @Test("an exporter retains old folder access while settings switch, then releases it exactly once")
    func lease() throws {
        let directory = TemporaryDirectory(), bookmarks = FakeOutputFolderBookmarks()
        let first = directory.file("first"), second = directory.file("second")
        var selection: OutputFolderSelection? = OutputFolderSelection(store: InMemoryKeyValueStore(), bookmarks: bookmarks,
                                                                      defaultDirectory: directory.file("fallback"))
        selection?.select(first)
        var exporter: TranscriptExporter? = selection?.exporter()
        selection?.select(second)
        #expect(bookmarks.stops.withLock { $0 }.isEmpty)
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/sample.wav"),
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "hello")!]),
            modelID: "test", audioDuration: 1, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
        #expect(try exporter?.export(document, format: .txt, timestamps: false).deletingLastPathComponent().path == first.path)
        exporter = nil
        #expect(bookmarks.stops.withLock { $0 } == [first])
        selection = nil
        #expect(bookmarks.stops.withLock { $0 } == [first, second])
    }
}

/// Explicit temporary-folder check only. This verifies the unsandboxed Foundation round trip;
/// entitlement/container enforcement still requires a separately signed sandboxed acceptance run.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_BOOKMARK_CHECK"] == "1")) @MainActor
struct OutputFolderBookmarkIntegrationTests {
    @Test("a real scoped temporary-folder bookmark restores after its initial lease is released")
    func roundTrip() throws {
        let directory = TemporaryDirectory(), store = InMemoryKeyValueStore()
        var initial: OutputFolderSelection? = OutputFolderSelection(store: store, bookmarks: SystemOutputFolderBookmarks())
        initial?.select(directory.url)
        try #require(initial?.message == nil)
        try #require(store.string(forKey: "files.outputFolderBookmark") != nil)
        initial = nil
        let restored = OutputFolderSelection(store: store, bookmarks: SystemOutputFolderBookmarks())
        try #require(restored.message == nil)
        try #require(restored.url.resolvingSymlinksInPath().path == directory.url.resolvingSymlinksInPath().path)
        let document = TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/bookmark-check.wav"),
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Bookmark check")!]),
            modelID: "test", audioDuration: 1, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
        let file = try restored.exporter().export(document, format: .txt, timestamps: false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Bookmark check"))
    }
}
