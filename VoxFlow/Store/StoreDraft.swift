import Foundation
import VoxFlowCore

/// The store edition writes only to its own editor. It never queries another app's focus.
@Observable @MainActor
final class StoreDraft: TextInserting {
    var text = ""
    private(set) var saveError: String?
    private let url: URL

    init(url: URL) {
        self.url = url
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        catch { saveError = "Could not restore the draft: \(error.localizedDescription)" }
    }

    func insert(_ text: String, cursorOffset: Int?) async -> InsertionResult {
        if !self.text.isEmpty { self.text += "\n\n" }
        self.text += text
        save()
        return .inserted(appName: "VoxFlow")
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            saveError = nil
        } catch { saveError = "Could not save the draft. Copy your text before quitting. \(error.localizedDescription)" }
    }
}
