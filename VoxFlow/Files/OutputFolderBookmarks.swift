import Foundation
import VoxFlowCore
import VoxFlowFiles

struct ResolvedOutputFolder: Sendable { let url: URL; let isStale: Bool }

protocol OutputFolderBookmarking: Sendable {
    func create(_ url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedOutputFolder
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func isWritableDirectory(_ url: URL) -> Bool
    func isInAppContainer(_ url: URL) -> Bool
}

extension OutputFolderBookmarking {
    func isInAppContainer(_ url: URL) -> Bool { false }
}

struct SystemOutputFolderBookmarks: OutputFolderBookmarking {
    func create(_ url: URL) throws -> Data { try url.bookmarkData(options: .withSecurityScope) }
    func resolve(_ data: Data) throws -> ResolvedOutputFolder {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        return ResolvedOutputFolder(url: url, isStale: stale)
    }
    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    func isInAppContainer(_ url: URL) -> Bool {
        Self.isInAppContainer(url, home: FileManager.default.homeDirectoryForCurrentUser,
                              bundleID: Bundle.main.bundleIdentifier)
    }
    /// Foundation remaps home to this app's Data container under App Sandbox. Resolve symlinks
    /// before comparing components; an external writable path never substitutes for a scope.
    static func isInAppContainer(_ url: URL, home: URL, bundleID: String?) -> Bool {
        guard url.isFileURL, let bundleID else { return false }
        let root = home.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard Array(root.suffix(4)) == ["Library", "Containers", bundleID, "Data"] else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return path.starts(with: root)
    }
    func isWritableDirectory(_ url: URL) -> Bool {
        url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && FileManager.default.isWritableFile(atPath: url.path)
    }
}

@Observable @MainActor
final class OutputFolderSelection {
    private enum Keys {
        static let bookmark = "files.outputFolderBookmark"
        static let legacyPath = "files.outputFolder"
        static let notice = "files.outputFolderNotice"
    }
    private let store: any KeyValueStore
    private let bookmarks: any OutputFolderBookmarking
    private let defaultDirectory: URL
    private var access: OutputFolderAccess?
    private(set) var url: URL
    private(set) var message: String?

    init(store: any KeyValueStore, bookmarks: any OutputFolderBookmarking,
         defaultDirectory: URL = TranscriptExporter.defaultDirectory) {
        self.store = store; self.bookmarks = bookmarks; self.defaultDirectory = defaultDirectory
        url = defaultDirectory
        message = store.string(forKey: Keys.notice)
        if let encoded = store.string(forKey: Keys.bookmark) {
            do {
                guard let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
                let resolved = try bookmarks.resolve(data)
                guard !resolved.isStale else { throw CocoaError(.fileReadCorruptFile) }
                access = try acquire(resolved.url)
                url = resolved.url
                message = nil
                store.set(nil, forKey: Keys.notice)
            } catch { fallback() }
        } else if let path = store.string(forKey: Keys.legacyPath) {
            // A legacy path conveys no sandbox authorization. Migration must acquire usable
            // access and create a real scoped bookmark; otherwise ask the user to select again.
            guard path.hasPrefix("/") else { fallback(); return }
            select(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func select(_ selected: URL) {
        if selected.standardizedFileURL == defaultDirectory.standardizedFileURL {
            access = nil; url = defaultDirectory; message = nil
            store.set(nil, forKey: Keys.bookmark); store.set(nil, forKey: Keys.legacyPath)
            store.set(nil, forKey: Keys.notice)
            return
        }
        do {
            let acquired = try acquire(selected)
            let data = try bookmarks.create(selected)
            access = acquired; url = selected; message = nil
            store.set(data.base64EncodedString(), forKey: Keys.bookmark)
            store.set(selected.path, forKey: Keys.legacyPath)
            store.set(nil, forKey: Keys.notice)
        } catch { fallback() }
    }

    func exporter() -> TranscriptExporter {
        if let access { TranscriptExporter(access: access) } else { TranscriptExporter(directory: defaultDirectory) }
    }

    private func acquire(_ url: URL) throws -> OutputFolderAccess {
        guard url.isFileURL else { throw CocoaError(.fileReadNoPermission) }
        let scoped = bookmarks.startAccessing(url)
        guard scoped || bookmarks.isInAppContainer(url) else { throw CocoaError(.fileReadNoPermission) }
        guard bookmarks.isWritableDirectory(url) else {
            if scoped { bookmarks.stopAccessing(url) }
            throw CocoaError(.fileWriteNoPermission)
        }
        return OutputFolderAccess(directory: url, bookmarks: bookmarks, scoped: scoped)
    }

    private func fallback() {
        access = nil; url = defaultDirectory
        message = "The output folder is unavailable. Saving to the default Transcripts folder. Choose a folder again."
        store.set(nil, forKey: Keys.bookmark); store.set(nil, forKey: Keys.legacyPath)
        store.set(message, forKey: Keys.notice)
    }
}

/// One successful start is balanced after both the selection and every exporter release access.
private final class OutputFolderAccess: ExportDirectoryAccess {
    let directory: URL
    private let bookmarks: any OutputFolderBookmarking
    private let scoped: Bool
    init(directory: URL, bookmarks: any OutputFolderBookmarking, scoped: Bool) {
        self.directory = directory; self.bookmarks = bookmarks; self.scoped = scoped
    }
    deinit { if scoped { bookmarks.stopAccessing(directory) } }
}
