import SwiftUI

/// The selected sidebar page, shared by the main window and the app-level ⌘1–7 commands.
@Observable @MainActor
final class Navigation {
    var page: SidebarPage = .default
    /// Which Settings tab shows when `page` is `.settings` (design ST-01…06); the Files page's model
    /// banner sets this to `.models` before switching pages (controller ruling 1).
    var settingsTab: SettingsTab = .general
    /// Set by File › Open (and any other call site that wants the Files page's file importer to
    /// appear) — `FilesPage` binds its `.fileImporter(isPresented:)` to this and resets it once the
    /// importer closes; `MainWindow` navigates to `.files` when this becomes true from elsewhere.
    var requestFileImport = false
}
