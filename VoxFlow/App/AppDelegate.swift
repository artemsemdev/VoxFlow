import AppKit
import SwiftUI

/// Dock-icon drops and Finder "Open With" (design MW-06: "drop on Dock icon").
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Starts the dictation loop exactly once: `dictation.start()` begins mirroring controller state,
    /// `flowBar.bind(to:)` shows/hides the HUD off that state, `fnMonitor.start()` arms the global
    /// fn/esc/any-key monitors (design 3e — needs Accessibility trust to see events at all).
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.dictation.start()
        AppServices.shared.flowBar.bind(to: AppServices.shared.dictation)
        AppServices.shared.fnMonitor.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            // Navigate first so the Files page (and its running-row UI) is what the user sees when
            // the window comes forward, rather than whatever page happened to be selected before.
            AppServices.shared.navigation.page = .files
            NSApp.activate(ignoringOtherApps: true)
            // No `@Environment(\.openWindow)` exists on an `NSApplicationDelegate` — `VoxFlowApp`
            // itself owns that action, so raising a not-currently-visible window is a flag it
            // observes rather than a call made directly from here.
            let mainWindowVisible = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == MainWindowID.main }
            if !mainWindowVisible {
                AppServices.shared.navigation.requestMainWindow = true
            }
            await AppServices.shared.queue.add(urls)
            await AppServices.shared.queue.start()
        }
    }

    /// VoxFlow is a menu bar app (`MenuBarExtra`) as well as a window app: closing the last window
    /// should never quit it out from under the menu bar item or an in-progress background export.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
