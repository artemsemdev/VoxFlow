import AppKit
import Foundation
import UniformTypeIdentifiers
import VoxFlowCore

/// `Pasteboard` bridge to `NSPasteboard.general` (controller ruling 2). Used by the result view's
/// Copy button.
struct SystemPasteboard: Pasteboard {
    func setString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// `FileRevealing` bridge to `NSWorkspace` (controller ruling 2). Used by "Reveal in Finder" on
/// both a done queue row and the result view's footer.
struct FinderRevealer: FileRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// `NSSavePanel` bridge for the result view's "Save as…" (controller ruling 2, design 2f). Default
/// `nameFieldStringValue` is `<base>.<ext>`; `allowedContentTypes` comes from the format's
/// extension; on OK it writes the already-rendered text directly (no re-render, no re-processing).
@MainActor
enum SavePanel {
    static func save(baseName: String, format: OutputFormat, contents: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(contents.utf8).write(to: url)
    }
}
