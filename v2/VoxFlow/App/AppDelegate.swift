import AppKit
import SwiftUI

/// Dock-icon drops and Finder "Open With" (design MW-06: "drop on Dock icon").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            await AppServices.shared.queue.add(urls)
            await AppServices.shared.queue.start()
        }
    }
}
