import SwiftUI
import UniformTypeIdentifiers

/// Backs `FilesPage`'s page-level `.onDrop` (design MW-06g). `.dropDestination(for: URL.self)`
/// gives no way to know *how many* items are being dragged before the drop completes — this
/// `DropDelegate` reads `NSItemProvider` counts directly so the overlay can say "Release to add 3
/// files" while the drag is still in flight (I3).
@MainActor
struct FilesDropDelegate: DropDelegate {
    let model: FilesViewModel

    func dropEntered(info: DropInfo) {
        model.isDragOver = true
        model.dragCount = info.itemProviders(for: [.fileURL]).count
    }

    func dropExited(info: DropInfo) {
        model.isDragOver = false
        model.dragCount = 0
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        model.isDragOver = false
        model.dragCount = 0
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(from: provider) { urls.append(url) }
            }
            await model.addFiles(urls)
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url)
            }
        }
    }
}
