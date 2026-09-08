import AppKit
import SwiftUI

/// Dock-icon drops and Finder "Open With" (design MW-06: "drop on Dock icon").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            // Navigate first so the Files page (and its running-row UI) is what the user sees when
            // the window comes forward, rather than whatever page happened to be selected before.
            AppServices.shared.navigation.page = .files
            await AppServices.shared.queue.add(urls)
            await AppServices.shared.queue.start()
        }
    }

    /// VoxFlow is a menu bar app (`MenuBarExtra`) as well as a window app: closing the last window
    /// should never quit it out from under the menu bar item or an in-progress background export.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
